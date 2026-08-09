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
    private var modeMenuItem: NSMenuItem?
    private var captureVisibilityMenuItem: NSMenuItem?
    private let audioManager = AudioCaptureManager()
    private let systemAudioManager = SystemAudioCaptureManager()
    private let aiEngine = AIEngineController()

    /// Called when the application finishes launching
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set app to accessory mode - keeps it in menu bar only
        // https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        setupHotkeys()
        initializeWindowController()

        // Which audio source actually reaches Gemini depends on the current mode:
        // Meeting mode -> system audio (other participants). Personal Assistant mode ->
        // the mic (the user talking directly to the assistant). Both capture engines run
        // continuously; only one's output is forwarded at a time.
        audioManager.onPCM16Chunk = { [weak self] chunk in
            guard self?.aiEngine.mode == .personalAssistant else { return }
            self?.aiEngine.sendLiveAudioChunk(chunk)
        }
        systemAudioManager.onPCM16Chunk = { [weak self] chunk in
            guard self?.aiEngine.mode == .meeting else { return }
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
        menu.addItem(withTitle: "Show Copilot", action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Start listening", action: #selector(startAudioCapture), keyEquivalent: "")
        menu.addItem(withTitle: "Stop listening", action: #selector(stopAudioCapture), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let modeItem = NSMenuItem(title: "Switch to Personal Assistant mode", action: #selector(toggleAssistantMode), keyEquivalent: "p")
        modeItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(modeItem)
        modeMenuItem = modeItem
        menu.addItem(NSMenuItem.separator())
        let visibilityItem = NSMenuItem(title: "Visible in Screenshots (Debug)", action: #selector(toggleCaptureVisibility), keyEquivalent: "v")
        visibilityItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(visibilityItem)
        captureVisibilityMenuItem = visibilityItem
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
        // Cmd+Shift+P: Toggle Meeting / Personal Assistant mode
        hotkey.registerHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .shift]) { [weak self] in
            self?.toggleAssistantMode()
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

    @objc private func toggleAssistantMode() {
        aiEngine.toggleMode()
        let nowInPersonalMode = aiEngine.mode == .personalAssistant
        modeMenuItem?.title = nowInPersonalMode ? "Switch to Meeting mode" : "Switch to Personal Assistant mode"
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
}
