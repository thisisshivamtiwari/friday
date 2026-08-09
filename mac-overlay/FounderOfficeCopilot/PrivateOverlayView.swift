import SwiftUI

// MARK: - UI View
/// Main SwiftUI interface: a Jarvis-style HUD - a glowing avatar as the primary "is it
/// listening / responding" indicator, with a scrollable feed of everything heard and every
/// response given. Always listening, never replies automatically - see the shortcuts cheat
/// sheet (top-right) for how to trigger a response. Fully responsive: no fixed frame, so the
/// window can be resized from small to large to maximized and this layout adapts.
struct PrivateOverlayView: View {
    @ObservedObject var aiEngine: AIEngineController
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var captureVisibility = CaptureVisibilityState.shared
    @State private var showShortcuts = false

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.height < 420

            VStack(alignment: .leading, spacing: 0) {
                if captureVisibility.isVisibleToCapture {
                    debugVisibleBanner
                }
                header(compact: isCompact, availableWidth: geo.size.width)
                    .overlay(alignment: .topTrailing) { shortcutsButton }
                if !aiEngine.teamsParticipants.isEmpty {
                    participantsRow
                }
                Divider().background(Color.white.opacity(0.1))
                chatFeed
                footer
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: PrivateOverlayWindowController.minSize.width, minHeight: PrivateOverlayWindowController.minSize.height)
        .background(
            ZStack {
                Color(red: 0.05, green: 0.08, blue: 0.15).opacity(0.15)
                Color.white.opacity(0.02)
            }
        )
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.red.opacity(captureVisibility.isVisibleToCapture ? 0.8 : 0), lineWidth: 3)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    /// Impossible to miss on purpose - this mode defeats the app's entire privacy
    /// guarantee, so it should never be ambiguous whether it's currently on
    private var debugVisibleBanner: some View {
        Text("⚠️ VISIBLE TO SCREENSHOTS/SCREEN SHARE - Cmd+Shift+V to turn off")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.85))
    }

    /// True while the response for the current turn is still streaming in - the avatar
    /// visibly speeds up/brightens the instant Gemini starts responding
    private var isStreaming: Bool {
        aiEngine.messages.last?.isStreaming ?? false
    }

    // MARK: Shortcuts cheat sheet

    private var shortcutsButton: some View {
        Button {
            showShortcuts.toggle()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
        .buttonStyle(.plain)
        .padding(10)
        .popover(isPresented: $showShortcuts, arrowEdge: .top) {
            shortcutsList
        }
    }

    private var shortcutsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts")
                .font(.system(size: 12, weight: .bold))
            shortcutRow("⌘⇧A", "Show / hide overlay")
            shortcutRow("⌘⇧R", "Respond now")
            shortcutRow("⌘⇧V", "Toggle visible in screenshots")
            shortcutRow("2× click", "Maximize / restore window")
        }
        .padding(14)
        .frame(width: 230)
    }

    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 78, alignment: .leading)
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Header

    /// The big centered hero avatar before anything's been heard. Once the chat actually
    /// has content, `activeHeader` takes over instead.
    @ViewBuilder
    private func header(compact: Bool, availableWidth: CGFloat) -> some View {
        if aiEngine.messages.isEmpty {
            idleHeader(compact: compact, availableWidth: availableWidth)
        } else {
            activeHeader
        }
    }

    private func idleHeader(compact: Bool, availableWidth: CGFloat) -> some View {
        let blobSize = compact ? 56.0 : min(120.0, availableWidth * 0.32)
        return VStack(spacing: 6) {
            AvatarBlobView(isActive: aiEngine.isActive, isStreaming: isStreaming)
                .frame(width: blobSize, height: blobSize)
            Text(settings.agentName)
                .font(.system(size: compact ? 13 : 16, weight: .bold))
                .foregroundColor(.white)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, compact ? 10 : 20)
        .padding(.bottom, 10)
    }

    /// Small inline avatar once something's actually been heard - frees up vertical space
    /// for the chat feed instead of keeping the big idle hero avatar around
    private var activeHeader: some View {
        HStack(spacing: 10) {
            AvatarBlobView(isActive: aiEngine.isActive, isStreaming: isStreaming)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.agentName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        guard aiEngine.isActive else { return "Stopped" }
        return aiEngine.isLiveSessionActive ? "Live · Gemini" : "Local mode"
    }

    private var participantsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants (\(aiEngine.teamsParticipants.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.purple)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(aiEngine.teamsParticipants, id: \.self) { participant in
                        Text(participant)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var chatFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if aiEngine.messages.isEmpty {
                        Text("Listening… press ⌘⇧R whenever you want a response")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(aiEngine.messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: aiEngine.messages.last?.text) { _ in
                guard let lastID = aiEngine.messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        Text("Invisible to screen share • Cmd+Shift+A to toggle • double-click to maximize")
            .font(.system(size: 9, weight: .regular))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(8)
    }
}

/// A single chat bubble - "Heard" (anything transcribed - your voice or anyone else's)
/// leans left in a muted tone; "Response" leans right in an accent tone, so the two are
/// easy to tell apart while scrolling back.
struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .response { Spacer(minLength: 32) }

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(labelColor)
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.system(size: 12.5, weight: message.role == .heard ? .regular : .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(bubbleColor)
            .cornerRadius(10)
            .opacity(message.isStreaming ? 0.75 : 1.0)

            if message.role == .heard { Spacer(minLength: 32) }
        }
    }

    private var label: String {
        message.role == .heard ? "Heard" : "Response"
    }

    private var labelColor: Color {
        message.role == .heard ? .gray : .yellow
    }

    private var bubbleColor: Color {
        message.role == .heard ? Color.white.opacity(0.06) : Color.yellow.opacity(0.14)
    }
}
