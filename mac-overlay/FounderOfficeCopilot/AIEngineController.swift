import Foundation
import Combine

// MARK: - AI Engine Controller
/// Orchestrates the live Gemini session and Teams member detection. A single always-on
/// assistant: audio (mic + system, whoever's talking) streams to Gemini continuously the
/// whole time it's active, transcribed into the chat as it's heard, but the assistant only
/// ever replies when explicitly triggered via requestResponse() - never automatically. Turn
/// boundaries are entirely client-controlled (see GeminiLiveClient), which is what makes
/// "always listening, replies only on demand" possible without relying on the server's own
/// voice-activity-detection to decide when a pause means "the user is done talking."
///
/// Suggestions only ever come from the real Gemini Live session - grounded in what was
/// actually heard. Without a configured API key, or while the live session is disconnected,
/// the app simply produces no responses rather than inventing disconnected-from-reality ones.
/// https://developer.apple.com/documentation/combine/observableobject
final class AIEngineController: ObservableObject {
    /// The live chat feed the overlay renders - heard/response bubbles interleaved
    @Published var messages: [ChatMessage] = []
    @Published var isListening: Bool = false
    @Published var teamsParticipants: [String] = []
    /// True while a Gemini Live session is connected
    @Published var isLiveSessionActive: Bool = false
    /// True between "Start listening" and "Stop listening" - the master gate. When false,
    /// nothing (the live session, reconnect attempts) is allowed to run.
    @Published var isActive: Bool = false

    private let teamsDetector = TeamsParticipantDetector()

    /// How the Gemini API key is looked up - defaults to the real Keychain-backed
    /// SettingsStore. Tests override this to return nil, so an automated run never opens
    /// a real network connection using a developer's saved key.
    var apiKeyProvider: () -> String? = { SettingsStore.shared.geminiAPIKey }

    private var liveClient: GeminiLiveClient?
    /// The latest session-resumption handle from the server - passed into the next setup
    /// message on reconnect so context survives instead of starting blank. Required for any
    /// session longer than the ~10 minute single-connection lifetime.
    private var lastResumptionHandle: String?

    /// Index of the in-progress "heard" / "response" bubble, so streamed deltas append to
    /// the same message instead of creating a new one per chunk
    private(set) var activeHeardIndex: Int?
    private(set) var activeResponseIndex: Int?

    init() {
        startDetectingTeamsParticipants()
    }

    // MARK: Start / stop (the master on/off switch)

    func start() {
        isActive = true
        isListening = true
        startLiveSession()
    }

    func stop() {
        isActive = false
        isListening = false
        stopLiveSession()
    }

    /// Starts detecting Teams participants in real-time
    /// Accessibility tree traversal runs off the main thread: cross-process AX calls into
    /// Teams (Electron/React) can take noticeable time and would otherwise stall the UI
    private func startDetectingTeamsParticipants() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                let participants = self.teamsDetector.detectParticipants()
                DispatchQueue.main.async {
                    self.teamsParticipants = participants
                }
            }
        }
    }

    // MARK: Gemini Live session

    /// Connects a Gemini Live session if an API key is configured; if not, the app
    /// simply produces no responses rather than falling back to disconnected-from-
    /// reality canned ones
    func startLiveSession() {
        guard isActive, liveClient == nil, let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return }

        let settings = SettingsStore.shared
        var systemInstruction = Self.unifiedInstruction(agentName: settings.agentName)
        if !settings.aboutMe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemInstruction += "\n\nAbout the user you're helping:\n\(settings.aboutMe)"
        }
        systemInstruction += "\n\n\(settings.rules)"

        let client = GeminiLiveClient(
            apiKey: apiKey,
            model: settings.geminiModel,
            systemInstruction: systemInstruction,
            resumptionHandle: lastResumptionHandle
        )
        client.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleLiveEvent(event)
            }
        }
        liveClient = client
        client.connect()
    }

    /// The single unified system instruction - no separate meeting/personal-assistant
    /// prompts, since there's no longer a mode distinction. Silence is the default state;
    /// the model only ever gets asked to reply at the exact moment requestResponse() sends
    /// activityEnd, so there's no need for the old "never behave like a dialogue partner"
    /// constraint that a continuously-reactive assistant needed - every reply here IS a
    /// deliberate request by construction.
    static func unifiedInstruction(agentName: String) -> String {
        """
        You are "\(agentName)", an always-listening personal assistant. You continuously \
        hear everything around the user - their own voice and anyone else's, in meetings, \
        calls, or day-to-day life - but you never speak up on your own. You only produce a \
        reply when explicitly triggered.

        When triggered, look at everything heard since your last reply and give one \
        substantive, useful response. If it looks like the user wants help contributing to \
        a live conversation, phrase it in the FIRST PERSON as something they could say out \
        loud right now, with real structure - a clear point, then a concrete reason or \
        example, not generic filler. If it looks like they're asking you something \
        directly, just answer it plainly and helpfully. If there's a clear question or \
        problem in what was said (including a coding/technical problem), solve it \
        directly. No preamble, no meta-commentary about what you're doing - just the \
        useful content itself.

        Language: reply in the same language as whatever you're actually responding to.
        """
    }

    func stopLiveSession() {
        liveClient?.disconnect()
        liveClient = nil
        isLiveSessionActive = false
        activeHeardIndex = nil
        activeResponseIndex = nil
    }

    /// The entire "respond now" trigger mechanism - closes the current listening window
    /// and asks Gemini to reply to everything heard since the last response. A no-op if
    /// there's no live session (e.g. no API key configured).
    func requestResponse() {
        liveClient?.sendActivityEnd()
    }

    /// Forwards an audio chunk (mic or system audio - both feed the same session) to the
    /// live session, if connected
    func sendLiveAudioChunk(_ data: Data) {
        liveClient?.sendAudioChunk(data)
    }

    /// Forwards a screen frame to the live session, if one is connected
    func sendLiveImageChunk(_ jpegData: Data) {
        liveClient?.sendImageChunk(jpegData)
    }

    /// Internal rather than private, deliberately: this is pure state-mutation logic given
    /// an event (no networking inside it), so tests drive it directly with synthetic
    /// GeminiLiveEvent values instead of needing a real WebSocket round trip.
    func handleLiveEvent(_ event: GeminiLiveEvent) {
        switch event {
        case .connected:
            isLiveSessionActive = true
            // Open the always-on listening window immediately - audio streams from here,
            // but nothing gets a reply until requestResponse() closes it
            liveClient?.sendActivityStart()

        case .sessionResumptionUpdate(let handle):
            lastResumptionHandle = handle

        case .inputTranscript(let delta):
            if activeResponseIndex != nil { activeResponseIndex = nil }
            if let index = activeHeardIndex {
                messages[index].text += delta
            } else {
                appendMessage(ChatMessage(role: .heard, text: delta), trackAs: \.activeHeardIndex)
            }

        case .textDelta(let delta):
            activeHeardIndex = nil
            if let index = activeResponseIndex {
                messages[index].text += delta
            } else {
                appendMessage(ChatMessage(role: .response, text: delta, isStreaming: true), trackAs: \.activeResponseIndex)
            }

        case .turnComplete:
            if let index = activeResponseIndex {
                messages[index].isStreaming = false
            }
            activeResponseIndex = nil
            activeHeardIndex = nil
            // Reopen the listening window for whatever comes next - manual turn control
            // means nothing else does this automatically
            liveClient?.sendActivityStart()

        case .interrupted:
            // Nothing is ever removed from the chat, even a reply that got cut off
            // mid-thought - it just stops streaming and stays exactly as far as it got.
            if let index = activeResponseIndex, messages.indices.contains(index) {
                messages[index].isStreaming = false
            }
            activeResponseIndex = nil

        case .error, .disconnected:
            isLiveSessionActive = false
            liveClient?.disconnect()
            liveClient = nil
            attemptReconnectIfNeeded()
        }
    }

    /// A spontaneous drop (idle/connection-lifetime timeout, network blip) reconnects on
    /// its own instead of requiring the user to notice and manually Stop/Start - using
    /// lastResumptionHandle so context survives the reconnect. A short fixed delay avoids
    /// hammering a connection that's genuinely down while still recovering quickly from a
    /// normal drop.
    private func attemptReconnectIfNeeded() {
        guard isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isActive, self.liveClient == nil else { return }
            self.startLiveSession()
        }
    }

    /// Appends a message and optionally tracks its index as the "active" bubble for a
    /// given streaming source. Nothing is ever trimmed - the whole session's history stays.
    private func appendMessage(_ message: ChatMessage, trackAs keyPath: ReferenceWritableKeyPath<AIEngineController, Int?>?) {
        messages.append(message)
        if let keyPath {
            self[keyPath: keyPath] = messages.count - 1
        }
    }

    deinit {
        liveClient?.disconnect()
    }
}
