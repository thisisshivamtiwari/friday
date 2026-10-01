import SwiftUI
import AppKit

// MARK: - Graph Window Controller
/// Hosts the project graph in an ordinary, fully-visible window - the same pattern
/// `SettingsWindowController` already uses, and deliberately
/// NOT part of the invisible overlay: the graph is something the user reads and explores at
/// their own pace, not glanceable heads-up content, and it needs standard window chrome,
/// resizing and full-size mode to be usable at all.
///
/// The managers are INJECTED from `AppDelegate`'s existing `AIEngineController`, never
/// re-created here. Constructing a second `ProjectManager` would open a second handle on the
/// same store and show a snapshot that silently diverges from what the running assistant is
/// actually using - and `ChatSessionStore`'s write serialization is per INSTANCE, so a second
/// instance is precisely the invariant its concurrency fix relies on not being broken.
final class GraphWindowController: NSWindowController {
    init(projectManager: ProjectManager, memoryManager: MemoryManager, chatSessionManager: ChatSessionManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Project Graph"
        window.setFrameAutosaveName("FounderOfficeCopilot.ProjectGraph")
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)

        let model = GraphViewModel(
            projectManager: projectManager,
            memoryManager: memoryManager,
            chatSessionManager: chatSessionManager
        )
        window.contentView = NSHostingView(rootView: GraphView(model: model))
        self.viewModel = model

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let viewModel: GraphViewModel

    /// Rebuilds on every show. Extraction runs continuously in the background, so a window left
    /// open since before a meeting would otherwise keep displaying pre-meeting state - and the
    /// rebuild is a projection of already-loaded in-memory arrays, not a store read, so it is
    /// cheap enough to do unconditionally (measured: ~18 ms at 1041 nodes / 3020 edges).
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            viewModel.reload()
        }
    }

}
