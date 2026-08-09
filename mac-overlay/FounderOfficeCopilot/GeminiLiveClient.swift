import Foundation

/// Events streamed back from a live Gemini session
enum GeminiLiveEvent {
    /// Server acknowledged the setup message; safe to start streaming audio/image chunks
    case connected
    /// A chunk of the model's in-progress text reply for the current turn
    case textDelta(String)
    /// The model finished its reply for the current turn
    case turnComplete
    /// The user started talking again mid-reply (barge-in) - the in-progress turn should
    /// be discarded, a new one is about to start. This is what makes suggestions adapt
    /// live instead of finishing a stale answer.
    case interrupted
    /// Transcription of the user's own mic audio, produced by the Live API itself
    case inputTranscript(String)
    case error(Error)
    case disconnected
}

/// Thin client for Google's Gemini Live API (`BidiGenerateContent` over WebSocket).
/// There is no official Google Swift SDK for this endpoint (confirmed against
/// ai.google.dev/api/live), so this speaks the documented JSON protocol directly over
/// `URLSessionWebSocketTask` rather than pulling in a third-party dependency.
/// https://ai.google.dev/api/live
final class GeminiLiveClient {
    private let apiKey: String
    private let model: String
    private let systemInstruction: String

    private let urlSession = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private(set) var isSetupComplete = false

    var onEvent: ((GeminiLiveEvent) -> Void)?

    /// Set on connect() - every log line below is stamped with elapsed time since then,
    /// so a pasted console log carries hard numbers (network connect time, time to
    /// setupComplete, time from an audio chunk going out to a reply coming back) instead
    /// of requiring a guess about where a reported delay actually is.
    private var connectStartedAt: Date?
    private func elapsed() -> String {
        guard let connectStartedAt else { return "?" }
        return String(format: "%.2fs", Date().timeIntervalSince(connectStartedAt))
    }

    init(apiKey: String, model: String, systemInstruction: String) {
        self.apiKey = apiKey
        self.model = model
        self.systemInstruction = systemInstruction
    }

    func connect() {
        guard var components = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent") else { return }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return }

        connectStartedAt = Date()
        print("[GeminiLive][t=0.00s] Connecting with model=\(model)")
        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()
        sendSetup()
        listen()
    }

    func disconnect() {
        // Cancelling a URLSessionWebSocketTask does not complete synchronously - its
        // already-scheduled `receive` completion still fires shortly after, with a
        // cancellation/failure error, and would otherwise call onEvent(.disconnected) on
        // this now-defunct instance. If a NEW client has already been created and
        // connected by then (e.g. the user clicked Stop then Start quickly), that stale
        // event lands on AIEngineController and incorrectly stomps the new session's
        // isLiveSessionActive back to false, permanently stranding it on local fallback
        // suggestions. Clearing onEvent first makes every callback below a guaranteed
        // no-op for this instance, no matter what still fires on the socket afterward.
        onEvent = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isSetupComplete = false
    }

    /// Streams a chunk of 16-bit PCM, 16kHz, mono audio - the format the Live API requires
    func sendAudioChunk(_ data: Data) {
        guard isSetupComplete else { return }
        send(json: [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": data.base64EncodedString()
                ]
            ]
        ])
    }

    /// Streams a single JPEG screen frame into the same session as the audio, so a
    /// suggestion can be grounded in both what's said and what's visible at once
    func sendImageChunk(_ jpegData: Data) {
        guard isSetupComplete else { return }
        send(json: [
            "realtimeInput": [
                "video": [
                    "mimeType": "image/jpeg",
                    "data": jpegData.base64EncodedString()
                ]
            ]
        ])
    }

    private func sendSetup() {
        // Every Live-capable model currently available (confirmed against the real API,
        // not just docs) rejects responseModalities=TEXT - real-time audio-to-audio is
        // mandatory. So we request AUDIO but also turn on outputAudioTranscription, which
        // gives a text transcript of the spoken reply alongside the audio; the audio bytes
        // in modelTurn.parts are simply discarded in handleServerMessage below, since this
        // app only ever wants text on screen, never spoken output during someone's meeting.
        send(json: [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"]
                ],
                "systemInstruction": [
                    "parts": [["text": systemInstruction]]
                ],
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any]()
            ]
        ])
    }

    private var sentAudioChunkCount = 0

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }

        if json["realtimeInput"] != nil {
            sentAudioChunkCount += 1
            if sentAudioChunkCount == 1 {
                print("[GeminiLive][t=\(elapsed())] Sending first realtimeInput chunk")
            }
        } else {
            print("[GeminiLive][t=\(elapsed())] >> \(text.prefix(300))")
        }

        task?.send(.string(text)) { [weak self] error in
            if let error {
                print("[GeminiLive] send() failed: \(error)")
                self?.onEvent?(.error(error))
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                print("[GeminiLive] receive() failed: \(error)")
                self.onEvent?(.error(error))
                self.onEvent?(.disconnected)
                return
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleServerMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleServerMessage(text)
                    }
                @unknown default:
                    break
                }
            }
            // Keep listening for the next message on the same socket
            self.listen()
        }
    }

    private func handleServerMessage(_ text: String) {
        print("[GeminiLive][t=\(elapsed())] << \(text.prefix(300))")

        let events = GeminiLiveMessageParser.parse(text)
        if events.isEmpty {
            print("[GeminiLive][t=\(elapsed())] Message produced no events (not JSON, or a message type we don't act on, e.g. sessionResumptionUpdate)")
        }
        for event in events {
            if case .connected = event {
                isSetupComplete = true
            }
            onEvent?(event)
        }
    }
}

/// Pure parsing of one raw Gemini Live server message into the events it represents - no
/// state, no networking, so this is unit-testable without a live WebSocket connection.
/// This is exactly the logic that caused real, hard-to-diagnose bugs earlier (wrong
/// response modality, audio vs. text frame handling), so it's worth covering directly.
enum GeminiLiveMessageParser {
    static func parse(_ text: String) -> [GeminiLiveEvent] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if json["setupComplete"] != nil {
            return [.connected]
        }

        guard let serverContent = json["serverContent"] as? [String: Any] else { return [] }

        var events: [GeminiLiveEvent] = []

        if serverContent["interrupted"] as? Bool == true {
            events.append(.interrupted)
        }

        if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
           let transcriptText = inputTranscription["text"] as? String {
            events.append(.inputTranscript(transcriptText))
        }

        // The model's reply text - from outputAudioTranscription, since responseModalities
        // is AUDIO (required) and modelTurn.parts only carries audio inlineData, never text,
        // under that configuration. Those audio parts are intentionally never read here.
        if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
           let transcriptText = outputTranscription["text"] as? String {
            events.append(.textDelta(transcriptText))
        }

        if serverContent["turnComplete"] as? Bool == true {
            events.append(.turnComplete)
        }

        return events
    }
}
