import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `TemporalStatus` (classification from each storage-status type, and the hard
/// `isAdmissible(status:intent:)` filter Stage 3 requires) plus `ContextPacket.empty`'s shape.
final class ContextPacketTests: XCTestCase {

    // MARK: classify(memoryEdgeStatus:)

    func testClassifyMemoryEdgeStatus() {
        XCTAssertEqual(TemporalStatus.classify(memoryEdgeStatus: .active), .current)
        XCTAssertEqual(TemporalStatus.classify(memoryEdgeStatus: .superseded), .superseded)
        XCTAssertEqual(TemporalStatus.classify(memoryEdgeStatus: .invalidated), .invalidated)
        XCTAssertEqual(TemporalStatus.classify(memoryEdgeStatus: .forgotten), .unknown)
    }

    // MARK: classify(decisionStatus:)

    func testClassifyDecisionStatus() {
        XCTAssertEqual(TemporalStatus.classify(decisionStatus: .active), .current)
        XCTAssertEqual(TemporalStatus.classify(decisionStatus: .superseded), .superseded)
    }

    // MARK: classify(projectItemStatus:)

    func testClassifyProjectItemStatusOnlyAbandonedIsInvalidated() {
        XCTAssertEqual(TemporalStatus.classify(projectItemStatus: .abandoned), .invalidated)
        for status: ProjectItem.Status in [.proposed, .planned, .active, .inProgress, .blocked, .completed, .achieved, .resolved] {
            XCTAssertEqual(TemporalStatus.classify(projectItemStatus: status), .current, "\(status) must not be classified invalidated")
        }
    }

    // MARK: isAdmissible - the hard filter

    func testCurrentAndUnknownAreAlwaysAdmissible() {
        for intent in TemporalQueryClassifier.Intent.allCases {
            XCTAssertTrue(TemporalStatus.isAdmissible(status: .current, intent: intent))
            XCTAssertTrue(TemporalStatus.isAdmissible(status: .unknown, intent: intent))
        }
    }

    func testHistoricalStatusIsAlwaysAdmissible() {
        for intent in TemporalQueryClassifier.Intent.allCases {
            XCTAssertTrue(TemporalStatus.isAdmissible(status: .historical, intent: intent))
        }
    }

    func testSupersededAdmissibleOnlyForHistoricalAdjacentIntents() {
        XCTAssertTrue(TemporalStatus.isAdmissible(status: .superseded, intent: .historical))
        XCTAssertTrue(TemporalStatus.isAdmissible(status: .superseded, intent: .changeReason))
        XCTAssertTrue(TemporalStatus.isAdmissible(status: .superseded, intent: .whenDecided))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .superseded, intent: .current))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .superseded, intent: .unspecified))
    }

    func testInvalidatedAdmissibleOnlyForChangeReasonOrWhenDecided() {
        XCTAssertTrue(TemporalStatus.isAdmissible(status: .invalidated, intent: .changeReason))
        XCTAssertTrue(TemporalStatus.isAdmissible(status: .invalidated, intent: .whenDecided))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .invalidated, intent: .current))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .invalidated, intent: .historical))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .invalidated, intent: .unspecified))
    }

    /// A CURRENT question (unspecified defaults to the same safe behavior) must never receive
    /// superseded or invalidated evidence as current truth - the single most important
    /// guarantee Stage 3 exists to provide.
    func testCurrentIntentNeverAdmitsSupersededOrInvalidated() {
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .superseded, intent: .current))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .invalidated, intent: .current))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .superseded, intent: .unspecified))
        XCTAssertFalse(TemporalStatus.isAdmissible(status: .invalidated, intent: .unspecified))
    }

    // MARK: ContextPacket.empty

    func testEmptyContextPacketHasNoEvidenceAnywhere() {
        let packet = ContextPacket.empty
        XCTAssertTrue(packet.currentConversation.isEmpty)
        XCTAssertNil(packet.activeProjectID)
        XCTAssertTrue(packet.relevantMemories.isEmpty)
        XCTAssertTrue(packet.relevantProjectItems.isEmpty)
        XCTAssertTrue(packet.relevantDecisions.isEmpty)
        XCTAssertTrue(packet.relevantEpisodes.isEmpty)
        XCTAssertTrue(packet.historicalEvidence.isEmpty)
        XCTAssertTrue(packet.proceduralInstructions.isEmpty)
        XCTAssertTrue(packet.provenanceIndex.isEmpty)
    }
}
