import SwiftUI
import AppKit

// MARK: - Interactive Control Feedback
/// The ONE place cursor/hover/pressed/focus feedback is implemented for icon-only controls -
/// applied consistently instead of hand-rolled per button. Two pieces, since SwiftUI only
/// exposes press state through `ButtonStyle` and hover/cursor through a plain modifier:
///
/// - `.pointingHandCursor()` - just the cursor (NSCursor push/pop on hover). The minimal,
///   universally-applicable piece; used alone by controls that already have their own bespoke
///   hover-background logic (e.g. SessionRow), so this never fights with that.
/// - `.interactiveControl()` - cursor + a generic hover background + a focus ring, for plain
///   icon buttons that have no bespoke styling of their own.
///
/// `.pointerStyle(_:)` (SwiftUI's native equivalent) requires macOS 14+; this app's
/// deployment target is 13.0, so NSCursor push/pop is the compatible mechanism.
private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pointingHand.pop()
            }
        }
    }
}

private struct InteractiveControlModifier: ViewModifier {
    var cornerRadius: CGFloat
    var hoverOpacity: Double
    @State private var isHovering = false
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(isHovering ? Color.white.opacity(hoverOpacity) : Color.clear)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(isFocused ? 0.4 : 0), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pointingHand.pop()
                }
            }
    }
}

/// Pairs with `.interactiveControl()` for plain icon buttons - a brief opacity dip on press,
/// the one piece of feedback `ButtonStyle` (not a plain view modifier) can provide.
struct PlainInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

extension View {
    /// Cursor feedback only - for controls that already implement their own hover-driven
    /// visual state (e.g. SessionRow's selected/hover background) and shouldn't have a
    /// second, generic hover background layered on top of it.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }

    /// Cursor + hover background + focus ring, for plain icon-only controls with no bespoke
    /// styling of their own. Pair with `.buttonStyle(PlainInteractiveButtonStyle())` on the
    /// `Button` itself for press feedback, and `.help(...)` for a tooltip.
    func interactiveControl(cornerRadius: CGFloat = 6, hoverOpacity: Double = 0.1) -> some View {
        modifier(InteractiveControlModifier(cornerRadius: cornerRadius, hoverOpacity: hoverOpacity))
    }
}
