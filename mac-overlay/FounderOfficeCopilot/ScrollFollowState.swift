import Foundation
import CoreGraphics

// MARK: - Scroll Follow State
/// Pure decision logic for the chat feed's auto-scroll behavior - deliberately has no SwiftUI
/// import and touches no view state, so it's directly unit-testable (same reasoning as
/// SessionSearch.swift: this project never symlinks view files into AutomatedTests, so logic
/// that needs test coverage gets pulled out into a plain file like this one).
///
/// The desired UX, in full: while the user is near the bottom of the feed, new content (a new
/// message, or the current message growing) should keep them pinned to the bottom. The moment
/// they scroll up to read older content, that following must stop completely - no yanking them
/// back down mid-read - and only resume once they've scrolled back near the bottom themselves.
/// Switching sessions or opening an old chat is a separate, unconditional "jump to latest"
/// action, not something this decision logic governs.
enum ScrollFollowState {
    /// How close to the true bottom (in points) still counts as "at the bottom" for auto-follow
    /// purposes - small enough that it doesn't kick in while genuinely reading upward, generous
    /// enough to absorb minor layout jitter (e.g. a bubble growing by a line or two) without
    /// flickering in and out of "near bottom".
    static let nearBottomThreshold: CGFloat = 120

    /// `bottomAnchorY`/`viewportHeight` are both measured in the same coordinate space (the
    /// scroll view's own): `bottomAnchorY` is where the very end of the content currently sits,
    /// `viewportHeight` is how tall the visible scroll area is. When the anchor sits within
    /// `nearBottomThreshold` points of the bottom of the visible area (or above it, i.e.
    /// already visible), the user is considered "at the bottom". Before any geometry has been
    /// measured yet (`viewportHeight == 0`, i.e. the very first layout pass), this defaults to
    /// true - the alternative (defaulting to false) would mean a freshly opened chat fails to
    /// auto-follow its first few deltas simply because geometry hadn't reported in yet.
    static func isNearBottom(bottomAnchorY: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0 else { return true }
        return (bottomAnchorY - viewportHeight) <= nearBottomThreshold
    }

    /// Whether new content (a newly appended message, or the current message growing via a
    /// streaming delta) should trigger an auto-scroll-to-bottom. Both cases reduce to the same
    /// rule per the approved UX spec - "near bottom" is the only thing that matters, not
    /// whether the change was a new message or existing growth - kept as one function rather
    /// than two identical ones to avoid a fake distinction.
    static func shouldFollow(isNearBottom: Bool) -> Bool {
        isNearBottom
    }
}
