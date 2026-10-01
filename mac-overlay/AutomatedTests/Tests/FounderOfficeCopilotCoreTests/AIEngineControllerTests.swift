import XCTest
@testable import FounderOfficeCopilotCore

/// Covers AIEngineController's own remaining responsibility after the Phase 1 multi-session
/// refactor: owning the two Gemini connections and translating their events into
/// ChatSessionManager calls. The message-accumulation logic itself (Heard bubble merging,
/// Response bubble streaming, responseContext, recording-vs-viewing) moved to
/// ChatSessionManager along with its tests - see ChatSessionManagerTests.swift. Nothing here
/// opens a real network connection (apiKeyProvider returns nil) or touches real saved
/// history (an in-memory ChatSessionStore is injected).
@MainActor
final class AIEngineControllerTests: XCTestCase {
    /// Every call site below builds its OWN fresh in-memory `MemoryManager`/`ProjectManager`
    /// pair (via this helper or inline) and passes them explicitly to `AIEngineController` -
    /// its `memoryManager`/`projectManager` parameters default to REAL, on-disk-backed
    /// instances (see its own doc comment), so omitting them here would silently construct
    /// real Core Data stores during an automated test run, the same risk class
    /// `makeInertExtractionCoordinator()` already exists to avoid for `extractionCoordinator`.
    private static func makeInertManagers() -> (memory: MemoryManager, project: ProjectManager) {
        (MemoryManager(store: MemoryStore(inMemory: true)), ProjectManager(store: ProjectStore(inMemory: true)))
    }

    private func makeEngine(extractionCoordinator: ExtractionCoordinator? = nil) -> AIEngineController {
        // Explicitly injects an in-memory-backed ExtractionCoordinator with no API key,
        // rather than letting AIEngineController fall back to its real default
        // (ExtractionCoordinator()'s default apiKeyProvider reads the REAL Keychain via
        // SettingsStore.shared.geminiAPIKey) - without this, these tests could silently
        // attempt a real network call if a real key happens to be configured on the machine
        // running them. See ExtractionCoordinatorTests.swift for the actual extraction
        // pipeline coverage; this file only needs extraction to be safely inert.
        let managers = Self.makeInertManagers()
        let coordinator = extractionCoordinator ?? Self.makeInertExtractionCoordinator(memoryManager: managers.memory, projectManager: managers.project)
        let engine = AIEngineController(
            chatSessionManager: ChatSessionManager(store: ChatSessionStore(inMemory: true)),
            memoryManager: managers.memory,
            projectManager: managers.project,
            extractionCoordinator: coordinator
        )
        engine.apiKeyProvider = { nil }
        return engine
    }

    private static func makeInertExtractionCoordinator(memoryManager: MemoryManager? = nil, projectManager: ProjectManager? = nil) -> ExtractionCoordinator {
        let managers = (memoryManager, projectManager)
        let coordinator = ExtractionCoordinator(
            memoryManager: managers.0 ?? MemoryManager(store: MemoryStore(inMemory: true)),
            projectManager: managers.1 ?? ProjectManager(store: ProjectStore(inMemory: true))
        )
        coordinator.apiKeyProvider = { nil }
        return coordinator
    }

    func testInitialStateIsInactiveAndNotListening() {
        let engine = makeEngine()
        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isListening)
    }

    func testStartSetsActiveAndListening() {
        let engine = makeEngine()
        engine.start()
        XCTAssertTrue(engine.isActive)
        XCTAssertTrue(engine.isListening, "the status dot must go green on Start regardless of whether a Gemini key is configured")
    }

    func testStopClearsActiveAndListening() {
        let engine = makeEngine()
        engine.start()
        engine.stop()

        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isListening)
    }

    func testStartWithNoAPIKeyDoesNotCreateALiveSession() {
        let engine = makeEngine()
        engine.start()
        XCTAssertFalse(engine.isLiveSessionActive)
    }

    // MARK: Delegation to ChatSessionManager for recording lifecycle

    func testStartBeginsARecordingSessionRegardlessOfAPIKey() {
        // Recording/persistence is independent of whether a Gemini key is configured - the
        // session exists and is ready to receive content the moment listening starts, same
        // as isListening going true regardless of the key.
        let engine = makeEngine()
        XCTAssertNil(engine.chatSessionManager.recordingSessionID)
        engine.start()
        XCTAssertNotNil(engine.chatSessionManager.recordingSessionID)
    }

    func testStopEndsTheRecordingSessionButKeepsItInHistory() {
        let engine = makeEngine()
        engine.start()
        let recordingID = engine.chatSessionManager.recordingSessionID
        engine.stop()

        XCTAssertNil(engine.chatSessionManager.recordingSessionID)
        XCTAssertTrue(engine.chatSessionManager.sessions.contains { $0.id == recordingID }, "stopping must never delete the session, only stop it receiving new content")
    }

    func testUnifiedInstructionDescribesAOneShotResponseAndIncludesAgentName() {
        let instruction = AIEngineController.unifiedInstruction(agentName: "Friday")
        XCTAssertTrue(instruction.contains("Friday"))
        XCTAssertTrue(instruction.lowercased().contains("newest"))
        XCTAssertTrue(instruction.lowercased().contains("one substantive"))
    }

    func testUnifiedInstructionExplainsRecencyPriorityOverEarlierContext() {
        let instruction = AIEngineController.unifiedInstruction(agentName: "Friday")
        XCTAssertTrue(instruction.lowercased().contains("follow-up"), "must explain when earlier context should be used")
        XCTAssertTrue(instruction.lowercased().contains("unrelated topic"), "must explain the newest content should stand on its own if unrelated to what came before")
    }

    // MARK: Live-event delegation

    func testInputTranscriptEventsAreForwardedToTheRecordingSession() {
        let engine = makeEngine()
        engine.start()
        engine.handleLiveEvent(.inputTranscript("hello"))

        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.count, 1)
        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.first?.text, "hello")
        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.first?.role, .heard)
    }

    func testTextDeltaTurnCompleteAndInterruptedAreNoOpsOnTheTranscriptionOnlyConnection() {
        let engine = makeEngine()
        engine.start()
        engine.handleLiveEvent(.inputTranscript("hello"))

        engine.handleLiveEvent(.textDelta("should be ignored"))
        engine.handleLiveEvent(.turnComplete)
        engine.handleLiveEvent(.interrupted)

        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.count, 1, "no Response bubble should ever be created from Live events")
    }

    func testSessionResumptionUpdateIsStashedWithoutTouchingMessages() {
        let engine = makeEngine()
        engine.start()
        engine.handleLiveEvent(.sessionResumptionUpdate(handle: "abc123"))
        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.count, 0)
    }

    // MARK: requestResponse() guard clauses

    func testRequestResponseIsANoOpWithoutAnAPIKey() {
        let engine = makeEngine()
        engine.start()
        engine.handleLiveEvent(.inputTranscript("hello"))

        engine.requestResponse()

        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.count, 1, "still just the heard bubble - no response requested without a key")
    }

    func testRequestResponseIsANoOpWithNoHeardTranscriptYet() {
        let managers = Self.makeInertManagers()
        let engine = AIEngineController(
            chatSessionManager: ChatSessionManager(store: ChatSessionStore(inMemory: true)),
            memoryManager: managers.memory,
            projectManager: managers.project,
            extractionCoordinator: Self.makeInertExtractionCoordinator(memoryManager: managers.memory, projectManager: managers.project)
        )
        var keyIsConfigured = false
        // Starts with no key so start() never opens a real Live connection, then "configures"
        // a key only for the requestResponse() call below - isolates the empty-transcript
        // guard from the API-key guard without ever touching the network.
        engine.apiKeyProvider = { keyIsConfigured ? "fake-key-never-sent" : nil }
        engine.start()

        keyIsConfigured = true
        engine.requestResponse()

        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.count, 0, "nothing has been heard yet, so there is nothing to respond to")
    }

    // MARK: Live-event writes always target the recording session, independent of viewing

    func testInputTranscriptStillTargetsTheRecordingSessionWhileViewingSomewhereElse() {
        let engine = makeEngine()
        engine.start()
        engine.handleLiveEvent(.inputTranscript("in the recording session"))

        let otherID = engine.chatSessionManager.createSession(title: "Somewhere else")
        engine.chatSessionManager.switchViewing(to: otherID)
        engine.handleLiveEvent(.inputTranscript(" - more"))

        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.first?.text, "in the recording session - more")
        XCTAssertTrue(engine.chatSessionManager.viewingSession?.messages.isEmpty ?? false, "viewing another session must never receive new heard content")
    }

    // MARK: Extraction integration (Phase 3.3) - categories 24/25: failure isolation, no blocking

    func testStopCompletesPromptlyEvenWithExtractionWiredIn() {
        let engine = makeEngine()
        engine.start()
        engine.handleLiveEvent(.inputTranscript("I prefer dark mode, this is long enough to be worth extracting."))

        let start = Date()
        engine.stop()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.25, "stop() must return promptly regardless of extraction being wired in - extraction is fire-and-forget, never awaited")
        XCTAssertFalse(engine.isActive)
    }

    func testRecordingContinuesNormallyWhenExtractionAlwaysFails() {
        let stub = StubExtractionLLMClient()
        stub.alwaysFail = true
        let coordinator = ExtractionCoordinator(
            memoryManager: MemoryManager(store: MemoryStore(inMemory: true)),
            projectManager: ProjectManager(store: ProjectStore(inMemory: true)),
            llmClient: stub,
            apiKeyProvider: { "test-key-not-real" },
            model: { "test-model" }
        )
        coordinator.maxRetryCount = 1
        coordinator.retryBackoffBase = 0.01

        let engine = makeEngine(extractionCoordinator: coordinator)
        engine.start()
        engine.handleLiveEvent(.inputTranscript("I prefer dark mode, this is long enough to be worth extracting."))

        XCTAssertEqual(engine.chatSessionManager.recordingSession?.messages.count, 1, "transcription must be completely unaffected by extraction failing")

        engine.stop()

        XCTAssertFalse(engine.isActive)
        XCTAssertNil(engine.chatSessionManager.recordingSessionID)
        XCTAssertEqual(engine.chatSessionManager.sessions.first?.messages.count, 1, "the heard content must survive regardless of extraction's outcome")
    }

    // MARK: Phase 3 - on-demand screen frame (Option B)
    //
    // Capture happens ONLY because a response was requested. These tests cover every path that
    // must NOT capture; the positive path (⌘⇧R with a key configured) continues into
    // GeminiResponseGenerator's real network call, so it is verified manually rather than here -
    // XCTest must never make a real request. The payload shape itself is covered offline by
    // GeminiResponseGeneratorTests.

    func testNoScreenCaptureWhileNotActive() {
        let engine = makeEngine()
        let provider = StubScreenFrameProvider(frameToReturn: Data([0xFF, 0xD8]))
        engine.screenFrameProvider = provider
        engine.apiKeyProvider = { "test-key-not-real" }
        engine.chatSessionManager.beginRecording()
        engine.chatSessionManager.appendHeardDelta("something worth answering")

        XCTAssertFalse(engine.isActive)
        engine.requestResponse()

        XCTAssertEqual(provider.captureCount, 0, "the screen must never be captured while not listening")
    }

    func testNoScreenCaptureWithoutAnAPIKey() {
        let engine = makeEngine()
        let provider = StubScreenFrameProvider(frameToReturn: Data([0xFF, 0xD8]))
        engine.screenFrameProvider = provider
        engine.apiKeyProvider = { nil }
        engine.isActive = true
        engine.chatSessionManager.beginRecording()
        engine.chatSessionManager.appendHeardDelta("something worth answering")

        engine.requestResponse()

        XCTAssertEqual(provider.captureCount, 0, "no key means no request - and therefore no capture")
    }

    func testNoScreenCaptureWhenThereIsNothingNewToAnswer() {
        let engine = makeEngine()
        let provider = StubScreenFrameProvider(frameToReturn: Data([0xFF, 0xD8]))
        engine.screenFrameProvider = provider
        engine.apiKeyProvider = { "test-key-not-real" }
        engine.isActive = true
        engine.chatSessionManager.beginRecording()
        // Nothing heard since the last response - requestResponse() is a no-op.

        engine.requestResponse()

        XCTAssertEqual(provider.captureCount, 0, "an empty turn must not trigger a screenshot")
    }

    func testNoScreenCaptureAfterStop() {
        let engine = makeEngine()
        let provider = StubScreenFrameProvider(frameToReturn: Data([0xFF, 0xD8]))
        engine.screenFrameProvider = provider
        engine.apiKeyProvider = { "test-key-not-real" }
        engine.isActive = true
        engine.chatSessionManager.beginRecording()
        engine.chatSessionManager.appendHeardDelta("something worth answering")

        engine.stop()
        engine.requestResponse()

        XCTAssertFalse(engine.isActive, "stop() closes the master gate")
        XCTAssertEqual(provider.captureCount, 0, "no capture may happen after stop()")
    }

    /// The frame must not leak into retrieval: `retrievedContextText(forCurrentTurn:)` is derived
    /// from the untrimmed turn and knows nothing about screen content, so Phase 4.2's grounding
    /// and project isolation are unaffected by Phase 3.
    func testScreenFrameNeverEntersTheRetrievalQuery() {
        let engine = makeEngine()
        engine.screenFrameProvider = StubScreenFrameProvider(frameToReturn: Data(repeating: 0xAB, count: 4_096))
        engine.chatSessionManager.beginRecording()
        engine.chatSessionManager.appendHeardDelta("what is the current status?")

        let context = engine.chatSessionManager.responseContext()
        let retrieved = engine.retrievedContextText(forCurrentTurn: context.currentTurn)

        XCTAssertNotNil(retrieved)
        XCTAssertFalse(retrieved?.contains("image/jpeg") ?? false)
        XCTAssertFalse(retrieved?.contains(Data(repeating: 0xAB, count: 16).base64EncodedString()) ?? false)
    }
}
