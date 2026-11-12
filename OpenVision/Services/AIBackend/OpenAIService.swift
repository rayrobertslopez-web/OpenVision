// OpenVision - OpenAIService.swift
// Cloud backend for the OpenAI Chat Completions API (and any OpenAI-compatible endpoint), or a
// ChatGPT subscription via the Responses API (see ChatGPTSubscription).
//
// Simple request/response (non-streaming) — reliable for validating the cloud command + vision
// path. Supports text and images (base64 data URL). The reply is delivered via `onAgentMessage`,
// matching the other backends so VoiceAgentView can wire it up the same way. The prompt, tools and
// tool loop are shared with the other cloud chat backends (CloudChat).

import Foundation
import UIKit

@MainActor
final class OpenAIService: ObservableObject {

    static let shared = OpenAIService()

    /// Called with the assistant's reply text (spoken via TTS by VoiceAgentView).
    var onAgentMessage: ((String) -> Void)?
    /// Called when processing starts/stops (drives the thinking/listening state).
    var onProcessingChanged: ((Bool) -> Void)?

    @Published private(set) var isConnected = false

    private var settings: AppSettings { SettingsManager.shared.settings }

    private init() {}

    /// Lightweight "connect": OpenAI is stateless HTTP, so just validate config.
    func connect() async throws {
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        isConnected = true
    }

    /// Send a prompt (optionally with an image) and deliver the reply via `onAgentMessage`.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)

        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        let reply: String
        if settings.openAIAuthMode == .chatGPTSubscription {
            reply = try await sendViaSubscription(text, imageData: imageData)
        } else {
            guard let url = URL(string: "\(settings.openAIBaseURL)/chat/completions") else {
                throw OpenAIError.badURL
            }
            let apiKey = settings.openAIAPIKey
            // A self-hosted bridge may look things up before answering (earlier frames, files on
            // the user's computer), so give it longer than the public API and tell it how long.
            let selfHosted = BridgeWatch.isCustomEndpoint(settings.openAIBaseURL)
            reply = try await CloudChat.chatCompletionsReply(
                text: text, imageData: imageData, model: settings.openAIModel, label: "OpenAI"
            ) { body in
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.httpBody = body
                request.timeoutInterval = selfHosted ? 120 : 60
                if selfHosted { request.setValue("120", forHTTPHeaderField: "X-OV-Timeout") }
                return try await CloudChat.dataWithRetry(for: request)
            }
        }
        ConversationContext.shared.record(user: text, assistant: reply)
        onAgentMessage?(reply)
    }

    // MARK: - ChatGPT subscription (Responses API)

    /// Same conversation, tools and loop as the Chat Completions path, sent to the ChatGPT
    /// subscription backend in Responses format.
    private func sendViaSubscription(_ text: String, imageData: Data?) async throws -> String {
        var instructions = CloudChat.systemPrompt()
        if let docContext = DocumentFocus.shared.contextForQuery(text) {
            instructions += "\n\n" + docContext
        }

        var input: [[String: Any]] = ConversationContext.shared.turns.map { turn in
            let type = turn.role == "assistant" ? "output_text" : "input_text"
            return ["role": turn.role, "content": [["type": type, "text": turn.content]]]
        }
        var userContent: [[String: Any]] = [["type": "input_text", "text": text.isEmpty && imageData != nil ? "Describe what you see." : text]]
        if let imageData {
            userContent.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"])
        }
        input.append(["role": "user", "content": userContent])

        let tools = ChatGPTSubscription.responsesTools(fromChatTools: CloudChat.toolSpecs())
        let model = settings.openAISubscriptionModel.isEmpty ? ChatGPTSubscription.defaultModel : settings.openAISubscriptionModel

        for _ in 0..<4 {
            let items = try await ChatGPTSubscription.respond(model: model, instructions: instructions, input: input, tools: tools)
            // Echo every item (reasoning included) back — the backend is stateless (store:false).
            input.append(contentsOf: items)

            let calls = items.filter { $0["type"] as? String == "function_call" }
            if !calls.isEmpty {
                for call in calls {
                    let result = await CloudChat.runTool(call["name"] as? String ?? "", arguments: call["arguments"] as? String)
                    input.append(["type": "function_call_output", "call_id": call["call_id"] as? String ?? "", "output": result])
                }
                continue
            }

            let reply = items
                .filter { $0["type"] as? String == "message" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { throw CloudChatError.emptyReply("ChatGPT") }
            return ChatGPTSubscription.capForSpeech(reply)
        }
        throw CloudChatError.api("ChatGPT", "search loop didn't converge")
    }

    enum OpenAIError: LocalizedError {
        case notConfigured, badURL
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI isn't configured. Add an API key or sign in to ChatGPT in Settings → OpenAI."
            case .badURL: return "The OpenAI base URL is invalid."
            }
        }
    }
}


// MARK: - Bridge watch (live frames to a self-hosted OpenAI-compatible endpoint)

/// While live video mode runs against the user's OWN endpoint (the OpenAI slot pointed at a bridge
/// instead of api.openai.com), upload glasses frames to `<base URL>/frames`. The bridge keeps them
/// as a short visual memory and attaches the latest ones to every question, so the model behind it
/// sees the current view and can look back in time. Nothing is uploaded to api.openai.com.
///
/// Upload economics: a frame goes out when the view changed since the last one sent, at most every
/// `minInterval`, and at least every `heartbeat` so the bridge knows the camera is still on.
@MainActor
final class BridgeWatch {

    static let shared = BridgeWatch()
    private init() {}

    private static let minInterval: TimeInterval = 0.7
    private static let heartbeat: TimeInterval = 4.0
    /// Lower than FrameChange.sceneChangeThreshold on purpose: the memory should also catch small
    /// changes (a hand putting something down), not only head turns.
    private static let changeThreshold = 0.03

    private var task: Task<Void, Never>?
    private var lastSentThumb: [UInt8]?
    private var lastSentAt = Date.distantPast
    private var lastSeenFrameTime = Date.distantPast
    private(set) var framesSent = 0

    var isRunning: Bool { task != nil }

    nonisolated static func isCustomEndpoint(_ baseURL: String) -> Bool {
        let lower = baseURL.lowercased()
        return !lower.isEmpty && !lower.contains("api.openai.com")
    }

    /// True when the selected backend is the OpenAI slot with an API key and a custom base URL.
    static var isAvailable: Bool {
        let settings = SettingsManager.shared.settings
        return settings.aiBackend == .openAI && settings.isOpenAIAPIAvailable
            && isCustomEndpoint(settings.openAIBaseURL)
    }

    func start() {
        stop()
        framesSent = 0
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                let sent = await self.sendIfWorthIt()
                try? await Task.sleep(nanoseconds: sent ? 250_000_000 : 350_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lastSentThumb = nil
        lastSentAt = .distantPast
        lastSeenFrameTime = .distantPast
    }

    private func sendIfWorthIt() async -> Bool {
        let glasses = GlassesManager.shared
        let frameTime = glasses.lastFrameTime
        // Only a frame we have not looked at yet, and only a fresh one: when the stream pauses
        // (app in the background, Bluetooth throttling) nothing is sent.
        guard let frame = glasses.lastFrame, frameTime > lastSeenFrameTime,
              Date().timeIntervalSince(frameTime) < 1.0 else { return false }
        lastSeenFrameTime = frameTime

        let sinceLast = Date().timeIntervalSince(lastSentAt)
        guard sinceLast >= Self.minInterval else { return false }
        let thumb = Self.thumbnail(frame)
        if let last = lastSentThumb, sinceLast < Self.heartbeat,
           FrameChange.difference(thumb, last) < Self.changeThreshold {
            return false
        }
        guard let jpeg = frame.jpegData(compressionQuality: 0.5) else { return false }

        let settings = SettingsManager.shared.settings
        guard let url = URL(string: "\(settings.openAIBaseURL)/frames") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue(String(format: "%.3f", frameTime.timeIntervalSince1970), forHTTPHeaderField: "X-Frame-Time")
        request.timeoutInterval = 10

        lastSentThumb = thumb
        lastSentAt = Date()
        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: jpeg)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                framesSent += 1
                if framesSent == 1 || framesSent % 100 == 0 {
                    NSLog("[BridgeWatch] frames sent: %d", framesSent)
                }
                return true
            }
            NSLog("[BridgeWatch] frame refused: HTTP %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            NSLog("[BridgeWatch] frame upload failed: %@", error.localizedDescription)
        }
        // The bridge is unreachable or refusing: back off instead of hammering it.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return false
    }

    /// 16x16 grayscale thumbnail for the change gate (same shape the live watch loop uses).
    private static func thumbnail(_ image: UIImage) -> [UInt8] {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let cg = image.cgImage else { return pixels }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }
}
