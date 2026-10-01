import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `TemporalQueryClassifier.classify(_:)` - pure, deterministic, no manager
/// dependencies. Confirms each `Intent` case's cue words are recognized and that the
/// most-specific-first priority ordering (changeReason/whenDecided before historical/current)
/// holds when a question could plausibly match more than one category.
final class TemporalQueryClassifierTests: XCTestCase {

    func testChangeReasonCues() {
        XCTAssertEqual(TemporalQueryClassifier.classify("Why did we change database providers?"), .changeReason)
        XCTAssertEqual(TemporalQueryClassifier.classify("why did I switch from React to Vue"), .changeReason)
        XCTAssertEqual(TemporalQueryClassifier.classify("Why did we move away from microservices"), .changeReason)
        XCTAssertEqual(TemporalQueryClassifier.classify("why did we abandon the old plan"), .changeReason)
    }

    func testWhenDecidedCues() {
        XCTAssertEqual(TemporalQueryClassifier.classify("When did we decide to use Postgres?"), .whenDecided)
        XCTAssertEqual(TemporalQueryClassifier.classify("when was this decided"), .whenDecided)
        XCTAssertEqual(TemporalQueryClassifier.classify("When did we agree on the deadline"), .whenDecided)
    }

    func testHistoricalCues() {
        XCTAssertEqual(TemporalQueryClassifier.classify("What did I use before this?"), .historical)
        XCTAssertEqual(TemporalQueryClassifier.classify("What database did we use previously"), .historical)
        XCTAssertEqual(TemporalQueryClassifier.classify("What was the original approach"), .historical)
    }

    func testCurrentCues() {
        XCTAssertEqual(TemporalQueryClassifier.classify("What do I currently use for auth?"), .current)
        XCTAssertEqual(TemporalQueryClassifier.classify("What are we using right now"), .current)
        XCTAssertEqual(TemporalQueryClassifier.classify("What database am I using at the moment"), .current)
    }

    func testUnspecifiedWhenNoTemporalCuePresent() {
        XCTAssertEqual(TemporalQueryClassifier.classify("Tell me about the professor's research"), .unspecified)
        XCTAssertEqual(TemporalQueryClassifier.classify("What is Retvens?"), .unspecified)
    }

    /// The classifier checks more-specific intents first: a question containing BOTH a
    /// "changeReason" cue and a "historical" cue must resolve to changeReason, not historical.
    func testChangeReasonTakesPriorityOverHistorical() {
        let text = "Why did we change away from what we used before?"
        XCTAssertEqual(TemporalQueryClassifier.classify(text), .changeReason)
    }

    func testWhenDecidedTakesPriorityOverCurrent() {
        let text = "When did we decide what we currently use for the database?"
        XCTAssertEqual(TemporalQueryClassifier.classify(text), .whenDecided)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(TemporalQueryClassifier.classify("WHY DID WE CHANGE THIS"), .changeReason)
        XCTAssertEqual(TemporalQueryClassifier.classify("CURRENTLY what do we use"), .current)
    }
}
