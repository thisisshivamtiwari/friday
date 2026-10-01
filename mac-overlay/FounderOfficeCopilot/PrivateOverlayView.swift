import SwiftUI

// MARK: - UI View
/// Main SwiftUI interface: a Jarvis-style HUD - a glowing avatar as the primary "is it
/// listening / responding" indicator, with a scrollable feed of everything heard and every
/// response given. Always listening, never replies automatically - see the shortcuts cheat
/// sheet (top-right) for how to trigger a response. Fully responsive: no fixed frame, so the
/// window can be resized from small to large to maximized and this layout adapts.
struct PrivateOverlayView: View {
    @ObservedObject var aiEngine: AIEngineController
    @ObservedObject var chatSessionManager: ChatSessionManager
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var captureVisibility = CaptureVisibilityState.shared
    @ObservedObject private var overlayVisibility = OverlayVisibilityState.shared
    @State private var showShortcuts = false
    /// Throttles the auto-scroll-to-bottom below - without this, a fast-streaming response
    /// (many small SSE text deltas per second) fired an animated ScrollViewReader.scrollTo
    /// on every single delta.
    @State private var lastAutoScrollAt = Date.distantPast

    /// How many of the viewed session's most recent messages are actually rendered - see
    /// `ChatSessionManager.viewingWindow(limit:)`. Bounds `ForEach`'s diff/construct cost to a
    /// constant regardless of total conversation length; ALL messages remain in
    /// `ChatSession.messages` and reachable via "load earlier" (`loadEarlierSentinel`) - this
    /// only bounds what's rendered, never what's stored.
    @State private var visibleMessageCount = Self.defaultWindowSize
    /// Which session `visibleMessageCount` currently applies to - lets `body` fall back to
    /// `defaultWindowSize` for a freshly-switched-to session on the SAME render that switches
    /// to it (rather than one render later, via `onChange`, which would show a stale window
    /// size from whatever session was previously being viewed for one frame).
    @State private var windowedSessionID: UUID?
    /// Geometry for `ScrollFollowState.isNearBottom` - see `bottomAnchor`/
    /// `scrollViewportHeightReader` for where these are actually measured. Deliberately just
    /// two numbers, not per-message geometry: cost is O(1) per layout pass, not O(messages).
    @State private var bottomAnchorY: CGFloat = .greatestFiniteMagnitude
    @State private var viewportHeight: CGFloat = 0

    private static let defaultWindowSize = 50
    private static let loadMoreIncrement = 100
    private static let scrollCoordinateSpace = "chatScroll"

    private var isNearBottom: Bool {
        ScrollFollowState.isNearBottom(bottomAnchorY: bottomAnchorY, viewportHeight: viewportHeight)
    }

    /// The user's own explicit choice, persisted across launches - NOT re-derived from
    /// window width on every render. Defaults to expanded, since the app's default window
    /// size (420pt) is comfortably above `minimumWidthForExpandedSidebar` below; a genuinely
    /// narrow window still forces the collapsed rail regardless of this preference (see
    /// `isSidebarExpanded(availableWidth:)`), but that's a hard physical-space floor, not a
    /// silent override of what the user chose - widening the window again honors this value
    /// immediately.
    @AppStorage("overlay.sidebarExpandedPreference") private var sidebarExpandedPreference = true

    /// PrivateOverlayView's initializer only takes `aiEngine` - `chatSessionManager` is read
    /// off it rather than passed separately, so PrivateOverlayWindowController's construction
    /// site needs no change at all.
    init(aiEngine: AIEngineController) {
        self.aiEngine = aiEngine
        self.chatSessionManager = aiEngine.chatSessionManager
    }

    /// Below this width there genuinely isn't room for a 220pt sidebar alongside usable chat
    /// content - the collapsed rail is forced regardless of the stored preference. Comfortably
    /// above the window's absolute `minSize.width` (280), comfortably below `defaultSize.width`
    /// (420), so a fresh install at the default size sees the sidebar the user would expect
    /// (expanded, since that's the default preference), not force-collapsed.
    private static let minimumWidthForExpandedSidebar: CGFloat = 380

    private func isSidebarExpanded(availableWidth: CGFloat) -> Bool {
        guard availableWidth >= Self.minimumWidthForExpandedSidebar else { return false }
        return sidebarExpandedPreference
    }

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.height < 420
            let sidebarExpanded = isSidebarExpanded(availableWidth: geo.size.width)
            // Looked up once per body evaluation and threaded through as plain values below,
            // rather than each dependent view independently re-running its own lookup - this
            // was happening up to ~7 times per single recompute before (isStreaming, the
            // header's empty-state check, chatFeed, both scroll helpers, both onChange
            // comparisons). `viewingWindow`/`recordingSessionStatus` (rather than the full
            // `viewingSession`/`recordingSession`) deliberately never expose the full messages
            // array here - see their doc comments in ChatSessionManager for why that matters
            // for long-chat performance, not just convenience.
            let currentViewingID = chatSessionManager.viewingSessionID
            let effectiveWindowSize = (windowedSessionID == currentViewingID) ? visibleMessageCount : Self.defaultWindowSize
            let window = chatSessionManager.viewingWindow(limit: effectiveWindowSize)
            let recordingStatus = chatSessionManager.recordingSessionStatus
            let isViewingLive = recordingStatus != nil && window.sessionID == recordingStatus?.id

            VStack(alignment: .leading, spacing: 0) {
                if captureVisibility.isVisibleToCapture {
                    debugVisibleBanner
                }
                HStack(spacing: 0) {
                    SessionSidebarView(
                        chatSessionManager: chatSessionManager,
                        sidebarViewModel: chatSessionManager.sidebarViewModel,
                        projectManager: aiEngine.projectManager,
                        isExpanded: sidebarExpanded,
                        onToggleExpanded: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarExpandedPreference.toggle()
                            }
                        }
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        header(
                            compact: isCompact,
                            availableWidth: geo.size.width,
                            viewingTitle: window.title,
                            viewingIsEmpty: window.totalMessageCount == 0,
                            recordingStatus: recordingStatus,
                            isViewingLive: isViewingLive
                        )
                        .overlay(alignment: .topTrailing) { shortcutsButton }
                        if !aiEngine.teamsParticipants.isEmpty {
                            participantsRow
                        }
                        Divider().background(Color.white.opacity(0.1))
                        chatFeed(window: window)
                        footer
                    }
                }
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
    /// visibly speeds up/brightens the instant Gemini starts responding. Deliberately reads
    /// the RECORDING session, not whatever's being viewed: this is "is Friday actively doing
    /// something right now," which is real live activity regardless of what you're browsing -
    /// it must not go quiet just because you switched to reading an old chat while a real
    /// response is streaming into the live one.
    private func isStreaming(recordingStatus: ChatSessionManager.RecordingSessionStatus?) -> Bool {
        recordingStatus?.isStreaming ?? false
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
        .buttonStyle(PlainInteractiveButtonStyle())
        .interactiveControl()
        .help("Keyboard shortcuts")
        .padding(4)
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

    /// The big centered hero avatar before the VIEWED session has any content. Once it does,
    /// `activeHeader` takes over instead - this is about layout for whatever's on screen, so
    /// it deliberately reads the viewed session (unlike `isStreaming` above, which reads the
    /// recording session on purpose).
    @ViewBuilder
    private func header(compact: Bool, availableWidth: CGFloat, viewingTitle: String?, viewingIsEmpty: Bool, recordingStatus: ChatSessionManager.RecordingSessionStatus?, isViewingLive: Bool) -> some View {
        if viewingIsEmpty {
            idleHeader(compact: compact, availableWidth: availableWidth, viewingTitle: viewingTitle, recordingStatus: recordingStatus, isViewingLive: isViewingLive)
        } else {
            activeHeader(viewingTitle: viewingTitle, recordingStatus: recordingStatus, isViewingLive: isViewingLive)
        }
    }

    private func idleHeader(compact: Bool, availableWidth: CGFloat, viewingTitle: String?, recordingStatus: ChatSessionManager.RecordingSessionStatus?, isViewingLive: Bool) -> some View {
        let blobSize = compact ? 56.0 : min(120.0, availableWidth * 0.32)
        return VStack(spacing: 6) {
            AvatarBlobView(isActive: aiEngine.isActive, isStreaming: isStreaming(recordingStatus: recordingStatus), isPaused: !overlayVisibility.isVisible)
                .frame(width: blobSize, height: blobSize)
            Text(settings.agentName)
                .font(.system(size: compact ? 13 : 16, weight: .bold))
                .foregroundColor(.white)
            headerSubtitle(viewingTitle: viewingTitle, recordingStatus: recordingStatus, isViewingLive: isViewingLive, fontSize: 11)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, compact ? 10 : 20)
        .padding(.bottom, 10)
    }

    /// Small inline avatar once something's actually been heard - frees up vertical space
    /// for the chat feed instead of keeping the big idle hero avatar around
    private func activeHeader(viewingTitle: String?, recordingStatus: ChatSessionManager.RecordingSessionStatus?, isViewingLive: Bool) -> some View {
        HStack(spacing: 10) {
            AvatarBlobView(isActive: aiEngine.isActive, isStreaming: isStreaming(recordingStatus: recordingStatus), isPaused: !overlayVisibility.isVisible)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.agentName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                headerSubtitle(viewingTitle: viewingTitle, recordingStatus: recordingStatus, isViewingLive: isViewingLive, fontSize: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The line under the agent name: normally the connection status (unchanged, still the
    /// most informative thing to show for the common case), but when the user is viewing a
    /// DIFFERENT session than the one actively recording, this swaps to say exactly that plus
    /// a way back - "you are looking at an old conversation while Friday is still listening
    /// somewhere else" needs to be obvious from the main pane, not just the sidebar.
    @ViewBuilder
    private func headerSubtitle(viewingTitle: String?, recordingStatus: ChatSessionManager.RecordingSessionStatus?, isViewingLive: Bool, fontSize: CGFloat) -> some View {
        if let recordingStatus, !isViewingLive {
            HStack(spacing: 6) {
                Text("Viewing: \(viewingTitle ?? "")")
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                returnToLiveButton(recordingSessionID: recordingStatus.id)
            }
        } else {
            Text(statusText)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(.gray)
        }
    }

    private func returnToLiveButton(recordingSessionID: UUID) -> some View {
        Button {
            chatSessionManager.switchViewing(to: recordingSessionID)
        } label: {
            Text("Return to Live")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.yellow)
        }
        .buttonStyle(PlainInteractiveButtonStyle())
        .interactiveControl(cornerRadius: 4, hoverOpacity: 0.15)
        .help("Return to the live conversation")
        .accessibilityLabel("Return to the live conversation")
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

    /// Renders only `window.recentMessages` (bounded, see `ChatSessionManager.viewingWindow`),
    /// never the full session - `ForEach`'s diff/construct cost is proportional to what it's
    /// given, so this is what keeps a 2000-message session from costing more per delta than a
    /// 20-message one. `window.hasEarlierMessages`/`loadEarlierSentinel` are how the rest of
    /// the (never-deleted) history stays reachable.
    private func chatFeed(window: ChatSessionManager.ViewingWindow) -> some View {
        let messages = window.recentMessages
        let firstVisibleID = messages.first?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        Text("Listening… press ⌘⇧R whenever you want a response")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    if window.hasEarlierMessages {
                        loadEarlierSentinel(anchorID: firstVisibleID, proxy: proxy)
                    }
                    ForEach(messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }
                    bottomAnchor
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .background(scrollViewportHeightReader)
            .onPreferenceChange(BottomAnchorYKey.self) { bottomAnchorY = $0 }
            .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
            .onChange(of: messages.last?.id) { _ in
                // A genuinely NEW message was appended (not just the current one growing) -
                // low-frequency by nature (once per heard/response turn), so this is
                // deliberately not throttled.
                if ScrollFollowState.shouldFollow(isNearBottom: isNearBottom) {
                    scrollToBottom(proxy: proxy, messages: messages, animated: true)
                }
            }
            .onChange(of: messages.last?.text) { _ in
                // The current message growing via streaming deltas - fires many times a
                // second, so leading-edge throttled: nothing is lost by only actually
                // scrolling every ~150ms, the eye can't tell the difference, and it cuts a
                // lot of redundant animated layout work during a long response.
                if ScrollFollowState.shouldFollow(isNearBottom: isNearBottom) {
                    scrollToBottomIfDue(proxy: proxy, messages: messages)
                }
            }
            .onChange(of: messages.last?.isStreaming) { _ in
                // Guarantees the final position lands exactly at the bottom once a response
                // finishes, even if the throttle above skipped the very last delta.
                if ScrollFollowState.shouldFollow(isNearBottom: isNearBottom) {
                    scrollToBottom(proxy: proxy, messages: messages, animated: true)
                }
            }
            .onChange(of: chatSessionManager.viewingSessionID) { newID in
                // Opening a (possibly long) different session: reset the window to the
                // default size and jump straight to its latest message, unconditionally and
                // WITHOUT animation - never animate through hundreds of intervening messages,
                // and never leave a stale large window size from whatever was previously
                // being viewed.
                windowedSessionID = newID
                visibleMessageCount = Self.defaultWindowSize
                scrollToBottom(proxy: proxy, messages: messages, animated: false)
            }
        }
    }

    private func loadEarlierSentinel(anchorID: UUID?, proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(height: 1)
            .onAppear { loadEarlier(anchorID: anchorID, proxy: proxy) }
    }

    /// Expands the render window by `loadMoreIncrement` and re-anchors the scroll position to
    /// what was previously the topmost rendered message - without this, revealing more history
    /// above the current viewport would shove everything else down and the view would appear
    /// to "jump". Deferred one runloop tick (`DispatchQueue.main.async`) so the re-anchor scroll
    /// happens AFTER the newly-revealed rows have actually been laid out, not before.
    private func loadEarlier(anchorID: UUID?, proxy: ScrollViewProxy) {
        visibleMessageCount += Self.loadMoreIncrement
        windowedSessionID = chatSessionManager.viewingSessionID
        guard let anchorID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    /// An invisible 1pt sentinel at the very end of the feed - its position (reported via
    /// `BottomAnchorYKey`) is what `ScrollFollowState.isNearBottom` compares against the
    /// visible viewport height to decide whether the user is "at the bottom". One geometry
    /// read per layout pass, not one per message.
    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: BottomAnchorYKey.self, value: geo.frame(in: .named(Self.scrollCoordinateSpace)).maxY)
                }
            )
    }

    private var scrollViewportHeightReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
        }
    }

    private func scrollToBottomIfDue(proxy: ScrollViewProxy, messages: [ChatMessage]) {
        guard Date().timeIntervalSince(lastAutoScrollAt) >= 0.15 else { return }
        scrollToBottom(proxy: proxy, messages: messages, animated: true)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, messages: [ChatMessage], animated: Bool) {
        guard let lastID = messages.last?.id else { return }
        lastAutoScrollAt = Date()
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(lastID, anchor: .bottom)
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

/// Reports the chat feed's bottom sentinel's position within the scroll view's own coordinate
/// space - see `PrivateOverlayView.bottomAnchor`/`ScrollFollowState.isNearBottom`.
private struct BottomAnchorYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reports the chat feed's visible viewport height - see
/// `PrivateOverlayView.scrollViewportHeightReader`/`ScrollFollowState.isNearBottom`.
private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
