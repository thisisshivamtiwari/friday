import SwiftUI
import AppKit

// MARK: - Settings Window Controller
/// A regular (non-panel, non-invisible) window for app configuration - unlike the overlay,
/// this one is meant to be fully visible and behave like a normal preferences window.
final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Founder Office Copilot Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings View
/// Configuration screen: agent persona, custom rules ("memory"/system instruction), and the
/// Gemini API key. Scrollable so it can grow (e.g. future meeting-history settings) without
/// needing a fixed window size that clips content.
struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var apiKeyInput: String = ""
    @State private var didSaveKey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent name")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("Founder Office Copilot", text: $settings.agentName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("About you")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Who you are, your role, and what you care about - included in every session so suggestions are personalized instead of generic.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextEditor(text: $settings.aboutMe)
                        .font(.system(size: 12))
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Rules")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Custom instructions the assistant follows for every meeting - tone, what to focus on, what to avoid.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextEditor(text: $settings.rules)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Gemini API key")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Stored in the macOS Keychain, never written to disk in plain text.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Text("Get a free key at")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Link("aistudio.google.com/app/apikey", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                            .font(.system(size: 11))
                    }
                    HStack {
                        SecureField("AIza...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            settings.geminiAPIKey = apiKeyInput
                            didSaveKey = true
                        }
                        .disabled(apiKeyInput.isEmpty)
                    }
                    if didSaveKey {
                        Text("Saved")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    } else if settings.geminiAPIKey != nil {
                        Text("A key is already saved. Enter a new one to replace it.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your spoken language")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Language for transcribing your own mic into \"You\" bubbles. This must match what you actually speak - unlike the \"Heard\" transcript (which auto-detects language), this one is locked to a single language per session and produces no transcript at all if it doesn't match.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Picker("", selection: $settings.transcriptionLocale) {
                        ForEach(SettingsStore.transcriptionLocaleOptions, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Gemini model")
                        .font(.system(size: 12, weight: .semibold))
                    TextField(SettingsStore.defaultGeminiModel, text: $settings.geminiModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            apiKeyInput = ""
            didSaveKey = false
        }
    }
}
