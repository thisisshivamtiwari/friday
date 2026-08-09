import XCTest
@testable import FounderOfficeCopilotCore

/// Never touches TCC-gated APIs (SFSpeechRecognizer.requestAuthorization) or the network -
/// macOS hard-crashes any process lacking an Info.plist usage-description key that calls
/// the former, which is true of this CLI test binary, and the latter would otherwise open a
/// real Gemini connection using whatever key is saved in this Mac's real Keychain entry.
final class NoOpTranscriptSource: TranscriptSource {
    var onTranscriptUpdate: ((String) -> Void)?
    func start() {}
    func stop() {}
}

/// Covers the exact state-machine bugs reported in manual testing this session: the
/// status dot staying green regardless of Stop, and Stop not actually halting output.
@MainActor
final class AIEngineControllerTests: XCTestCase {
    /// Builds an engine with test doubles wired in - see NoOpTranscriptSource above for why
    private func makeEngine() -> AIEngineController {
        let engine = AIEngineController(speechRecognizer: NoOpTranscriptSource())
        engine.apiKeyProvider = { nil }
        return engine
    }

    func testInitialStateIsInactiveAndNotListening() {
        let engine = makeEngine()
        XCTAssertFalse(engine.isActive)
        XCTAssertFalse(engine.isListening)
        XCTAssertEqual(engine.mode, .meeting)
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
        XCTAssertFalse(engine.isListening, "the status dot must go red on Stop - this was the reported bug (stuck green)")
    }

    func testToggleModeFlipsBetweenMeetingAndPersonalAssistant() {
        let engine = makeEngine()
        XCTAssertEqual(engine.mode, .meeting)
        engine.toggleMode()
        XCTAssertEqual(engine.mode, .personalAssistant)
        engine.toggleMode()
        XCTAssertEqual(engine.mode, .meeting)
    }

    func testToggleModeDoesNotChangeActiveState() {
        let engine = makeEngine()
        engine.start()
        engine.toggleMode()
        XCTAssertTrue(engine.isActive, "switching modes must not itself stop listening")
    }

    func testStartWithNoAPIKeyDoesNotCreateALiveSession() {
        // apiKeyProvider returns nil in makeEngine() - this is the "no key configured"
        // path, and it must never claim to be live
        let engine = makeEngine()
        engine.start()
        XCTAssertFalse(engine.isLiveSessionActive)
    }

    // MARK: System instruction content - locks in the exact behavioral fix from this session

    func testMeetingInstructionForbidsAddressingTheUser() {
        let instruction = AIEngineController.meetingInstruction(agentName: "Friday")
        XCTAssertTrue(instruction.contains("SILENT"))
        XCTAssertTrue(instruction.contains("not talking to you"))
        XCTAssertTrue(instruction.lowercased().contains("never ask the user a question"))
    }

    func testPersonalAssistantInstructionExpectsDirectAddress() {
        let instruction = AIEngineController.personalAssistantInstruction(agentName: "Friday")
        XCTAssertTrue(instruction.contains("talking directly"))
        XCTAssertFalse(instruction.contains("SILENT"), "personal assistant mode must not carry over the meeting mode's silence constraint")
    }

    // MARK: Message history bugs (reported via screenshots showing a stuck first reply and
    // a single "You" bubble getting overwritten forever instead of the chat accumulating)

    private func makeEngineWithRecognizer() -> (engine: AIEngineController, recognizer: NoOpTranscriptSource) {
        let recognizer = NoOpTranscriptSource()
        let engine = AIEngineController(speechRecognizer: recognizer)
        engine.apiKeyProvider = { nil }
        return (engine, recognizer)
    }

    /// NoOpTranscriptSource's onTranscriptUpdate is delivered via DispatchQueue.main.async
    /// inside AIEngineController - queuing this fulfill immediately after triggering it
    /// guarantees (FIFO on a serial queue) that the update has already been applied by the
    /// time this returns, without an arbitrary sleep.
    private func waitForMainQueue() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func testEachUtteranceGetsItsOwnYouBubbleOnceThePreviousOneIsAnswered() {
        let (engine, recognizer) = makeEngineWithRecognizer()
        engine.mode = .personalAssistant

        recognizer.onTranscriptUpdate?("first question")
        waitForMainQueue()
        XCTAssertEqual(engine.messages.count, 1)

        // A reply starting is the only signal (in Personal Assistant mode) that this "You"
        // utterance is done and answered
        engine.handleLiveEvent(.textDelta("answer one"))
        engine.handleLiveEvent(.turnComplete)

        recognizer.onTranscriptUpdate?("second question")
        waitForMainQueue()

        XCTAssertEqual(engine.messages.count, 3, "You(first), Assistant(answer), You(second) - not one bubble silently overwritten forever")
        XCTAssertEqual(engine.messages[0].text, "first question")
        XCTAssertEqual(engine.messages[1].text, "answer one")
        XCTAssertEqual(engine.messages[2].text, "second question")
    }

    func testInterruptionKeepsTheHalfFinishedReplyInsteadOfDeletingIt() {
        let (engine, recognizer) = makeEngineWithRecognizer()
        engine.mode = .personalAssistant

        recognizer.onTranscriptUpdate?("question")
        waitForMainQueue()

        engine.handleLiveEvent(.textDelta("partial answer"))
        XCTAssertEqual(engine.messages.count, 2)

        engine.handleLiveEvent(.interrupted)
        XCTAssertEqual(engine.messages.count, 2, "nothing is ever removed from the chat, even a reply that got cut off")
        XCTAssertEqual(engine.messages[0].text, "question")
        XCTAssertEqual(engine.messages[1].text, "partial answer", "the half-finished reply stays exactly as far as it got")
        XCTAssertFalse(engine.messages[1].isStreaming, "it stops streaming/pulsing once interrupted, even though it stays")

        // The next reply must start a fresh bubble, not append onto the interrupted one
        engine.handleLiveEvent(.textDelta("second answer"))
        XCTAssertEqual(engine.messages.count, 3)
        XCTAssertEqual(engine.messages[2].text, "second answer")
    }

    func testIdenticalRepeatedTranscriptDoesNotDuplicateTheYouBubble() {
        let (engine, recognizer) = makeEngineWithRecognizer()
        engine.mode = .personalAssistant

        recognizer.onTranscriptUpdate?("question")
        waitForMainQueue()
        XCTAssertEqual(engine.messages.count, 1)

        // A reply completing closes out the You bubble, same as any other turn
        engine.handleLiveEvent(.textDelta("answer"))
        engine.handleLiveEvent(.turnComplete)
        XCTAssertEqual(engine.messages.count, 2)

        // SFSpeechRecognizer redelivers the exact same text verbatim - no new speech
        // happened, so this must not create a visible duplicate of the question
        recognizer.onTranscriptUpdate?("question")
        waitForMainQueue()
        XCTAssertEqual(engine.messages.count, 2, "an identical repeated transcript must not duplicate the You bubble")
        XCTAssertEqual(engine.messages[0].text, "question")

        // A genuinely different utterance afterward must still get its own fresh bubble
        recognizer.onTranscriptUpdate?("a different question")
        waitForMainQueue()
        XCTAssertEqual(engine.messages.count, 3)
        XCTAssertEqual(engine.messages[2].text, "a different question")
    }
}
