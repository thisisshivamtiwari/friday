import XCTest
@testable import FounderOfficeCopilotCore

/// Covers the state machine and message-accumulation logic for the single always-on
/// assistant: start/stop, and the heard/response bubble bookkeeping in handleLiveEvent
/// (made internal rather than private specifically so these can be driven directly with
/// synthetic events, without a real Gemini network connection - see its doc comment).
@MainActor
final class AIEngineControllerTests: XCTestCase {
    /// apiKeyProvider returning nil keeps every test from opening a real network
    /// connection using whatever key happens to be saved in this Mac's real Keychain
    private func makeEngine() -> AIEngineController {
        let engine = AIEngineController()
        engine.apiKeyProvider = { nil }
        return engine
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
        // apiKeyProvider returns nil in makeEngine() - this is the "no key configured"
        // path, and it must never claim to be live
        let engine = makeEngine()
        engine.start()
        XCTAssertFalse(engine.isLiveSessionActive)
    }

    func testUnifiedInstructionNeverSpeaksAutomaticallyButAnswersWhenTriggered() {
        let instruction = AIEngineController.unifiedInstruction(agentName: "Friday")
        XCTAssertTrue(instruction.contains("never speak up on your own"))
        XCTAssertTrue(instruction.lowercased().contains("only produce a") || instruction.lowercased().contains("only ever"))
        XCTAssertTrue(instruction.contains("Friday"))
    }

    // MARK: Message accumulation (heard/response bubbles)

    func testInputTranscriptAccumulatesIntoASingleHeardBubbleUntilAResponse() {
        let engine = makeEngine()

        engine.handleLiveEvent(.inputTranscript("Hello"))
        engine.handleLiveEvent(.inputTranscript(" there"))
        XCTAssertEqual(engine.messages.count, 1, "deltas for the same stretch of speech accumulate into one bubble")
        XCTAssertEqual(engine.messages[0].text, "Hello there")
        XCTAssertEqual(engine.messages[0].role, .heard)
    }

    func testResponseStreamsIntoOneBubbleThenClosesOutOnTurnComplete() {
        let engine = makeEngine()
        engine.handleLiveEvent(.inputTranscript("What's the plan"))

        engine.handleLiveEvent(.textDelta("Let's "))
        engine.handleLiveEvent(.textDelta("start with X."))
        XCTAssertEqual(engine.messages.count, 2)
        XCTAssertEqual(engine.messages[1].text, "Let's start with X.")
        XCTAssertEqual(engine.messages[1].role, .response)
        XCTAssertTrue(engine.messages[1].isStreaming)

        engine.handleLiveEvent(.turnComplete)
        XCTAssertFalse(engine.messages[1].isStreaming)

        // A new stretch of speech after a response must start a fresh Heard bubble, not
        // resume appending to the one from before the response
        engine.handleLiveEvent(.inputTranscript("Next question"))
        XCTAssertEqual(engine.messages.count, 3)
        XCTAssertEqual(engine.messages[2].text, "Next question")
    }

    func testInterruptionKeepsTheHalfFinishedResponseInsteadOfDeletingIt() {
        let engine = makeEngine()
        engine.handleLiveEvent(.inputTranscript("question"))
        engine.handleLiveEvent(.textDelta("partial answer"))
        XCTAssertEqual(engine.messages.count, 2)

        engine.handleLiveEvent(.interrupted)
        XCTAssertEqual(engine.messages.count, 2, "nothing is ever removed from the chat, even a response that got cut off")
        XCTAssertEqual(engine.messages[1].text, "partial answer")
        XCTAssertFalse(engine.messages[1].isStreaming, "it stops streaming once interrupted, even though it stays")

        engine.handleLiveEvent(.textDelta("second answer"))
        XCTAssertEqual(engine.messages.count, 3, "the next response must start a fresh bubble, not append onto the interrupted one")
    }
}
