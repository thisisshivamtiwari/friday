import Foundation

// MARK: - AI Engine Controller
/// Orchestrates the live Gemini transcription session and on-demand response generation - it
/// no longer owns chat content itself. Audio (mic + system, whoever's talking) streams to a
/// Gemini Live session continuously the whole time it's active, transcribed using Gemini's
/// own automatic voice-activity-detection - that connection is deliberately never asked to
/// produce a reply. Every transcribed delta and every response is written through to
/// `chatSessionManager` rather than kept here, which is what makes multi-chat possible
/// without this class needing to know anything about "sessions" beyond calling into it.
///
/// A "Response" comes from requestResponse(), a one-shot REST call (GeminiResponseGenerator)
/// grounded in the recording session's accumulated transcript text, not in the Live session's
/// own turn state. This is deliberate: the Live connection can drop and reconnect (idle
/// timeout, network blip) without losing the ability to answer - at most a few seconds of
/// transcription are lost, never the whole conversation's context.
///
/// Without a configured API key, the app simply produces no transcription/responses rather
/// than inventing disconnected-from-reality ones.
/// https://developer.apple.com/documentation/combine/observableobject
final class AIEngineController: ObservableObject {
    let chatSessionManager: ChatSessionManager
    /// Phase 4.1 - exposed (not just held internally by `extractionCoordinator`/`contextEngine`)
    /// specifically so the UI can create projects and assign/reassign/unassign sessions,
    /// mirroring exactly how `chatSessionManager` is already exposed for the sidebar's own
    /// actions. This is the SAME instance passed to `extractionCoordinator`/`contextEngine`
    /// below - there is only ever one `ProjectManager` object graph per running app, so a link
    /// created here is immediately visible to both the write and read paths.
    let projectManager: ProjectManager
    /// Exposed for exactly the same reason `projectManager` above is, and on the same terms:
    /// the Graph UI resolves `Decision.madeBy` / `ProjectItem.assignedTo` person ids to names,
    /// and it must read them from THIS instance - the one already handed to
    /// `extractionCoordinator` and `KeywordGraphRetrievalProvider` below - so a person created
    /// by extraction a moment ago is visible immediately rather than only after the next
    /// launch's reload from disk. Constructing a second `MemoryManager` for the UI would open a
    /// second handle on the same store and drift from what the running assistant is using.
    let memoryManager: MemoryManager
    /// Owns the Memory/Project extraction pipeline - see its own doc comment. AIEngineController
    /// only ever calls `turnFinalized(...)`, which returns immediately (fire-and-forget); no
    /// path here waits on or is affected by extraction in any way. GeminiResponseGenerator and
    /// the audio/transcription pipeline remain completely unaware this exists.
    private let extractionCoordinator: ExtractionCoordinator
    /// Stage 7 - the read path counterpart to `extractionCoordinator`'s write path. Built from
    /// the SAME `memoryManager`/`projectManager` instances passed to `extractionCoordinator`
    /// (see init below) so a fact extracted earlier in the same running session is actually
    /// visible to retrieval, not just after the next app launch's fresh reload from disk.
    /// `GeminiResponseGenerator` never sees this - see `retrievedContextText(forCurrentTurn:)`
    /// and `ContextPacketFormatter` for the only place its output crosses into a prompt.
    private let contextEngine: ContextEngine
    /// Guards against sending the same heard bubble to extraction twice - both
    /// requestResponse() and stop() can observe the same still-accumulating heard message.
    private var lastExtractedHeardMessageID: UUID?
    @Published var isListening: Bool = false
    @Published var teamsParticipants: [String] = []
    /// True while a Gemini Live session is connected
    @Published var isLiveSessionActive: Bool = false
    /// True between "Start listening" and "Stop listening" - the master gate. When false,
    /// nothing (the live session, reconnect attempts) is allowed to run.
    @Published var isActive: Bool = false

    /// Whether a response can be generated at all. The ONE genuine precondition for Chat, and
    /// separate from `isActive` (audio) on purpose - see `requestResponse()`.
    var hasAPIKey: Bool { apiKeyProvider()?.isEmpty == false }
    /// Evidence for responses generated in this run, keyed by response message id. Populated by
    /// `retrievedContextText(forCurrentTurn:)` from the SAME `ContextPacket` the model was given,
    /// so what the UI shows as sources is exactly what informed the answer. See
    /// `ResponseEvidence.swift` for why this is in-memory and never reconstructed from text.
    let responseEvidence = ResponseEvidenceStore()

    private let teamsDetector = TeamsParticipantDetector()
    /// Phase 3 (Option B): supplies ONE screen frame at response time. Injectable so tests can
    /// drive the image path without ScreenCaptureKit or a TCC grant; production gets the real
    /// one-shot capturer. Never started/stopped - there is no stream to run.
    var screenFrameProvider: ScreenFrameProviding = ScreenCaptureManager()

    /// How the Gemini API key is looked up - defaults to the real Keychain-backed
    /// SettingsStore. Tests override this to return nil, so an automated run never opens
    /// a real network connection using a developer's saved key.
    var apiKeyProvider: () -> String? = { SettingsStore.shared.geminiAPIKey }

    private var liveClient: GeminiLiveClient?
    /// The latest session-resumption handle from the server - passed into the next setup
    /// message on reconnect so context survives instead of starting blank. Required for any
    /// session longer than the ~10 minute single-connection lifetime.
    private var lastResumptionHandle: String?
    /// Kept alive for the duration of an in-flight request - GeminiResponseGenerator owns
    /// its own URLSession, which would cancel any outstanding task if the instance were
    /// deallocated before the completion handler fires.
    private var responseGenerator: GeminiResponseGenerator?

    /// `chatSessionManager` defaults to a real, on-disk-backed instance for the running app;
    /// tests inject one built on `ChatSessionStore(inMemory: true)` so nothing ever touches
    /// real saved history. `memoryManager`/`projectManager` likewise default to real, on-disk
    /// instances and exist as explicit parameters (rather than being hidden inside
    /// `extractionCoordinator`/`contextEngine`'s own defaults) specifically so BOTH the write
    /// path and the Stage 7 read path share the exact same in-memory object graph - tests
    /// inject `inMemory: true`-backed instances the same way they already do for
    /// `chatSessionManager`. `extractionCoordinator`/`contextEngine` stay optional purely as
    /// an override seam (tests that need a specific stub LLM client, or a
    /// `KeywordGraphRetrievalProvider` swapped for something deterministic, pass their own);
    /// when nil, both are built from `memoryManager`/`projectManager`/`chatSessionManager` here.
    init(
        chatSessionManager: ChatSessionManager = ChatSessionManager(),
        memoryManager: MemoryManager = MemoryManager(),
        projectManager: ProjectManager = ProjectManager(),
        extractionCoordinator: ExtractionCoordinator? = nil,
        contextEngine: ContextEngine? = nil
    ) {
        self.chatSessionManager = chatSessionManager
        self.projectManager = projectManager
        self.memoryManager = memoryManager
        self.extractionCoordinator = extractionCoordinator ?? ExtractionCoordinator(memoryManager: memoryManager, projectManager: projectManager)
        self.contextEngine = contextEngine ?? ContextEngine(
            retrievalProvider: KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager),
            chatSessionManager: chatSessionManager,
            projectManager: projectManager
        )
        startDetectingTeamsParticipants()
    }

    // MARK: Start / stop (the master on/off switch)

    func start() {
        isActive = true
        isListening = true
        chatSessionManager.beginRecording()
        startLiveSession()
    }

    func stop() {
        isActive = false
        isListening = false
        stopLiveSession()
        // Catches a heard turn that accumulated but never triggered a response before
        // recording stopped - otherwise it would never reach extraction at all.
        extractFinalizedHeardTurnIfNeeded()
        // Only an explicit Stop ends the recording session - see stopLiveSession()'s doc
        // comment for why a transient reconnect-driven disconnect must NOT end up here too.
        chatSessionManager.endRecording()
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
        let client = GeminiLiveClient(
            apiKey: apiKey,
            model: settings.geminiModel,
            systemInstruction: Self.buildSystemInstruction(settings: settings),
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

    /// The system instruction used for on-demand responses (see requestResponse()) - the
    /// Live connection itself no longer gets asked to reply to anything, so this only needs
    /// to describe the one-shot "answer what was heard" behavior, not a dialogue partner.
    /// Explicitly calls out recency priority since the request now carries real multi-turn
    /// history (see ChatSessionManager.responseContext) - the model needs to be told, not
    /// just structurally shown, that earlier turns are background, not what to answer.
    static func unifiedInstruction(agentName: String) -> String {
        """
        You are "\(agentName)", an always-listening personal assistant. You're given some \
        recent conversation for context, followed by the newest thing heard around the \
        user - their own voice and anyone else's, in meetings, calls, or day-to-day life - \
        and asked for exactly one substantive, useful response to the newest part.

        Use the earlier context only when the newest content actually depends on it - a \
        follow-up question, or a reference ("it", "that", "him") pointing at something just \
        discussed. If the newest content is a new, unrelated topic, answer it on its own \
        terms - don't let earlier context pull your answer back toward whatever was \
        discussed before.

        If it looks like the user wants help contributing to a live conversation, phrase \
        it in the FIRST PERSON as something they could say out loud right now, with real \
        structure - a clear point, then a concrete reason or example, not generic filler. \
        If it looks like they're asking you something directly, just answer it plainly and \
        helpfully. If there's a clear question or problem (including a coding/technical \
        problem), solve it directly. No preamble, no meta-commentary about what you're \
        doing - just the useful content itself.

        Language: reply in the same language as whatever you're actually responding to.
        """
    }

    /// `additionalContext` is the Stage 7 `ContextPacketFormatter` output - nil for the Live
    /// session's own system instruction (see `startLiveSession()`, which never passes it: that
    /// connection is transcription-only and never generates a reply, so retrieval-derived
    /// context would have nothing to influence there) and for any call where retrieval found
    /// nothing worth adding (see `retrievedContextText(forCurrentTurn:)`). Internal rather than
    /// private, deliberately, same reasoning as `unifiedInstruction`/`handleLiveEvent`: tests
    /// need to inspect the exact system instruction Stage 7 context injection produces without
    /// driving a real `GeminiResponseGenerator` network call to observe it.
    static func buildSystemInstruction(settings: SettingsStore, additionalContext: String? = nil) -> String {
        var instruction = unifiedInstruction(agentName: settings.agentName)
        if !settings.aboutMe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instruction += "\n\nAbout the user you're helping:\n\(settings.aboutMe)"
        }
        instruction += "\n\n\(settings.rules)"
        if let additionalContext, !additionalContext.isEmpty {
            instruction += "\n\n\(additionalContext)"
        }
        return instruction
    }

    /// Disconnects the Live connection - called both by an explicit stop() (user action) AND
    /// by handleLiveEvent's .error/.disconnected case before a reconnect attempt. Recording
    /// state is deliberately NOT touched here for exactly that reason: a transient drop that
    /// auto-reconnects must keep writing into the SAME recording session throughout, not end
    /// it - only stop() (the user's actual gesture) calls chatSessionManager.endRecording().
    func stopLiveSession() {
        liveClient?.disconnect()
        liveClient = nil
        isLiveSessionActive = false
    }

    /// The entire "respond now" trigger mechanism: builds a bounded, structured conversation
    /// context (recent history + everything new since the last response - see
    /// ChatSessionManager.responseContext) and fires a one-shot REST request for a reply,
    /// completely independent of whether the Live transcription connection is currently up.
    /// A no-op if there's nothing new to respond to, or no API key configured.
    /// Generates one response for whatever is in the current turn.
    ///
    /// Deliberately does NOT require `isActive`. That flag is the AUDIO master switch - it gates
    /// the microphone, system-audio capture and the Gemini Live session - and response generation
    /// needs none of them: `GeminiResponseGenerator` is a plain one-shot REST call that never
    /// touches the live client. Requiring it meant a founder had to switch on the microphone and
    /// open a live audio session merely to TYPE a question in Chat, which is both a poor
    /// experience and more access than the task needs. Listening and answering are now
    /// independent, which is what the architecture already assumed internally.
    ///
    /// What it still requires is real: an API key, a session to write into, and a non-empty turn.
    func requestResponse() {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return }
        let context = chatSessionManager.responseContext()
        guard !context.isEmpty else { return }

        // The heard bubble is about to be closed out by beginResponse() below - capture it
        // for extraction now, while it's still the "last heard message".
        extractFinalizedHeardTurnIfNeeded()

        let settings = SettingsStore.shared
        let generator = GeminiResponseGenerator(apiKey: apiKey, model: settings.responseModel)
        responseGenerator = generator

        guard let messageID = chatSessionManager.beginResponse() else { return }

        let retrieved = retrievedContext(forCurrentTurn: context.currentTurn)
        let additionalContext = retrieved?.text
        // Record what this specific answer was grounded in, against the message that will carry
        // it. Purely additive: `additionalContext` above is the same string it always was.
        if let packet = retrieved?.packet {
            responseEvidence.record(evidenceReferences(from: packet), for: messageID)
        }

        // Phase 3 (Option B): one screen frame, captured ONLY because a response was just
        // requested - not streamed, not scheduled, not retained. It is passed straight into the
        // request and released with it. A nil frame (permission denied, capture failed, no
        // display) produces exactly the pre-Phase-3 text-only request.
        //
        // Deliberately does NOT touch `additionalContext`/retrieval: the frame is not evidence
        // in the ContextPacket sense, so Phase 4.2's grounding and project isolation are
        // untouched by it.
        Task { [weak self] in
            // Opt-in only. When off, no capture is attempted at all - not captured-then-discarded,
            // so nothing is ever read from the screen the user did not ask for.
            let frame = settings.screenContextEnabled ? await self?.screenFrameProvider.captureCurrentFrameJPEG() : nil
            if frame != nil {
                // A frame that informed the answer MUST appear in the sources, or the disclosure
                // is a lie by omission: it would list six sources while the claim actually came
                // from an unlisted screenshot. This is exactly how a hotel codebase visible on
                // screen ended up answering a question the stored context did not cover.
                await MainActor.run { self?.responseEvidence.append(.screen, for: messageID) }
            }
            await MainActor.run {
                generator.generate(
                    systemInstruction: Self.buildSystemInstruction(settings: settings, additionalContext: additionalContext),
                    // Phase 2.5: the character-bounded view. `additionalContext` above is still
                    // derived from the UNTRIMMED `context.currentTurn`, so the retrieval query -
                    // and with it Phase 4.2's evidence-sufficiency grounding - is unaffected by
                    // this cap. Image bytes are NOT text and never count against that budget.
                    context: context.boundedOrderedMessages,
                    screenFrameJPEG: frame,
                    onPartialText: { [weak self] delta in
                        DispatchQueue.main.async {
                            self?.chatSessionManager.appendResponseDelta(delta, messageID: messageID)
                        }
                    },
                    completion: { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.responseGenerator = nil
                            let errorText: String?
                            if case .failure(let error) = result {
                                errorText = "Couldn't get a response: \(error.localizedDescription)"
                            } else {
                                errorText = nil
                            }
                            self.chatSessionManager.completeResponse(messageID: messageID, errorText: errorText)
                            self.extractFinalizedResponseTurn(messageID: messageID)
                        }
                    }
                )
            }
        }
    }

    /// Stage 7's retrieval hook - always driven by `chatSessionManager.recordingSessionID`,
    /// NEVER `viewingSessionID`, so browsing a different session in the sidebar while a
    /// response is generated can never leak that session's project/context into this one (or
    /// vice versa). `currentTurn` is passed in from `requestResponse()`'s own already-computed
    /// `responseContext()` rather than recomputed here, so there is exactly one bounded read
    /// of conversation state per response - this does not reintroduce a second, possibly
    /// diverging notion of "the current conversation."
    ///
    /// Entirely synchronous and in-memory - `ContextEngine`/`KeywordGraphRetrievalProvider`
    /// only ever read already-loaded `@Published` manager arrays (no network, no fresh Core
    /// Data query - see their own doc comments), so this cannot block audio capture,
    /// transcription, the sidebar, or streamed response chunks. There is deliberately no
    /// do/catch here: nothing in this call graph throws or performs I/O, so the graceful-
    /// fallback guarantee ("if retrieval finds/does nothing, requestResponse() proceeds
    /// exactly as before Stage 7") is enforced by these guards returning nil, not by error
    /// recovery - memory retrieval is an enhancement to the response already being generated,
    /// never a precondition for it. Internal rather than private, deliberately - same
    /// `unifiedInstruction`/`handleLiveEvent` reasoning as `buildSystemInstruction` above.
    func retrievedContextText(forCurrentTurn currentTurn: [ChatMessage]) -> String? {
        retrievedContext(forCurrentTurn: currentTurn)?.text
    }

    /// The packet AND its rendered text. Callers that want to show the user where an answer came
    /// from need the structured packet; the rendering is byte-identical to what it always was, so
    /// capturing evidence cannot change the model's input.
    func retrievedContext(forCurrentTurn currentTurn: [ChatMessage]) -> (packet: ContextPacket, text: String)? {
        guard let recordingSessionID = chatSessionManager.recordingSessionID else { return nil }
        let questionText = currentTurn.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !questionText.isEmpty else { return nil }
        let packet = contextEngine.buildContextPacket(forQuestion: questionText, sessionID: recordingSessionID)
        return (packet, ContextPacketFormatter.format(packet, questionText: questionText))
    }

    /// Turns a packet into the user-facing source list, resolving project and conversation names
    /// through the managers this controller already owns.
    private func evidenceReferences(from packet: ContextPacket) -> [AnswerSource] {
        AnswerSourceBuilder.references(
            from: packet,
            currentSessionID: chatSessionManager.recordingSessionID,
            projectNameForItem: { [weak self] itemID in
                guard let item = self?.projectManager.projectItem(id: itemID) else { return nil }
                return self?.projectManager.project(id: item.projectID)?.name
            },
            projectNameForDecision: { [weak self] decisionID in
                guard let decision = self?.projectManager.decision(id: decisionID) else { return nil }
                return self?.projectManager.project(id: decision.projectID)?.name
            },
            sessionTitle: { [weak self] sessionID in
                self?.chatSessionManager.sessions.first { $0.id == sessionID }?.title
            }
        )
    }

    /// Captures the current recording session's last HEARD message (if any, and if not
    /// already sent) and hands it to extraction - fire-and-forget, returns immediately. Called
    /// right before beginResponse() closes out the heard bubble, and from stop() to catch a
    /// heard turn that never triggered a response at all.
    private func extractFinalizedHeardTurnIfNeeded() {
        guard let recordingSessionID = chatSessionManager.recordingSessionID,
              let lastMessage = chatSessionManager.recordingSession?.messages.last,
              lastMessage.role == .heard,
              lastMessage.id != lastExtractedHeardMessageID,
              !lastMessage.text.isEmpty else { return }
        lastExtractedHeardMessageID = lastMessage.id
        extractionCoordinator.turnFinalized(sessionID: recordingSessionID, messageID: lastMessage.id, text: lastMessage.text)
    }

    /// Captures a just-completed RESPONSE message and hands it to extraction - Friday's own
    /// answers can restate/confirm facts worth extracting too, not just what was heard.
    private func extractFinalizedResponseTurn(messageID: UUID) {
        guard let recordingSessionID = chatSessionManager.recordingSessionID,
              let message = chatSessionManager.recordingSession?.messages.first(where: { $0.id == messageID }),
              !message.text.isEmpty else { return }
        extractionCoordinator.turnFinalized(sessionID: recordingSessionID, messageID: message.id, text: message.text)
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

        case .sessionResumptionUpdate(let handle):
            lastResumptionHandle = handle

        case .inputTranscript(let delta):
            chatSessionManager.appendHeardDelta(delta)

        case .textDelta, .turnComplete, .interrupted:
            // This connection is transcription-only now (automatic VAD, no
            // outputAudioTranscription requested) - any reply text/turn-boundary events it
            // still produces internally are irrelevant here. Real responses come from
            // requestResponse()'s one-shot REST call instead.
            break

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

    deinit {
        liveClient?.disconnect()
    }
}
