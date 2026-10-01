import SwiftUI
import AppKit

// MARK: - Capture Visibility State
/// Whether the overlay is currently visible to screen capture ("debug mode," for taking a
/// screenshot/recording to show someone a UI problem) or using its normal
/// sharingType=.none invisibility. Published so PrivateOverlayView can show a hard-to-miss
/// indicator whenever debug mode is on - the whole point of this app is being invisible
/// during a real meeting, so silently leaving debug mode on would be a real footgun.
final class CaptureVisibilityState: ObservableObject {
    static let shared = CaptureVisibilityState()
    @Published var isVisibleToCapture = false
    private init() {}
}

// MARK: - Overlay Visibility State
/// Whether the overlay window is actually on screen right now (not occluded by another
/// window, not minimized, not hidden via orderOut) - driven by NSWindow's own occlusionState
/// rather than just the explicit show()/hide() calls, so it also catches "covered by another
/// app's window" the same way "explicitly hidden" is caught. AvatarBlobView uses this to stop
/// its continuous per-frame Canvas animation while nobody could possibly be seeing it -
/// TimelineView(.animation) does NOT pause itself just because its window is off-screen, so
/// without this the animation burned CPU on every frame forever, even while hidden.
final class OverlayVisibilityState: ObservableObject {
    static let shared = OverlayVisibilityState()
    @Published var isVisible = false
    private init() {}
}

// MARK: - Private Overlay Window Controller
/// Controls the floating overlay window that stays invisible during screen sharing.
/// Resizable (small -> large -> maximize) so the Jarvis-style layout can adapt, rather than
/// being locked to one fixed size.
final class PrivateOverlayWindowController: NSWindowController {
    private let aiEngine: AIEngineController
    private var isVisible = false
    /// Frame to restore to when un-maximizing; nil means "not currently maximized"
    private var preMaximizeFrame: NSRect?

    static let defaultSize = NSSize(width: 420, height: 580)
    static let minSize = NSSize(width: 280, height: 360)

    init(aiEngine: AIEngineController) {
        self.aiEngine = aiEngine

        // Create a floating panel window
        // https://developer.apple.com/documentation/appkit/nspanel
        let window = PrivateOverlayWindow(
            contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: Self.defaultSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        // Configure window appearance
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        // .fullScreenAuxiliary (not .fullScreenPrimary) deliberately: real macOS Spaces
        // fullscreen would fight with sharingType=.none/nonactivatingPanel in ways that
        // risk breaking the invisibility property, so "fullscreen" here is implemented as
        // an in-place maximize (see toggleMaximize) rather than the native Spaces transition
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = true
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.minSize = Self.minSize

        // Add SwiftUI content view
        let contentView = PrivateOverlayView(aiEngine: aiEngine)
        let hostingView = DraggableHostingView(rootView: contentView)
        window.contentView = hostingView

        super.init(window: window)

        // Double-click the draggable background to maximize/restore - the standard macOS
        // title-bar-zoom convention, applied here since this window hides its title bar
        hostingView.onDoubleClick = { [weak self] in self?.toggleMaximize() }

        // Keeps OverlayVisibilityState accurate for every reason the window can stop being
        // actually visible - explicit hide(), being covered by another window, minimizing -
        // not just the two paths this controller itself drives (show()/hide()).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            OverlayVisibilityState.shared.isVisible = window.occlusionState.contains(.visible)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    /// Toggles between the window's current size and filling the active screen's visible
    /// frame - a "maximize," not native macOS fullscreen (see the collectionBehavior note
    /// above for why)
    func toggleMaximize() {
        guard let window else { return }

        if let restoreFrame = preMaximizeFrame {
            window.setFrame(restoreFrame, display: true, animate: true)
            preMaximizeFrame = nil
        } else {
            preMaximizeFrame = window.frame
            let targetScreen = window.screen ?? NSScreen.main
            if let visibleFrame = targetScreen?.visibleFrame {
                window.setFrame(visibleFrame, display: true, animate: true)
            }
        }
    }

    var isMaximized: Bool { preMaximizeFrame != nil }

    /// Toggles between the normal invisible-to-capture state and a debug-visible state
    /// where the overlay shows up in screenshots/screen recordings, so it can actually be
    /// shown to someone rather than being invisible in every screenshot too
    func toggleCaptureVisibility() {
        guard let panel = window as? PrivateOverlayWindow else { return }
        panel.setVisibleToCapture(!CaptureVisibilityState.shared.isVisibleToCapture)
    }
}

// MARK: - Draggable Hosting View
/// NSHostingView always reports `mouseDownCanMoveWindow == false`, which silently defeats
/// `NSWindow.isMovableByWindowBackground` for any window whose contentView is SwiftUI-hosted -
/// the window never receives the mouseDown needed to start the built-in background drag.
/// Overriding it to `true` restores background dragging while leaving SwiftUI's own gesture
/// handling (buttons, scroll views, etc.) untouched, since AppKit only starts the window drag
/// when no SwiftUI gesture claims the mouseDown first.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    /// Fired on a double-click that lands on the draggable background (not on a SwiftUI
    /// control, since those claim the event first) - wired to maximize/restore
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Private Overlay Window
/// NSPanel subclass that uses sharingType=.none to hide from screen sharing
/// Reference: Cluely's implementation uses the same approach
/// https://developer.apple.com/documentation/appkit/nspanel
final class PrivateOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        configureForPrivacyMode()
    }

    /// Configures window to be invisible during screen capture
    /// sharingType = .none excludes this window from:
    /// - Screen sharing in Zoom, Teams, Google Meet, Webex
    /// - OS-level screen recording
    /// - Screenshot APIs
    private func configureForPrivacyMode() {
        // https://developer.apple.com/documentation/appkit/nspanel/sharingtype
        self.sharingType = .none
    }

    /// Switches between the normal invisible mode and a debug-visible mode where the
    /// window shows up in screenshots/recordings too - see CaptureVisibilityState
    func setVisibleToCapture(_ visible: Bool) {
        sharingType = visible ? .readOnly : .none
        CaptureVisibilityState.shared.isVisibleToCapture = visible
    }
}
