import XCTest
@testable import FounderOfficeCopilotCore

/// Covers MemoryEdge's plain value-type behavior - initialization, category/status enum
/// coverage, confidence boundary values, and the computed `isStale(now:)` staleness logic.
/// No Core Data, no MemoryManager here - see MemoryStoreTests/MemoryManagerTests for
/// persistence-layer coverage.
final class MemoryEdgeTests: XCTestCase {
    private func makeEdge(
        confidence: Float = 0.5,
        status: MemoryEdge.Status = .active,
        lastConfirmedAt: Date = Date(),
        sourceMessageIDs: [UUID] = []
    ) -> MemoryEdge {
        MemoryEdge(
            subjectEntityID: UUID(),
            predicate: "prefers",
            category: .preference,
            confidence: confidence,
            status: status,
            sourceSessionID: UUID(),
            sourceMessageIDs: sourceMessageIDs,
            lastConfirmedAt: lastConfirmedAt
        )
    }

    // MARK: Initialization

    func testInitializerAppliesDefaults() {
        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "prefers", category: .preference, confidence: 0.6, sourceSessionID: UUID())

        XCTAssertNil(edge.objectEntityID)
        XCTAssertNil(edge.literalValue)
        XCTAssertEqual(edge.status, .active)
        XCTAssertEqual(edge.sourceMessageIDs, [])
        XCTAssertEqual(edge.confirmationCount, 1)
        XCTAssertNil(edge.supersedes)
        XCTAssertNil(edge.supersededBy)
        XCTAssertFalse(edge.isExplicit)
        XCTAssertFalse(edge.isPinned)
    }

    func testInitializerAcceptsAllExplicitValues() {
        let id = UUID()
        let subject = UUID()
        let object = UUID()
        let session = UUID()
        let message = UUID()
        let supersededID = UUID()
        let firstObserved = Date(timeIntervalSinceReferenceDate: 100)
        let lastConfirmed = Date(timeIntervalSinceReferenceDate: 200)

        let edge = MemoryEdge(
            id: id,
            subjectEntityID: subject,
            predicate: "works-at",
            objectEntityID: object,
            literalValue: nil,
            category: .relationship,
            confidence: 0.9,
            status: .active,
            sourceSessionID: session,
            sourceMessageIDs: [message],
            firstObservedAt: firstObserved,
            lastConfirmedAt: lastConfirmed,
            confirmationCount: 3,
            supersedes: supersededID,
            supersededBy: nil,
            isExplicit: true,
            isPinned: true
        )

        XCTAssertEqual(edge.id, id)
        XCTAssertEqual(edge.subjectEntityID, subject)
        XCTAssertEqual(edge.predicate, "works-at")
        XCTAssertEqual(edge.objectEntityID, object)
        XCTAssertEqual(edge.category, .relationship)
        XCTAssertEqual(edge.confidence, 0.9)
        XCTAssertEqual(edge.sourceSessionID, session)
        XCTAssertEqual(edge.sourceMessageIDs, [message])
        XCTAssertEqual(edge.firstObservedAt, firstObserved)
        XCTAssertEqual(edge.lastConfirmedAt, lastConfirmed)
        XCTAssertEqual(edge.confirmationCount, 3)
        XCTAssertEqual(edge.supersedes, supersededID)
        XCTAssertTrue(edge.isExplicit)
        XCTAssertTrue(edge.isPinned)
    }

    func testEqualityMatchesOnAllFields() {
        let id = UUID()
        let subject = UUID()
        let session = UUID()
        let date = Date()
        let a = MemoryEdge(id: id, subjectEntityID: subject, predicate: "prefers", category: .preference, confidence: 0.5, sourceSessionID: session, firstObservedAt: date, lastConfirmedAt: date)
        let b = MemoryEdge(id: id, subjectEntityID: subject, predicate: "prefers", category: .preference, confidence: 0.5, sourceSessionID: session, firstObservedAt: date, lastConfirmedAt: date)
        XCTAssertEqual(a, b)
    }

    // MARK: Category values

    func testAllCategoryValuesAreDistinct() {
        let all = MemoryEdge.Category.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        XCTAssertTrue(all.contains(.identity))
        XCTAssertTrue(all.contains(.preference))
        XCTAssertTrue(all.contains(.goal))
        XCTAssertTrue(all.contains(.fact))
        XCTAssertTrue(all.contains(.relationship))
        XCTAssertTrue(all.contains(.project))
        XCTAssertTrue(all.contains(.contact))
        XCTAssertTrue(all.contains(.other))
    }

    // MARK: Status values

    func testStatusHasExactlyFourStoredCasesNoStaleCase() {
        // "Stale" is deliberately NOT a stored status - see isStale(now:) below. This test
        // pins the exact stored vocabulary so a future change can't silently reintroduce a
        // fifth stored case without this test forcing a conscious update.
        let all = MemoryEdge.Status.allCases
        XCTAssertEqual(Set(all), [.active, .superseded, .invalidated, .forgotten])
        XCTAssertEqual(all.count, 4)
    }

    // MARK: Confidence boundaries

    func testConfidenceAtLowerBoundZero() {
        let edge = makeEdge(confidence: 0.0)
        XCTAssertEqual(edge.confidence, 0.0)
    }

    func testConfidenceAtUpperBoundOne() {
        let edge = makeEdge(confidence: 1.0)
        XCTAssertEqual(edge.confidence, 1.0)
    }

    func testConfidenceIsNotClampedByThisType() {
        // MemoryEdge is a plain value type - clamping/validating confidence is a business
        // rule for whatever creates/corroborates an edge (a later phase), not for this type
        // to silently enforce. Documents that behavior explicitly rather than leaving it
        // implicit.
        let edge = makeEdge(confidence: 1.5)
        XCTAssertEqual(edge.confidence, 1.5, "this type must not silently clamp - out-of-range values pass through unchanged")
    }

    // MARK: Staleness

    func testActiveEdgeConfirmedJustNowIsNotStale() {
        let edge = makeEdge(status: .active, lastConfirmedAt: Date())
        XCTAssertFalse(edge.isStale())
    }

    func testActiveEdgeConfirmedLongAgoIsStale() {
        let longAgo = Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600)
        let edge = makeEdge(status: .active, lastConfirmedAt: longAgo)
        XCTAssertTrue(edge.isStale())
    }

    func testActiveEdgeExactlyAtThresholdIsNotYetStale() {
        // Strictly greater-than the threshold, not greater-than-or-equal - confirms the
        // boundary is exclusive.
        let now = Date()
        let atThreshold = now.addingTimeInterval(-MemoryEdge.staleThreshold)
        let edge = makeEdge(status: .active, lastConfirmedAt: atThreshold)
        XCTAssertFalse(edge.isStale(now: now))
    }

    func testSupersededEdgeIsNeverStaleRegardlessOfAge() {
        let longAgo = Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600)
        let edge = makeEdge(status: .superseded, lastConfirmedAt: longAgo)
        XCTAssertFalse(edge.isStale(), "staleness only applies to .active edges")
    }

    func testInvalidatedEdgeIsNeverStale() {
        let longAgo = Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600)
        let edge = makeEdge(status: .invalidated, lastConfirmedAt: longAgo)
        XCTAssertFalse(edge.isStale())
    }

    func testForgottenEdgeIsNeverStale() {
        let longAgo = Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600)
        let edge = makeEdge(status: .forgotten, lastConfirmedAt: longAgo)
        XCTAssertFalse(edge.isStale())
    }

    func testReconfirmingAStaleEdgeMakesItFreshAgain() {
        // Staleness is purely computed from lastConfirmedAt, so simply updating that field
        // (what a later phase's corroboration logic does) is enough to make a stale edge
        // fresh again - no separate "un-stale" transition is needed.
        var edge = makeEdge(status: .active, lastConfirmedAt: Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600))
        XCTAssertTrue(edge.isStale())
        edge.lastConfirmedAt = Date()
        XCTAssertFalse(edge.isStale())
    }

    // MARK: Source UUID preservation

    func testSourceMessageIDsPreservesOrderAndDuplicatesAcrossMutation() {
        let first = UUID()
        let second = UUID()
        var edge = makeEdge(sourceMessageIDs: [first])
        XCTAssertEqual(edge.sourceMessageIDs, [first])

        edge.sourceMessageIDs.append(second)
        XCTAssertEqual(edge.sourceMessageIDs, [first, second], "corroboration appends, never reorders or dedupes silently")
    }

    func testSourceSessionIDIsImmutableAfterInit() {
        // sourceSessionID is a `let` - this test documents/pins that as intentional: an
        // edge's ORIGINATING session never changes after creation, even though which
        // messages corroborate it (sourceMessageIDs) can grow.
        let session = UUID()
        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "prefers", category: .preference, confidence: 0.5, sourceSessionID: session)
        XCTAssertEqual(edge.sourceSessionID, session)
    }
}
