import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Main application entry point
/// https://developer.apple.com/documentation/swiftui/app
@main
struct FounderOfficeCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate
/// Manages application lifecycle, menu bar icon, and keyboard shortcuts
/// https://developer.apple.com/documentation/appkit/nsapplicationdelegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var windowController: PrivateOverlayWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var graphWindowController: GraphWindowController?
    private var mainWindowController: MainWindowController?
    private var captureVisibilityMenuItem: NSMenuItem?
    private let audioManager = AudioCaptureManager()
    private let systemAudioManager = SystemAudioCaptureManager()
    private let audioMixer = AudioMixer()
    /// LAZY on purpose. `AIEngineController` builds `ChatSessionManager`/`MemoryManager`/
    /// `ProjectManager`, and constructing those OPENS all three Core Data stores. As a stored
    /// `let` that happened before `applicationDidFinishLaunching` even ran, so merely launching
    /// the process paid for three database opens before a single line of setup code executed.
    /// Lazy defers that to the first genuine use, which keeps startup cheap and means a launch
    /// path that never touches the assistant never opens a store at all.
    private lazy var aiEngine = AIEngineController()

    /// Called when the application finishes launching
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set app to accessory mode - keeps it in menu bar only
        // https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        // DEVELOPER TOOLING - one-shot validation of the real core loop. Returns before any
        // audio/live-session startup, like the preview flag below.
        if LiveLoopValidation.runIfRequested() { return }

        // DEVELOPER TOOLING (not product UI, and not reachable from any menu): opens the
        // workspace window against a chosen store directory and returns BEFORE audio capture,
        // system-audio capture and the Gemini Live session start. This exists so the UI can be
        // launched and screenshotted during development without the side effect of recording the
        // room or opening a paid session. `--workspace-stores=<dir>` points it at a directory of
        // Core Data stores; omitted, it uses the real ones.
        if ProcessInfo.processInfo.arguments.contains("--workspace-preview") {
            NSApp.setActivationPolicy(.regular)
            if let appearance = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--workspace-appearance=") })?.split(separator: "=").last {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            }
            let storeDirectory = ProcessInfo.processInfo.arguments
                .first { $0.hasPrefix("--workspace-stores=") }?.split(separator: "=", maxSplits: 1).last.map(String.init)
            showMainWindow(storeDirectory: storeDirectory)
            return
        }
        #endif

        setupMenuBar()
        setupHotkeys()
        initializeWindowController()

        // Single always-on assistant: both the mic (the user) and system audio (everyone
        // else) always feed the same live session - there's no mode to gate this on.
        // Nothing gets a reply automatically either way; that only happens when
        // aiEngine.requestResponse() is triggered (see the Respond Now hotkey below).
        //
        // Both sources go through AudioMixer first rather than straight to the live
        // session - see its doc comment for why sending two independently-timed streams
        // directly was causing garbled, hallucinated transcription.
        audioManager.onPCM16Chunk = { [weak self] chunk in
            self?.audioMixer.addMicChunk(chunk)
        }
        systemAudioManager.onPCM16Chunk = { [weak self] chunk in
            self?.audioMixer.addSystemChunk(chunk)
        }
        audioMixer.onMixedPCM16Chunk = { [weak self] chunk in
            self?.aiEngine.sendLiveAudioChunk(chunk)
        }

        audioManager.startListening()
        systemAudioManager.start()
        aiEngine.start()
    }

    /// Creates the menu bar icon and dropdown menu
    private func setupMenuBar() {
        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🎯"
            button.action = #selector(toggleOverlay)
            button.target = self
        }

        // Create dropdown menu
        let menu = NSMenu()
        let workspaceItem = NSMenuItem(title: "Open Workspace", action: #selector(openWorkspace), keyEquivalent: "0")
        workspaceItem.keyEquivalentModifierMask = [.command]
        menu.addItem(workspaceItem)
        menu.addItem(withTitle: "Show Copilot Overlay", action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Start listening", action: #selector(startAudioCapture), keyEquivalent: "")
        menu.addItem(withTitle: "Stop listening", action: #selector(stopAudioCapture), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let respondItem = NSMenuItem(title: "Respond Now", action: #selector(requestResponse), keyEquivalent: "r")
        respondItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(respondItem)
        menu.addItem(NSMenuItem.separator())
        let visibilityItem = NSMenuItem(title: "Visible in Screenshots (Debug)", action: #selector(toggleCaptureVisibility), keyEquivalent: "v")
        visibilityItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(visibilityItem)
        captureVisibilityMenuItem = visibilityItem
        menu.addItem(NSMenuItem.separator())
        let graphItem = NSMenuItem(title: "Project Graph…", action: #selector(showProjectGraph), keyEquivalent: "g")
        graphItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(graphItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        // Every action above is implemented on AppDelegate (self), so route those through
        // it - EXCEPT Quit, whose action (NSApplication.terminate(_:)) only exists on
        // NSApplication. Forcing target=self on it too (as this used to do in a blanket
        // loop over all items) made AppKit correctly see self can't perform that action
        // and permanently grey the item out - "Quit" became unclickable.
        for item in menu.items where item !== quitItem {
            item.target = self
        }
        quitItem.target = NSApp

        statusItem?.menu = menu
    }

    /// Registers global keyboard shortcuts - works even when the app isn't frontmost
    private func setupHotkeys() {
        let hotkey = HotKeyManager.shared
        // Cmd+Shift+A: Show/Hide overlay
        hotkey.registerHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command, .shift]) { [weak self] in
            self?.toggleOverlay()
        }
        // Cmd+Shift+R: Respond Now - the entire "ask the assistant" trigger. Everything
        // heard since the last response becomes the context for this one.
        hotkey.registerHotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .shift]) { [weak self] in
            self?.requestResponse()
        }
        // Cmd+Shift+V: Toggle debug visibility (shows the overlay in screenshots/screen
        // share, so a UI problem can actually be captured to show someone)
        hotkey.registerHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .shift]) { [weak self] in
            self?.toggleCaptureVisibility()
        }
    }

    /// Initializes the floating window controller
    private func initializeWindowController() {
        windowController = PrivateOverlayWindowController(aiEngine: aiEngine)
    }

    @objc private func toggleOverlay() {
        windowController?.toggle()
    }

    @objc private func showOverlay() {
        windowController?.show()
    }

    @objc private func startAudioCapture() {
        audioManager.startListening()
        systemAudioManager.start()
        aiEngine.start()
    }

    @objc private func stopAudioCapture() {
        audioManager.stopListening()
        systemAudioManager.stop()
        aiEngine.stop()
    }

    @objc private func requestResponse() {
        aiEngine.requestResponse()
    }

    @objc private func toggleCaptureVisibility() {
        windowController?.toggleCaptureVisibility()
        captureVisibilityMenuItem?.state = CaptureVisibilityState.shared.isVisibleToCapture ? .on : .off
    }


    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    /// The managers come from the ONE live `AIEngineController`, never from fresh instances -
    /// see `GraphWindowController`'s doc comment for why a second `ProjectManager`/
    /// `ChatSessionStore` would be actively harmful rather than merely wasteful.
    /// The main workspace window. Shares the ONE `AIEngineController` object graph, so anything
    /// captured during a meeting is visible here the moment extraction lands - see
    /// `MainWindowController`'s doc comment for why a second manager set would be wrong.
    @objc private func openWorkspace() { showMainWindow(storeDirectory: nil) }

    private func showMainWindow(storeDirectory: String?) {
        if mainWindowController == nil {
            if let storeDirectory {
                let base = URL(fileURLWithPath: storeDirectory, isDirectory: true)
                mainWindowController = MainWindowController(engine: AIEngineController(
                    chatSessionManager: ChatSessionManager(store: ChatSessionStore(storeURL: base.appendingPathComponent("ChatSessions.sqlite"))),
                    memoryManager: MemoryManager(store: MemoryStore(storeURL: base.appendingPathComponent("Memory.sqlite"))),
                    projectManager: ProjectManager(store: ProjectStore(storeURL: base.appendingPathComponent("Projects.sqlite")))
                ))
            } else {
                mainWindowController = MainWindowController(engine: aiEngine)
            }
        }
        mainWindowController?.show()
    }

    @objc private func showProjectGraph() {
        if graphWindowController == nil {
            graphWindowController = GraphWindowController(
                projectManager: aiEngine.projectManager,
                memoryManager: aiEngine.memoryManager,
                chatSessionManager: aiEngine.chatSessionManager
            )
        }
        graphWindowController?.show()
    }
}
