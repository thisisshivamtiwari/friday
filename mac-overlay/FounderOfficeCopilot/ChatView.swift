import SwiftUI

// MARK: - Chat
/// The workspace's conversation surface, and the half of the core loop that was previously only
/// available in the floating overlay.
///
/// It drives the SAME `AIEngineController.requestResponse()` the overlay does - same retrieval,
/// same context construction, same grounding, same generator. There is deliberately no second AI
/// pipeline: a parallel path would drift from the validated one, and the sources shown here
/// would stop describing the answer given.
struct ChatView: View {
    @ObservedObject var engine: AIEngineController
    @ObservedObject var sessions: ChatSessionManager
    @ObservedObject var evidence: ResponseEvidenceStore
    @ObservedObject var workspace: WorkspaceModel
    /// A question staged by "Ask AI about this". Placed in the composer and focused rather than
    /// sent, so the user reviews and edits before anything is asked on their behalf.
    @Binding var seededPrompt: String?
    /// Raised when the user opens a source, so the workspace can show the entity it points at.
    let openEntity: (AnswerSource) -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    /// Which project this conversation is about. This is not decoration: retrieval scopes
    /// evidence by the session's project link (`ProjectResolution` Tier 1), so without it a
    /// question about project work retrieves nothing and the assistant correctly - but
    /// uselessly - answers "I don't have that stored". Defaults to the most recently active
    /// project and is always visible, so the scope is never a hidden decision.
    @State private var selectedProjectID: UUID?

    private var messages: [ChatMessage] {
        sessions.sessions.first { $0.id == sessions.viewingSessionID ?? sessions.recordingSessionID }?.messages ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                EmptyStateView(
                    icon: "text.bubble",
                    title: "Ask about your work",
                    message: "Ask what was decided, what is still outstanding, or why something changed. Every answer shows the projects, decisions and conversations it came from."
                )
            } else {
                transcript
            }
            Divider()
            composer
        }
        .background(DS.Surface.canvas)
        .onChange(of: seededPrompt) { prompt in
            guard let prompt else { return }
            draft = prompt
            seededPrompt = nil
            composerFocused = true
        }
        .onAppear {
            if let prompt = seededPrompt { draft = prompt; seededPrompt = nil; composerFocused = true }
            // Start scoped to whatever the founder was last working on - the most useful default,
            // and visible in the picker rather than implicit.
            if selectedProjectID == nil {
                selectedProjectID = sessions.recordingSessionID.flatMap { workspace.projects.project(forSession: $0) }
                    ?? workspace.activeProjects.first?.id
                applyProjectScope()
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            references: evidence.references(for: message.id),
                            openEntity: openEntity
                        )
                        .id(message.id)
                    }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Follows the conversation as it streams, which is what makes a long answer readable
            // without the user chasing it.
            .onChange(of: messages.last?.text) { _ in
                guard let last = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    // MARK: Composer

    private var isBusy: Bool { messages.last?.isStreaming == true }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .bottom, spacing: DS.Space.s) {
                // A real multiline field: a founder's question is often two sentences, and a
                // single-line box that scrolls sideways makes it unreadable while typing.
                TextEditor(text: $draft)
                    .font(DS.Font.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 34, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($composerFocused)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.medium)
                            .stroke(composerFocused ? Color.accentColor.opacity(0.55) : DS.Surface.hairline)
                    )
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ask about your projects, decisions or work…")
                                .font(DS.Font.body).foregroundColor(.secondary)
                                .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Message")

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundColor(canSend ? .accentColor : .secondary.opacity(0.4))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
                .accessibilityLabel("Send message")
            }

            HStack(spacing: DS.Space.s) {
                projectPicker
                Divider().frame(height: 12)
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(DS.Font.caption).foregroundColor(.secondary)
                } else if !engine.hasAPIKey {
                    // The one genuine precondition, stated plainly and with somewhere to go.
                    Image(systemName: "key").font(DS.Font.caption).foregroundColor(.secondary)
                    Text("Add a Gemini API key in Settings to ask questions.")
                        .font(DS.Font.caption).foregroundColor(.secondary)
                } else if engine.isListening {
                    Image(systemName: "waveform").font(DS.Font.caption).foregroundColor(.accentColor)
                    Text("Listening — ⌘↩ to send").font(DS.Font.caption).foregroundColor(.secondary)
                } else {
                    Text("⌘↩ to send").font(DS.Font.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Scope control. Assigning a session to a project is the app's ONE existing mechanism for
    /// this (`ProjectSessionLink`, the single source of truth), so this reuses it rather than
    /// introducing a second notion of "which project is this about".
    private var projectPicker: some View {
        Picker("", selection: $selectedProjectID) {
            Text("No project").tag(UUID?.none)
            ForEach(workspace.allProjectsByActivity) { project in
                Text(project.name).tag(UUID?.some(project.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 240)
        .help("Which project this conversation is about. Answers are grounded in this project's work, decisions and history.")
        .accessibilityLabel("Project context for this conversation")
        .onChange(of: selectedProjectID) { _ in applyProjectScope() }
    }

    /// Links the live session to the chosen project. Called on selection AND before sending, so
    /// a question is never asked against a scope the user cannot see.
    private func applyProjectScope() {
        guard let sessionID = sessions.recordingSessionID ?? sessions.sessions.first(where: { $0.id == sessions.viewingSessionID })?.id else { return }
        if let selectedProjectID {
            workspace.projects.assignSession(sessionID, to: selectedProjectID)
        } else {
            workspace.projects.unassignSession(sessionID)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy && engine.hasAPIKey
    }

    /// A typed question enters the conversation exactly the way a heard one does, then triggers
    /// the same response path. That is what makes retrieval see it - `ContextEngine` builds its
    /// packet from the current turn's text, so a question that never became a turn would be
    /// answered with no context at all.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Ensures there is a session to write into. `beginRecording()` is pure session
        // bookkeeping - it does not start audio or open a live session - so typing a question
        // never switches the microphone on.
        _ = sessions.beginRecording()
        applyProjectScope()
        sessions.appendHeardDelta(text)
        draft = ""
        engine.requestResponse()
    }
}

// MARK: - Message

private struct MessageRow: View {
    let message: ChatMessage
    let references: [AnswerSource]
    let openEntity: (AnswerSource) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(message.role == .heard ? "YOU" : "COPILOT")
                    .font(DS.Font.metadata)
                    .foregroundColor(message.role == .heard ? .secondary : .accentColor)
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(DS.Font.caption).foregroundColor(.secondary.opacity(0.7))
                Spacer()
                if isHovering && !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(DS.Font.caption)
                    }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                    .help("Copy").accessibilityLabel("Copy message")
                }
            }

            Text(message.text.isEmpty && message.isStreaming ? "…" : message.text)
                .font(DS.Font.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if message.role == .response, !references.isEmpty {
                SourcesDisclosure(references: references, openEntity: openEntity)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(message.role == .heard ? "You" : "Copilot") at \(message.timestamp.formatted(date: .omitted, time: .shortened))")
    }
}

// MARK: - Sources

/// The trust surface. Collapsed it is a single quiet line; expanded it lists exactly what the
/// retrieval layer supplied, each row navigable to the entity it names.
struct SourcesDisclosure: View {
    let references: [AnswerSource]
    let openEntity: (AnswerSource) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Sources · \(references.count)").font(DS.Font.caption)
                }
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(references.count.pluralised("source")). \(isExpanded ? "Expanded" : "Collapsed")")
            .accessibilityHint("Show what this answer was based on")

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    ForEach(references) { reference in
                        Button { openEntity(reference) } label: {
                            HStack(alignment: .top, spacing: DS.Space.s) {
                                Image(systemName: reference.kind.icon)
                                    .font(DS.Font.caption).foregroundColor(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(reference.kind.label.uppercased())
                                        .font(DS.Font.metadata).foregroundColor(.secondary)
                                    Text(reference.title)
                                        .font(DS.Font.callout).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let subtitle = reference.subtitle, !subtitle.isEmpty {
                                        Text(subtitle).font(DS.Font.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                            }
                            .padding(DS.Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(reference.kind.label): \(reference.title)")
                        .accessibilityHint("Open this \(reference.kind.label.lowercased())")
                    }
                }
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.Surface.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).stroke(DS.Surface.hairline))
            }
        }
        .padding(.top, DS.Space.xs)
    }
}
