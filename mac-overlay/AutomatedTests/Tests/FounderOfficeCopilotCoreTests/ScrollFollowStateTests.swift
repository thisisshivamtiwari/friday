import XCTest
@testable import FounderOfficeCopilotCore

/// Covers ScrollFollowState's pure decision logic - see its own doc comment for the UX rule
/// this implements. No SwiftUI/view state involved, so these are ordinary value-in/value-out
/// assertions.
final class ScrollFollowStateTests: XCTestCase {
    // MARK: isNearBottom

    func testIsNearBottomWhenAnchorIsWithinTheViewport() {
        // The bottom sentinel sits well within the visible area.
        XCTAssertTrue(ScrollFollowState.isNearBottom(bottomAnchorY: 400, viewportHeight: 600))
    }

    func testIsNearBottomWhenAnchorIsJustBelowTheThreshold() {
        let viewportHeight: CGFloat = 600
        let anchor = viewportHeight + ScrollFollowState.nearBottomThreshold - 1
        XCTAssertTrue(ScrollFollowState.isNearBottom(bottomAnchorY: anchor, viewportHeight: viewportHeight))
    }

    func testIsNotNearBottomWhenAnchorIsFarBelowTheViewport() {
        // The user has scrolled well up into older history - the true bottom is far below
        // what's currently visible.
        XCTAssertFalse(ScrollFollowState.isNearBottom(bottomAnchorY: 5000, viewportHeight: 600))
    }

    func testIsNearBottomDefaultsTrueBeforeAnyGeometryHasBeenMeasured() {
        // viewportHeight == 0 means the very first layout pass hasn't reported in yet - a
        // freshly opened chat must still auto-follow its first few deltas.
        XCTAssertTrue(ScrollFollowState.isNearBottom(bottomAnchorY: .greatestFiniteMagnitude, viewportHeight: 0))
    }

    // MARK: shouldFollow - the actual auto-scroll decision

    func testShouldFollowWhenNearBottomAndTheCurrentMessageGrew() {
        // "near bottom + new delta -> scroll"
        XCTAssertTrue(ScrollFollowState.shouldFollow(isNearBottom: true))
    }

    func testShouldFollowWhenNearBottomAndANewMessageArrived() {
        // "near bottom + new message -> scroll" - reduces to the same rule as growth, per the
        // approved spec (near-bottom is the only thing that matters, not the kind of change).
        XCTAssertTrue(ScrollFollowState.shouldFollow(isNearBottom: true))
    }

    func testShouldNotFollowWhenFarFromBottomAndTheCurrentMessageGrew() {
        // "far from bottom + new delta -> don't scroll"
        XCTAssertFalse(ScrollFollowState.shouldFollow(isNearBottom: false))
    }

    func testShouldNotFollowWhenFarFromBottomAndANewMessageArrived() {
        // "far from bottom + new message -> don't scroll"
        XCTAssertFalse(ScrollFollowState.shouldFollow(isNearBottom: false))
    }

    func testResumesFollowingOnceNearBottomAgain() {
        // "returned near bottom -> resume" - there's no separate hysteresis state, following
        // is purely a function of the CURRENT isNearBottom reading, so scrolling back down is
        // exactly "isNearBottom flips back to true" and following resumes on its own.
        XCTAssertFalse(ScrollFollowState.shouldFollow(isNearBottom: false))
        XCTAssertTrue(ScrollFollowState.shouldFollow(isNearBottom: true))
    }
}
