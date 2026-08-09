import XCTest
@testable import FounderOfficeCopilotCore

/// These fixtures are real message shapes captured from the actual Gemini Live API during
/// manual testing this session (not guessed from docs) - this is exactly the parsing logic
/// that caused real, hard-to-diagnose bugs earlier (wrong response modality assumption,
/// mixed text/binary WebSocket frames), so it's worth pinning down with real examples.
final class GeminiLiveMessageParserTests: XCTestCase {
    func testSetupCompleteProducesConnectedEvent() {
        let events = GeminiLiveMessageParser.parse(#"{"setupComplete": {}}"#)
        XCTAssertEqual(events.count, 1)
        guard case .connected = events[0] else {
            return XCTFail("expected .connected, got \(events[0])")
        }
    }

    func testInputTranscriptionProducesInputTranscriptEvent() {
        let json = #"{"serverContent": {"inputTranscription": {"text": " I think"}}}"#
        let events = GeminiLiveMessageParser.parse(json)
        XCTAssertEqual(events.count, 1)
        guard case .inputTranscript(let text) = events[0] else {
            return XCTFail("expected .inputTranscript, got \(events[0])")
        }
        XCTAssertEqual(text, " I think")
    }

    func testOutputTranscriptionProducesTextDeltaEvent() {
        // Response modality is AUDIO (every available Live model requires this - confirmed
        // against the real API), so the model's reply text only ever arrives via
        // outputTranscription, never as a "text" part on modelTurn.
        let json = #"{"serverContent": {"outputTranscription": {"text": "Retention specifically,"}}}"#
        let events = GeminiLiveMessageParser.parse(json)
        XCTAssertEqual(events.count, 1)
        guard case .textDelta(let text) = events[0] else {
            return XCTFail("expected .textDelta, got \(events[0])")
        }
        XCTAssertEqual(text, "Retention specifically,")
    }

    func testModelTurnWithOnlyAudioInlineDataProducesNoTextDelta() {
        // Confirms audio bytes in modelTurn.parts are never misread as text
        let json = """
        {"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "AAA="}}]}}}
        """
        let events = GeminiLiveMessageParser.parse(json)
        XCTAssertTrue(events.isEmpty, "audio-only modelTurn parts should produce no events")
    }

    func testInterruptedProducesInterruptedEvent() {
        let events = GeminiLiveMessageParser.parse(#"{"serverContent": {"interrupted": true}}"#)
        XCTAssertEqual(events.count, 1)
        guard case .interrupted = events[0] else {
            return XCTFail("expected .interrupted, got \(events[0])")
        }
    }

    func testTurnCompleteProducesTurnCompleteEvent() {
        let json = #"{"serverContent": {"turnComplete": true}, "usageMetadata": {"promptTokenCount": 164}}"#
        let events = GeminiLiveMessageParser.parse(json)
        XCTAssertEqual(events.count, 1)
        guard case .turnComplete = events[0] else {
            return XCTFail("expected .turnComplete, got \(events[0])")
        }
    }

    func testInterruptedAndTurnCompleteCanArriveTogether() {
        let json = #"{"serverContent": {"interrupted": true, "turnComplete": true}}"#
        let events = GeminiLiveMessageParser.parse(json)
        XCTAssertEqual(events.count, 2)
    }

    func testUnrelatedTopLevelMessageProducesNoEvents() {
        // e.g. sessionResumptionUpdate - a real message type the app deliberately ignores
        let json = #"{"sessionResumptionUpdate": {"newHandle": "abc-123", "resumable": true}}"#
        XCTAssertTrue(GeminiLiveMessageParser.parse(json).isEmpty)
    }

    func testMalformedJSONProducesNoEventsAndDoesNotCrash() {
        XCTAssertTrue(GeminiLiveMessageParser.parse("not json at all").isEmpty)
        XCTAssertTrue(GeminiLiveMessageParser.parse("").isEmpty)
    }

    func testEmptyServerContentProducesNoEvents() {
        // A bare ack the API sometimes sends mid-turn
        XCTAssertTrue(GeminiLiveMessageParser.parse(#"{"serverContent": {}}"#).isEmpty)
    }
}
