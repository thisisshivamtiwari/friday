import Foundation
import Combine

// MARK: - AI Engine Controller
/// Orchestrates the live Gemini session, Teams member detection, and transcription.
/// Suggestions only ever come from the real Gemini Live session - grounded in what was
/// actually said. Without a configured API key, or while the live session is
/// disconnected, the app simply produces no suggestions rather than inventing
/// disconnected-from-reality ones.
/// https://developer.apple.com/documentation/combine/observableobject
final class AIEngineController: ObservableObject {
    /// The live chat feed the overlay renders - transcript and suggestion bubbles interleaved
    @Published var messages: [ChatMessage] = []
    @Published var isListening: Bool = false
    @Published var teamsParticipants: [String] = []
    /// True while a Gemini Live session is connected and driving suggestions
    @Published var isLiveSessionActive: Bool = false
    /// True between "Start listening" and "Stop listening" - the master gate. When false,
    /// nothing (RMS detection, live session) is allowed to produce output, which is what
    /// "Stop listening" is actually supposed to mean.
    @Published var isActive: Bool = false
    @Published var mode: AssistantMode = .meeting

    private let teamsDetector = TeamsParticipantDetector()
    private let speechRecognizer: TranscriptSource

    /// How the Gemini API key is looked up - defaults to the real Keychain-backed
    /// SettingsStore. Tests override this to return nil, so an automated run never opens
    /// a real network connection using a developer's saved key.
    var apiKeyProvider: () -> String? = { SettingsStore.shared.geminiAPIKey }

    private var liveClient: GeminiLiveClient?
    /// Index of the in-progress "you" / "heard" / "suggestion" bubble, so streamed deltas
    /// append to the same message instead of creating a new one per chunk
    private(set) var activeYouIndex: Int?
    private(set) var activeHeardIndex: Int?
    private(set) var activeSuggestionIndex: Int?

    /// `speechRecognizer` is injectable so tests can pass a no-op stub: the real
    /// SpeechRecognitionEngine calls SFSpeechRecognizer.requestAuthorization, which macOS
    /// hard-crashes any process for if it lacks an Info.plist usage-description key - true
    /// of any plain command-line test binary, not just a misconfigured app.
    init(speechRecognizer: TranscriptSource = SpeechRecognitionEngine()) {
        self.speechRecognizer = speechRecognizer
        startDetectingTeamsParticipants()
        startLiveTranscription()
    }

    // MARK: Start / stop (the master on/off switch)

    /// Starts listening: connects the Gemini Live session (if a key is configured)
    func start() {
        isActive = true
        // isListening (the status dot) reflects "Start listening was clicked and Stop
        // hasn't been clicked yet" - deliberately NOT tied to momentary mic RMS, which is
        // noisy enough (ambient laptop mic noise floor) to stay permanently "detected"
        isListening = true
        speechRecognizer.start()
        startLiveSession()
    }

    /// Fully stops listening - disconnects Gemini and the local transcript
    func stop() {
        isActive = false
        isListening = false
        speechRecognizer.stop()
        stopLiveSession()
    }

    /// Switches between Meeting and Personal Assistant mode. The Live API's system
    /// instruction is fixed for the lifetime of a session, so a mode change while active
    /// means reconnecting with the new instruction and audio routing.
    func toggleMode() {
        mode = (mode == .meeting) ? .personalAssistant : .meeting
        guard isActive else { return }
        stopLiveSession()
        startLiveSession()
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

    /// Transcribes the user's own mic locally (on-device SFSpeechRecognizer) and shows it
    /// as "You" bubbles - independent of whether a Gemini Live session is active, since
    /// the mic is never sent to Gemini at all (see AudioCaptureManager/SystemAudioCaptureManager)
    private func startLiveTranscription() {
        speechRecognizer.onTranscriptUpdate = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            DispatchQueue.main.async {
                // SFSpeechRecognizer reports the full running transcript each callback
                // (not a delta), so replace rather than append
                if let index = self.activeYouIndex {
                    self.messages[index].text = text
                } else if self.messages.last(where: { $0.role == .you })?.text == text {
                    // SFSpeechRecognizer can redeliver the exact same cumulative transcript
                    // verbatim even when nothing new was said (a re-emitted/stabilized
                    // hypothesis, not new speech). If activeYouIndex was already cleared by
                    // an assistant reply completing in between, treating this as "new" would
                    // duplicate the question that's already shown - ignore the redelivery.
                } else {
                    self.appendMessage(ChatMessage(role: .you, text: text), trackAs: \.activeYouIndex)
                }
            }
        }
    }

    // MARK: Gemini Live session

    /// Connects a Gemini Live session if an API key is configured; if not, the app
    /// simply produces no suggestions rather than falling back to disconnected-from-
    /// reality canned ones
    func startLiveSession() {
        guard isActive, liveClient == nil, let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return }

        let settings = SettingsStore.shared
        var systemInstruction = mode == .meeting ? Self.meetingInstruction(agentName: settings.agentName) : Self.personalAssistantInstruction(agentName: settings.agentName)
        if !settings.aboutMe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemInstruction += "\n\nAbout the user you're helping:\n\(settings.aboutMe)"
        }
        systemInstruction += "\n\n\(settings.rules)"

        let client = GeminiLiveClient(apiKey: apiKey, model: settings.geminiModel, systemInstruction: systemInstruction)
        client.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleLiveEvent(event)
            }
        }
        liveClient = client
        client.connect()
    }

    /// Explicit and repeated on purpose: without this, a conversational Live model
    /// defaults to treating the user's voice as talking TO it and replies with
    /// clarifying questions ("You think what?", "Why is that?") - confirmed against
    /// the real API. It must never behave like a dialogue partner in this mode.
    static func meetingInstruction(agentName: String) -> String {
        """
        You are "\(agentName)", a SILENT real-time meeting copilot. You overhear \
        a live meeting between the user and other people (and sometimes see their screen). \
        You are not a participant in this meeting and the user is not talking to you.

        Never reply conversationally. Never ask the user a question. Never address the \
        user as "you". Do not say things like "What do you mean" or "Why is that" or \
        "And how does that work" - those are dialogue replies, and you must not produce them.

        Instead, after each new thing is said in the meeting, output a substantive, \
        well-reasoned response phrased in the FIRST PERSON, as something the user could say \
        OUT LOUD TO THE OTHER PEOPLE right now. Aim for 2-4 sentences (roughly 10-20 seconds \
        of natural spoken delivery) with real structure: a clear point or stance, then a \
        concrete reason, example, or piece of evidence backing it up, and - only where it \
        genuinely fits - a specific tie-back to whatever role/company/context you've been \
        given about the user, never generic filler. When responding to something someone \
        else just said, look for a way to build on it, add a genuinely new angle, or \
        respectfully sharpen/challenge an assumption in it, rather than restating it. The \
        goal is for the user to sound like the sharpest, most prepared, most specific person \
        in the room - not to fill silence with a throwaway line. No preamble, no labels, no \
        meta-commentary, no questions directed at the user - just the words themselves, \
        exactly as the user would say them to the room.

        Language: always reply in the SAME language as the specific question or statement \
        you are responding to right now - not the dominant language of the meeting overall. \
        If that line was asked in English, answer in English, even if earlier parts of the \
        meeting were in Hindi or another language, and vice versa. Do not switch languages \
        just because the conversation around it was in a different one, and do not mix \
        languages within a single reply unless the question itself did.
        """
    }

    /// The inverse of the meeting instruction: here the user IS talking directly to the
    /// assistant (they triggered this mode deliberately), so it should behave like a
    /// normal helpful voice assistant - the opposite of "never address the user".
    static func personalAssistantInstruction(agentName: String) -> String {
        """
        You are "\(agentName)", the user's personal assistant. They are talking directly \
        to you right now and expect you to respond - answer questions, help them think \
        things through, or do what they ask. Be concise, helpful, and conversational.
        """
    }

    func stopLiveSession() {
        liveClient?.disconnect()
        liveClient = nil
        isLiveSessionActive = false
        activeHeardIndex = nil
        activeSuggestionIndex = nil
        // Stopping/restarting listening is a session boundary too - the next utterance
        // after a restart should start a fresh bubble, not resume overwriting the last one
        activeYouIndex = nil
    }

    /// Forwards a system-audio chunk (other participants) to the live session, if connected
    func sendLiveAudioChunk(_ data: Data) {
        liveClient?.sendAudioChunk(data)
    }

    /// Forwards a screen frame to the live session, if one is connected
    func sendLiveImageChunk(_ jpegData: Data) {
        liveClient?.sendImageChunk(jpegData)
    }

    /// Internal rather than private, deliberately: this is pure state-mutation logic given
    /// an event (no networking inside it), so tests drive it directly with synthetic
    /// GeminiLiveEvent values instead of needing a real WebSocket round trip - the same
    /// test-seam reasoning as the injectable speechRecognizer/apiKeyProvider above.
    func handleLiveEvent(_ event: GeminiLiveEvent) {
        switch event {
        case .connected:
            isLiveSessionActive = true

        case .inputTranscript(let delta):
            // Meeting mode: this is the OTHER participants (system audio) - show it.
            // Personal Assistant mode: this is a transcript of the user's own mic, which
            // the local on-device recognizer already shows as a "You" bubble, so skip it
            // here to avoid a duplicate.
            guard mode == .meeting else { break }
            if activeSuggestionIndex != nil { activeSuggestionIndex = nil }
            if let index = activeHeardIndex {
                messages[index].text += delta
            } else {
                appendMessage(ChatMessage(role: .heard, text: delta), trackAs: \.activeHeardIndex)
            }

        case .textDelta(let delta):
            activeHeardIndex = nil
            let role: ChatMessage.Role = mode == .meeting ? .suggestion : .assistantReply
            if let index = activeSuggestionIndex {
                messages[index].text += delta
            } else {
                appendMessage(ChatMessage(role: role, text: delta, isStreaming: true), trackAs: \.activeSuggestionIndex)
            }

        case .turnComplete:
            if let index = activeSuggestionIndex {
                messages[index].isStreaming = false
            }
            activeSuggestionIndex = nil
            // A reply successfully completing (not merely starting - an interrupted one
            // never reaches here) is what closes out whatever "You" utterance prompted it.
            // The next thing you say should start a new bubble, not keep overwriting this
            // one. Personal Assistant mode has no other signal for this boundary, since
            // Gemini's own inputTranscript is deliberately ignored there (see above).
            activeYouIndex = nil

        case .interrupted:
            // Nothing is ever removed from the chat, even a reply that got cut off
            // mid-thought - it just stops streaming and stays exactly as far as it got.
            // The next reply starts a fresh bubble via activeSuggestionIndex below.
            if let index = activeSuggestionIndex, messages.indices.contains(index) {
                messages[index].isStreaming = false
            }
            activeSuggestionIndex = nil

        case .error, .disconnected:
            isLiveSessionActive = false
            // A spontaneous drop (idle timeout, network blip) must not leave liveClient
            // pointing at a dead connection - startLiveSession()'s `guard liveClient == nil`
            // would then silently refuse to reconnect forever, even across an explicit
            // Stop/Start cycle, since nothing else on the normal Start path clears it.
            liveClient?.disconnect()
            liveClient = nil
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
