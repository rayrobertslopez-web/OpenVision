// OpenVision - GlassesManager.swift
// Singleton manager for Meta Ray-Ban glasses via DAT SDK

import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import OSLog
import MWDATCore
import MWDATCamera

/// Manages Meta Ray-Ban glasses registration, connection, and camera streaming
@MainActor
final class GlassesManager: ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesManager()

    // MARK: - Published Properties

    /// Whether the app is registered with Meta AI
    @Published var isRegistered: Bool = false

    /// Currently connected device identifier
    @Published var connectedDevice: DeviceIdentifier?

    /// Number of connected devices
    @Published var connectedDeviceCount: Int = 0

    /// Whether camera streaming is active
    @Published var isStreaming: Bool = false

    /// Whether the running stream was opened with the glasses' microphone on it (camera audio
    /// streaming). Decided once per stream, from Meta AI's microphone grant. Buffers arrive
    /// through `GlassesAudioRelay`.
    @Published private(set) var streamCarriesAudio: Bool = false

    /// Last captured video frame
    @Published var lastFrame: UIImage?

    /// When `lastFrame` was received. Lets the live loop tell a fresh frame from a stale one when
    /// the Bluetooth stream throttles under head motion (so it doesn't describe an old view).
    private(set) var lastFrameTime: Date = .distantPast

    /// Last captured photo data
    @Published var lastPhotoData: Data?

    /// Error message for UI display
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private let wearables = Wearables.shared
    // 0.9.0 camera lifecycle: DeviceSession owns the device link, Camera owns the camera
    // hardware, camera.stream carries frames. Stopping the camera cascades to the stream.
    private var deviceSession: DeviceSession?
    private var camera: Camera?

    // Listener tokens (retained to keep subscriptions active)
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?
    private var audioFrameListenerToken: (any AnyListenerToken)?

    // MARK: - Callbacks

    /// Called when a video frame is received
    var onVideoFrame: ((UIImage) -> Void)?

    /// Called with the raw sample buffer for every video frame — used by SessionRecorder to mux
    /// the glasses POV into a movie file without going through UIImage. Independent of `onVideoFrame`.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called when a photo is captured
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Initialization

    private init() {
        print("[GlassesManager] Initializing")
        setupRegistrationListener()
        setupDevicesListener()
    }

    // MARK: - Registration

    /// Register app with Meta AI
    func register() async throws {
        print("[GlassesManager] Starting registration")

        // Check if already registered
        for await state in wearables.registrationStateStream() {
            if case .registered = state {
                print("[GlassesManager] Already registered")
                isRegistered = true
                return
            }
            break
        }

        // Start registration flow
        try await wearables.startRegistration()
        print("[GlassesManager] Registration initiated, waiting for Meta AI callback")
    }

    /// Unregister app from Meta AI
    func unregister() async {
        print("[GlassesManager] Starting unregistration")

        // Stop streaming first if active
        if isStreaming {
            await stopStreaming()
        }

        do {
            try await wearables.startUnregistration()
            isRegistered = false
            connectedDevice = nil
            connectedDeviceCount = 0
            errorMessage = nil
            print("[GlassesManager] Unregistration successful")
        } catch {
            errorMessage = "Unregister failed: \(error.localizedDescription)"
            print("[GlassesManager] Unregistration error: \(error)")
        }
    }

    // MARK: - Streaming

    /// Start camera streaming from glasses.
    ///
    /// `withAudio` asks for the glasses' microphone on the same stream (experimental in the SDK).
    /// It is the only way to hear the glasses while their camera runs: the Bluetooth HFP mic
    /// goes deaf during streaming. The audio is requested only when Meta AI's microphone grant
    /// is there, because a stream asked for audio the wearer never allowed may not start at all.
    /// `frameRate` must be one of the SDK's values: 2, 7, 15, 24, 30.
    func startStreaming(withAudio: Bool = false, frameRate: UInt = 30) async {
        guard isRegistered else {
            errorMessage = "Not registered with Meta AI"
            print("[GlassesManager] Cannot start streaming - not registered")
            return
        }

        guard !isStreaming else {
            print("[GlassesManager] Already streaming")
            return
        }

        // Check for connected device
        guard let deviceId = connectedDevice else {
            errorMessage = "No glasses connected"
            print("[GlassesManager] Cannot start streaming - no device connected")
            return
        }

        print("[GlassesManager] Starting camera stream for device: \(deviceId)")

        // Diagnostic (issue #55 follow-up): the SDK's own verdict on whether it can drive
        // this hardware — surfaces firmware/SDK mismatches that otherwise fail as an opaque
        // "Device unavailable" at session start.
        if let device = wearables.deviceForIdentifier(deviceId) {
            print("[GlassesManager] Device \(device.nameOrId()): type=\(device.deviceType()) link=\(device.linkState) compatibility=\(device.compatibility())")
            if device.compatibility() == .deviceUpdateRequired {
                errorMessage = "Glasses firmware update required — update in the Meta AI app"
            } else if device.compatibility() == .sdkUpdateRequired {
                errorMessage = "Glasses too new for this SDK version"
            }
        } else {
            print("[GlassesManager] deviceForIdentifier returned nil")
        }

        // Request camera permission first (like xmeta does)
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            print("[GlassesManager] Camera permission status: \(status)")

            if status != .granted {
                print("[GlassesManager] Requesting camera permission...")
                status = try await wearables.requestPermission(.camera)
                print("[GlassesManager] After request, status: \(status)")
            }

            guard status == .granted else {
                errorMessage = "Camera permission denied"
                print("[GlassesManager] Camera permission not granted")
                return
            }
        } catch {
            errorMessage = "Permission error: \(error.localizedDescription)"
            print("[GlassesManager] Permission error: \(error)")
            return
        }

        // Glasses microphone on the stream: only with the grant (see the method comment).
        var carriesAudio = false
        if withAudio {
            do {
                var micStatus = try await wearables.checkPermissionStatus(.microphone)
                print("[GlassesManager] Microphone permission status: \(micStatus)")
                if micStatus != .granted {
                    print("[GlassesManager] Requesting microphone permission...")
                    micStatus = try await wearables.requestPermission(.microphone)
                    print("[GlassesManager] After request, microphone status: \(micStatus)")
                }
                carriesAudio = micStatus == .granted
            } catch {
                print("[GlassesManager] Microphone permission unavailable: \(error)")
            }
            if !carriesAudio {
                print("[GlassesManager] No microphone grant — the stream will carry video only")
            }
        }

        // SpecificDeviceSelector stays the more reliable choice over AutoDeviceSelector
        let specificSelector = SpecificDeviceSelector(device: deviceId)

        let config: StreamConfiguration
        if carriesAudio {
            config = StreamConfiguration(
                videoCodec: .raw,
                audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
                resolution: .medium,
                frameRate: frameRate
            )
        } else {
            config = StreamConfiguration(
                videoCodec: .raw,
                resolution: .medium,
                frameRate: frameRate
            )
        }

        do {
            let session = try wearables.createSession(deviceSelector: specificSelector)
            deviceSession = session

            // Order matters (SDK docs): the session must be STARTED before addCamera —
            // attaching the camera to an idle session returns nil (issue #55, Blayzer test).
            // Subscribe to state before start() so the .started transition can't be missed.
            let stateStream = session.stateStream()
            // The session can abort during startup (starting -> stopping -> stopped) with the
            // reason only on its error stream — log it or we debug blind (seen on Gen 1/2).
            let sessionErrorTask = Task {
                for await error in session.errorStream() {
                    print("[GlassesManager] Device session error: \(error) — \(error.description)")
                    await MainActor.run { self.errorMessage = "Session error: \(error.description)" }
                }
            }
            defer { sessionErrorTask.cancel() }
            print("[GlassesManager] Starting device session...")
            try session.start()

            let started = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await state in stateStream {
                        print("[GlassesManager] Device session state: \(state)")
                        if state == .started { return true }
                        if state == .stopped { return false }
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            guard started else {
                errorMessage = "Device session did not start (timeout)"
                print("[GlassesManager] Device session failed to reach .started")
                dumpSDKLogs(since: 30)
                session.stop()
                deviceSession = nil
                return
            }

            guard let cam = try session.addCamera(config: config) else {
                errorMessage = "Failed to attach camera to device session"
                print("[GlassesManager] addCamera returned nil")
                session.stop()
                deviceSession = nil
                return
            }
            camera = cam

            // The audio listener must be registered before the stream starts.
            setupStreamListeners(stream: cam.stream, withAudio: carriesAudio)
            cam.stream.start()
            isStreaming = true
            streamCarriesAudio = carriesAudio
            print("[GlassesManager] Streaming started successfully (\(frameRate) fps, audio: \(carriesAudio ? "on" : "off"))")
        } catch {
            errorMessage = "Stream start failed: \(error.localizedDescription)"
            print("[GlassesManager] Stream start error: \(error)")
            cleanupStreamListeners()
            camera = nil
            deviceSession = nil
        }
    }

    /// Stop camera streaming
    func stopStreaming() async {
        guard isStreaming || camera != nil || deviceSession != nil else { return }

        print("[GlassesManager] Stopping camera stream")

        // Cancel the audio listener before the camera stops (SDK guidance), then the rest.
        audioFrameListenerToken = nil
        camera?.stop()          // cascades to the stream
        deviceSession?.stop()

        cleanupStreamListeners()
        camera = nil
        deviceSession = nil
        isStreaming = false
        streamCarriesAudio = false
        GlassesAudioRelay.shared.reset()
        lastFrame = nil
        lastFrameTime = .distantPast

        print("[GlassesManager] Streaming stopped")
    }

    /// Capture a photo from the glasses camera
    func capturePhoto() async {
        guard isStreaming, let stream = camera?.stream else {
            errorMessage = "Streaming must be active to capture photos"
            return
        }

        print("[GlassesManager] Capturing photo")

        // Non-throwing since 0.9.0; failures surface as StreamError.photoCaptureFailed
        // on the error publisher, which setupStreamListeners already routes to errorMessage.
        if !stream.capturePhoto(format: .jpeg) {
            errorMessage = "Failed to start photo capture"
            print("[GlassesManager] capturePhoto returned false")
        }
    }

    // MARK: - Private Methods

    private func setupRegistrationListener() {
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    if case .registered = state {
                        self.isRegistered = true
                        print("[GlassesManager] Registration state: registered")
                    } else {
                        self.isRegistered = false
                        print("[GlassesManager] Registration state: \(state)")
                    }
                }
            }
        }
    }

    private func setupDevicesListener() {
        devicesTask = Task {
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    self.connectedDeviceCount = devices.count
                    self.connectedDevice = devices.first
                    print("[GlassesManager] Devices updated: \(devices.count) connected")
                }
            }
        }
    }

    private func setupStreamListeners(stream: MWDATCamera.Stream, withAudio: Bool = false) {
        // Glasses microphone. Delivered straight from the SDK's callback, in order, to the relay:
        // hopping each buffer through its own main-actor Task would let them arrive out of order.
        if withAudio {
            audioFrameListenerToken = stream.audioFramePublisher.listen { frame in
                GlassesAudioRelay.shared.deliver(frame.pcmBuffer)
            }
        }

        // State listener
        stateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                switch state {
                case .streaming:
                    self?.isStreaming = true
                case .stopped:
                    self?.isStreaming = false
                default:
                    break
                }
            }
        }

        // Video frame listener
        videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                // Hand the raw sample buffer to the recorder (if any). SessionRecorder immediately
                // hops it onto its own writer queue, so this stays cheap even at 30fps.
                self?.onVideoSampleBuffer?(frame.sampleBuffer)
                if let image = frame.makeUIImage() {
                    self?.lastFrame = image
                    self?.lastFrameTime = Date()
                    self?.onVideoFrame?(image)
                }
            }
        }

        // Photo data listener
        photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                let data = photoData.data
                self?.lastPhotoData = data
                self?.onPhotoCaptured?(data)
                print("[GlassesManager] Photo captured: \(data.count) bytes")
            }
        }

        // Error listener
        errorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                // The raw video codec pauses by design when the app leaves the foreground
                // (screen lock, app switch) and the SDK reports that as a scary-sounding
                // error ("Critical error, the stream should end" — issue #55). Only alert
                // for errors that happen while the user is actually looking at the app.
                if UIApplication.shared.applicationState == .active {
                    self?.errorMessage = error.localizedDescription
                }
                print("[GlassesManager] Stream error: \(error)")
            }
        }
    }

    /// TEMP DIAGNOSTIC (issue #55 follow-up): the DAT SDK logs its teardown reasons via OSLog,
    /// which `devicectl --console` can't see. The app CAN read its own process's entries, so on
    /// session failure dump every non-Apple subsystem line from the last `seconds` to stdout.
    private func dumpSDKLogs(since seconds: TimeInterval) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-seconds))
            let entries = try store.getEntries(at: position)
            print("[GlassesManager] ===== SDK log dump (last \(Int(seconds))s) =====")
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                let sub = log.subsystem
                guard !sub.isEmpty, !sub.hasPrefix("com.apple") else { continue }
                print("[SDKLOG] \(sub)/\(log.category) [\(log.level.rawValue)] \(log.composedMessage)")
            }
            print("[GlassesManager] ===== end SDK log dump =====")
        } catch {
            print("[GlassesManager] OSLogStore dump failed: \(error)")
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
        audioFrameListenerToken = nil
    }
}

// MARK: - Glasses microphone relay

/// Hands the glasses' microphone buffers (camera audio streaming) to whoever is listening, on the
/// SDK's own callback thread and in arrival order. Each buffer is converted into a fresh 16 kHz
/// mono float buffer first: the SDK asks that its buffers are not mutated, and the consumers
/// (speech recognition, voice-activity detection) get one known format whatever the glasses send.
final class GlassesAudioRelay: @unchecked Sendable {

    static let shared = GlassesAudioRelay()
    private init() {}

    private let lock = NSLock()
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private var lastFrame = Date.distantPast
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)

    /// When the last buffer arrived. "Recent" means the glasses microphone is really flowing.
    var lastFrameTime: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastFrame
    }

    func setHandler(_ newHandler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    func reset() {
        lock.lock()
        lastFrame = .distantPast
        converter = nil
        lock.unlock()
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let targetFormat else { return }

        lock.lock()
        let firstBuffer = lastFrame == .distantPast
        lastFrame = Date()
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        let activeConverter = converter
        let activeHandler = handler
        lock.unlock()

        if firstBuffer {
            NSLog("[GlassesAudio] microphone flowing: %@, %d frames a buffer", "\(buffer.format)", Int(buffer.frameLength))
        }
        guard let activeConverter, let activeHandler else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // One buffer in, then "no data now": the converter pulls its input.
        var supplied = false
        var conversionError: NSError?
        activeConverter.convert(to: converted, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, converted.frameLength > 0 else { return }
        activeHandler(converted)
    }
}
