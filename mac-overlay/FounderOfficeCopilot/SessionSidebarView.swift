import SwiftUI

// MARK: - Session Sidebar
/// The session list: collapsible, searchable, grouped Today/Yesterday/Older, plus New Chat
/// and a pinned "currently recording" indicator that doubles as "return to it". Every
/// interaction here calls ONLY ChatSessionManager's viewing-only API (switchViewing,
/// createSession, rename, setArchived, delete) - never AIEngineController or either Gemini
/// client, so browsing sessions can never affect what's actively recording. Row taps in
/// particular are a single line calling switchViewing(to:) and nothing else, deliberately,
/// so that's easy to audit at a glance.
///
/// Deliberately observes `sidebarViewModel` (a derived, read-only structural projection - see
/// its doc comment in ChatSessionManager.swift), NOT `chatSessionManager` itself, which is
/// what makes this view immune to the high-frequency content updates that live transcription
/// and response streaming produce - `chatSessionManager` is still held (unobserved) purely to
/// call its action methods and, only while actively searching, to read live content.
struct SessionSidebarView: View {
    let chatSessionManager: ChatSessionManager
    @ObservedObject var sidebarViewModel: SidebarViewModel
    /// Phase 4.1 - `@ObservedObject` (not just `let`, matching `sidebarViewModel` rather than
    /// `chatSessionManager`'s unobserved-action-only pattern) so a row's project badge and the
    /// "Project" submenu's contents update live the moment a project is created or a session is
    /// (re)assigned - `ProjectManager.projects`/`sessionLinks` are both `@Published`. Every
    /// interaction here calls ONLY `ProjectManager`'s own session-association API
    /// (`createProject`, `assignSession`, `unassignSession`, `project(forSession:)`) - never
    /// anything that touches `recordingSessionID`/`viewingSessionID`, exactly the same
    /// independence guarantee already documented above for `chatSessionManager`.
    @ObservedObject var projectManager: ProjectManager
    /// Whether to render expanded or as a collapsed rail - computed by PrivateOverlayView
    /// (it alone knows the available window width), not decided here.
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    @State private var searchQuery: String = ""
    @State private var sessionPendingDelete: PendingSession?
    @State private var sessionPendingRename: PendingSession?
    @State private var renameText: String = ""
    @State private var isArchivedSectionExpanded = false
    /// Phase 4.1 - which row's "New Project…" alert is open, if any.
    @State private var sessionPendingNewProject: PendingSession?
    @State private var newProjectName: String = ""

    static let expandedWidth: CGFloat = 220
    static let collapsedWidth: CGFloat = 44

    /// Just enough to drive a row/confirmation dialog - deliberately not a whole ChatSession,
    /// since this needs to represent a row from either the summary projection (idle) or full
    /// session data (actively searching) without those two shapes needing to unify.
    private struct PendingSession: Identifiable {
        let id: UUID
        let title: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            recordingIndicator
            Divider().background(Color.white.opacity(0.08))
            if isExpanded {
                searchField
                sessionList
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .trailing) {
            Divider().background(Color.white.opacity(0.08))
        }
        .confirmationDialog(
            "Delete “\(sessionPendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { sessionPendingDelete != nil }, set: { if !$0 { sessionPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = sessionPendingDelete?.id { chatSessionManager.delete(id) }
                sessionPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingDelete = nil }
        } message: {
            Text("This can’t be undone.")
        }
        .alert(
            "Rename Chat",
            isPresented: Binding(get: { sessionPendingRename != nil }, set: { if !$0 { sessionPendingRename = nil } })
        ) {
            TextField("Title", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = sessionPendingRename?.id, !trimmed.isEmpty {
                    chatSessionManager.rename(id, to: trimmed)
                }
                sessionPendingRename = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingRename = nil }
        }
        .alert(
            "New Project",
            isPresented: Binding(get: { sessionPendingNewProject != nil }, set: { if !$0 { sessionPendingNewProject = nil } })
        ) {
            TextField("Project name", text: $newProjectName)
            Button("Create") {
                let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let sessionID = sessionPendingNewProject?.id, !trimmed.isEmpty {
                    let project = projectManager.createProject(Project(name: trimmed))
                    projectManager.assignSession(sessionID, to: project.id)
                }
                sessionPendingNewProject = nil
                newProjectName = ""
            }
            Button("Cancel", role: .cancel) {
                sessionPendingNewProject = nil
                newProjectName = ""
            }
        }
    }

    // MARK: Header (New Chat + collapse toggle - both always reachable, in either state)

    private var header: some View {
        HStack(spacing: 4) {
            if isExpanded {
                Text("Chats")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
            }
            newChatButton
            toggleButton
        }
        .padding(.horizontal, isExpanded ? 10 : 4)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var newChatButton: some View {
        Button {
            let id = chatSessionManager.createSession()
            chatSessionManager.switchViewing(to: id)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
        }
        .buttonStyle(PlainInteractiveButtonStyle())
        .interactiveControl()
        .help("New chat")
        .accessibilityLabel("New chat")
    }

    private var toggleButton: some View {
        Button(action: onToggleExpanded) {
            Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.gray)
        }
        .buttonStyle(PlainInteractiveButtonStyle())
        .interactiveControl()
        .help(isExpanded ? "Collapse chat list" : "Expand chat list")
        .accessibilityLabel(isExpanded ? "Collapse chat list" : "Expand chat list")
    }

    // MARK: Recording indicator - always visible (in both states) whenever something is
    // recording, regardless of what's being viewed. Doubles as "Return to Recording". A
    // static dot, deliberately not animated yet - see Phase 2.5 notes on measuring
    // performance before adding any more continuous rendering.

    @ViewBuilder
    private var recordingIndicator: some View {
        if let recordingID = sidebarViewModel.recordingSessionID,
           let recording = sidebarViewModel.summaries.first(where: { $0.id == recordingID }) {
            Button {
                chatSessionManager.switchViewing(to: recordingID)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Recording")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.red)
                            Text(recording.title)
                                .font(.system(size: 11))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(PlainInteractiveButtonStyle())
            .interactiveControl()
            .padding(.horizontal, isExpanded ? 6 : 2)
            .help("Recording: \(recording.title) — click to return to it")
            .accessibilityLabel("Recording: \(recording.title). Activate to return to it.")
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(.gray)
            TextField("Search chats", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainInteractiveButtonStyle())
                .interactiveControl(cornerRadius: 4, hoverOpacity: 0.15)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: Session list

    /// A common shape for what a row needs, regardless of whether it came from the cheap
    /// summary projection (idle) or full session content (actively searching) - this is what
    /// lets SessionRow stay decoupled from both ChatSession and SidebarViewModel.SessionSummary.
    private struct RowData: Identifiable {
        let id: UUID
        let title: String
        let lastActivity: Date
        let isArchived: Bool
    }

    private struct RowGroup {
        let title: String
        let rows: [RowData]
    }

    /// While the search field is empty, groups the cheap structural projection - this is the
    /// common "meeting running in the background, sidebar just sitting there" case, and it
    /// never touches `chatSessionManager.sessions` (the array live transcription/responses
    /// mutate) at all. Only once the user types something does this fall back to full
    /// session/message content, for that one explicit action - see SessionSearch's own doc
    /// comment for why message-text search needs it.
    private var groups: [RowGroup] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return SidebarViewModel.grouped(sidebarViewModel.summaries).map { group in
                RowGroup(title: group.title, rows: group.summaries.map {
                    RowData(id: $0.id, title: $0.title, lastActivity: $0.lastMessageAt ?? $0.createdAt, isArchived: $0.isArchived)
                })
            }
        } else {
            return SessionSearch.grouped(chatSessionManager.sessions, query: trimmed).map { group in
                RowGroup(title: group.title, rows: group.sessions.map {
                    RowData(id: $0.id, title: $0.title, lastActivity: $0.lastMessageAt ?? $0.createdAt, isArchived: $0.isArchived)
                })
            }
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                let currentGroups = groups
                if currentGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(currentGroups, id: \.title) { group in
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.rows) { row in
                            sessionRow(row)
                        }
                    }
                }
                archivedDisclosure
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var archivedDisclosure: some View {
        let archived = sidebarViewModel.summaries.filter(\.isArchived)
        if !archived.isEmpty {
            DisclosureGroup(isExpanded: $isArchivedSectionExpanded) {
                ForEach(archived) { summary in
                    sessionRow(RowData(id: summary.id, title: summary.title, lastActivity: summary.lastMessageAt ?? summary.createdAt, isArchived: true))
                }
            } label: {
                Text("Archived (\(archived.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.gray)
                    .pointingHandCursor()
            } .padding(.horizontal, 12)
            .padding(.top, 8)
            .tint(.gray)
        }
    }

    /// Phase 4.1 - the row's currently-assigned project, if any, resolved live via
    /// `ProjectManager.project(forSession:)` - NEVER cached, matching the same "always a live
    /// lookup, never a stored current-project field" rule `ProjectManager` itself follows.
    private func assignedProject(for sessionID: UUID) -> Project? {
        guard let projectID = projectManager.project(forSession: sessionID) else { return nil }
        return projectManager.project(id: projectID)
    }

    private func sessionRow(_ row: RowData) -> some View {
        let assigned = assignedProject(for: row.id)
        return SessionRow(
            title: row.title,
            lastActivity: row.lastActivity,
            isRecording: row.id == sidebarViewModel.recordingSessionID,
            isPending: row.id == sidebarViewModel.pendingRecordingSessionID,
            isSelected: row.id == sidebarViewModel.viewingSessionID,
            isArchived: row.isArchived,
            canRecordHere: sidebarViewModel.recordingSessionID == nil,
            assignedProjectName: assigned?.name,
            otherProjects: projectManager.projects.filter { $0.id != assigned?.id },
            onSelect: { chatSessionManager.switchViewing(to: row.id) },
            onRename: {
                renameText = row.title
                sessionPendingRename = PendingSession(id: row.id, title: row.title)
            },
            onArchiveToggle: { chatSessionManager.setArchived(row.id, !row.isArchived) },
            onDelete: { sessionPendingDelete = PendingSession(id: row.id, title: row.title) },
            onRecordHere: { chatSessionManager.recordHere(row.id) },
            onCancelRecordingTarget: { chatSessionManager.cancelRecordingTarget() },
            onAssignToProject: { projectID in projectManager.assignSession(row.id, to: projectID) },
            onNewProject: {
                newProjectName = ""
                sessionPendingNewProject = PendingSession(id: row.id, title: row.title)
            },
            onRemoveFromProject: { projectManager.unassignSession(row.id) }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 4) {
            if trimmedQuery.isEmpty {
                Text("No chats yet")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            } else {
                Text("No chats found for “\(trimmedQuery)”")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.horizontal, 12)
    }
}

// MARK: - Session Row
/// Selected state reads as a left accent bar + bolded title (quiet, not a checkmark badge).
/// Recording and "recording target" states are both a small static dot inline with the
/// title - filled red for actively recording, outlined for designated-but-not-yet-recording
/// - kept visually distinct from the accent bar so a row that's also selected doesn't read as
/// two competing indicators on the same edge. The two dot states are mutually exclusive by
/// construction (ChatSessionManager never lets a pending target survive past the recording
/// it was consumed by), so a row is never shown as both at once.
private struct SessionRow: View {
    let title: String
    let lastActivity: Date
    let isRecording: Bool
    let isPending: Bool
    let isSelected: Bool
    let isArchived: Bool
    /// Whether "Record Here" should be offered at all - false whenever anything is already
    /// recording (anywhere), not just on the active row, so the action never appears
    /// somewhere it would just be silently ignored.
    let canRecordHere: Bool
    /// Phase 4.1 - nil if this session isn't linked to any project.
    let assignedProjectName: String?
    /// Every OTHER existing project (excludes whichever one is currently assigned, if any) -
    /// what the "Project" submenu offers to assign/reassign to, plus "New Project…".
    let otherProjects: [Project]
    let onSelect: () -> Void
    let onRename: () -> Void
    let onArchiveToggle: () -> Void
    let onDelete: () -> Void
    let onRecordHere: () -> Void
    let onCancelRecordingTarget: () -> Void
    let onAssignToProject: (UUID) -> Void
    let onNewProject: () -> Void
    let onRemoveFromProject: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? Color.yellow : Color.clear)
                    .frame(width: 3, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if isRecording {
                            Circle().fill(Color.red).frame(width: 5, height: 5)
                        } else if isPending {
                            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1).frame(width: 5, height: 5)
                        }
                    }
                    Text(rowSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(isPending ? .white.opacity(0.7) : .gray)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
            .cornerRadius(6)
        }
        .buttonStyle(PlainInteractiveButtonStyle())
        .padding(.horizontal, 6)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…", action: onRename)
            if isPending {
                Button("Cancel Recording Target", action: onCancelRecordingTarget)
            } else if canRecordHere {
                Button("Record Here", action: onRecordHere)
            }
            Divider()
            projectMenu
            Divider()
            Button(isArchived ? "Unarchive" : "Archive", action: onArchiveToggle)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .help("\(title) — right-click for more options")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var rowBackground: Color {
        if isSelected { return Color.yellow.opacity(0.12) }
        if isHovering { return Color.white.opacity(0.06) }
        return Color.clear
    }

    /// "Recording Target" replaces the relative-time line while pending - the session hasn't
    /// been touched yet (there's nothing new to say about "when"), and this is the moment the
    /// designation itself is the most useful thing to communicate. The assigned project name
    /// (Phase 4.1), when present, is appended after a middle dot - this is the row's only
    /// "which project is this session in" indicator, deliberately not a separate badge/row.
    private var rowSubtitle: String {
        let base = isPending ? "Recording Target" : Self.relativeTime(lastActivity)
        guard let assignedProjectName else { return base }
        return "\(base) · \(assignedProjectName)"
    }

    /// The "Project" submenu - offered on every row regardless of recording/pending state,
    /// exactly like Rename/Archive/Delete already are. Mirrors the exact
    /// `Menu { ForEach ... ; Divider() ; Button(...) }`-inside-`.contextMenu` shape SwiftUI
    /// already supports for nested menus.
    @ViewBuilder
    private var projectMenu: some View {
        Menu(assignedProjectName.map { "Project: \($0)" } ?? "Assign to Project") {
            ForEach(otherProjects) { project in
                Button(project.name) { onAssignToProject(project.id) }
            }
            if !otherProjects.isEmpty {
                Divider()
            }
            Button("New Project…", action: onNewProject)
            if assignedProjectName != nil {
                Divider()
                Button("Remove from Project", action: onRemoveFromProject)
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [title, Self.relativeTime(lastActivity)]
        if isRecording { parts.append("currently recording") }
        if isPending { parts.append("designated as the next recording target") }
        if isSelected { parts.append("selected") }
        if let assignedProjectName { parts.append("in project \(assignedProjectName)") }
        return parts.joined(separator: ", ")
    }

    static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
