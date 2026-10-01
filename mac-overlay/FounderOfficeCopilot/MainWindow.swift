import SwiftUI
import AppKit

// MARK: - Main Window
/// The application's primary window: a standard macOS sidebar + detail split.
///
/// This does NOT replace the floating overlay. The two surfaces answer different questions and
/// both earn their place: the overlay is glanceable, always-available heads-up assistance during
/// a live meeting, while this window is where the founder reads, explores and understands
/// accumulated state at their own pace. They share one object graph - the same
/// `AIEngineController`, therefore the same stores - so anything captured in a meeting is
/// present here the moment extraction lands.
final class MainWindowController: NSWindowController {
    /// Managers are injected from the app's single `AIEngineController`. Constructing new ones
    /// would open second handles on the same stores and show state that silently diverges from
    /// what the running assistant is using.
    init(engine: AIEngineController) {
        let projectManager = engine.projectManager
        let memoryManager = engine.memoryManager
        let chatSessionManager = engine.chatSessionManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Founder Office Copilot"
        window.titlebarAppearsTransparent = false
        window.setFrameAutosaveName("FounderOfficeCopilot.Main")
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 600)

        let workspace = WorkspaceModel(projects: projectManager, memory: memoryManager, sessions: chatSessionManager)
        window.contentView = NSHostingView(rootView: MainWindowView(
            workspace: workspace,
            engine: engine,
            graphManagers: (projectManager, memoryManager, chatSessionManager)
        ))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        applyAppearance()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Applied to THIS window rather than `NSApp`, so the always-on overlay keeps the dark
    /// treatment it was designed against regardless of the workspace preference.
    func applyAppearance() {
        window?.appearance = SettingsStore.shared.appearance.nsAppearance
    }
}

// MARK: - Destinations

/// The app's information architecture, in one place. Ordered by how often a founder needs it,
/// not by how the code is organised.
enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home
    case chat
    case projects
    case work
    case decisions
    case people
    case timeline
    case knowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .chat: return "Chat"
        case .projects: return "Projects"
        case .work: return "Work"
        case .decisions: return "Decisions"
        case .people: return "People"
        case .timeline: return "Timeline"
        case .knowledge: return "Knowledge Graph"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .chat: return "text.bubble"
        case .projects: return "folder"
        case .work: return "checklist"
        case .decisions: return "checkmark.seal"
        case .people: return "person.2"
        case .timeline: return "clock"
        case .knowledge: return "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Root

struct MainWindowView: View {
    @StateObject var workspace: WorkspaceModel
    @ObservedObject var engine: AIEngineController
    let graphManagers: (ProjectManager, MemoryManager, ChatSessionManager)

    @State private var destination: WorkspaceDestination = MainWindowView.initialDestination

    /// Developer tooling only (see `AppDelegate`'s `--workspace-preview` block): lets a
    /// screenshot run land directly on a given screen. Defaults to Home for every real launch.
    static var initialDestination: WorkspaceDestination {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--workspace-tab=") })?
            .split(separator: "=").last, let value = WorkspaceDestination(rawValue: String(raw)) { return value }
        #endif
        return .home
    }
    @State private var selectedProjectID: UUID?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    /// The entity a source click asked to open, shown as an inspector sheet over whatever screen
    /// the user was on - so following a source never loses their place in the conversation.
    @State private var focusedEntity: EntityReference?
    /// Owned here, not rebuilt per navigation, so "Open in graph" can focus a node and the user
    /// finds it still focused when they come back.
    @StateObject private var graphModel: GraphViewModel
    /// A question staged for Chat by "Ask AI about this". Consumed by the composer.
    @State private var seededPrompt: String?
    @State private var isCreatingProject = false

    init(workspace: WorkspaceModel, engine: AIEngineController, graphManagers: (ProjectManager, MemoryManager, ChatSessionManager)) {
        _workspace = StateObject(wrappedValue: workspace)
        self.engine = engine
        self.graphManagers = graphManagers
        _graphModel = StateObject(wrappedValue: GraphViewModel(
            projectManager: graphManagers.0, memoryManager: graphManagers.1, chatSessionManager: graphManagers.2
        ))
    }

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(minWidth: 620)
        }
        .navigationTitle(destination.title)
        // Density is read by the design system at render time, so the view tree must be
        // invalidated when it changes - otherwise the setting appears to do nothing until the
        // next navigation.
        .id(settings.density)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingProject = true
                } label: {
                    Label("New project", systemImage: "plus")
                }
                .help("New project (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isSearchPresented = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search everything (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        .sheet(isPresented: Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { if !$0 { settings.hasCompletedOnboarding = true } }
        )) {
            OnboardingView { settings.hasCompletedOnboarding = true }
        }
        .sheet(isPresented: $isCreatingProject) {
            NewProjectSheet(
                workspace: workspace,
                linkableSession: workspace.recentSessions.first
            ) { project in
                selectedProjectID = project.id
                destination = .projects
            }
        }
        .sheet(item: $focusedEntity) { entity in
            EntityInspectorSheet(
                workspace: workspace,
                entity: entity,
                navigate: { destination, projectID in
                    if let projectID { selectedProjectID = projectID }
                    self.destination = destination
                    focusedEntity = nil
                },
                openInGraph: { entity in
                    focusInGraph(entity)
                    destination = .knowledge
                    focusedEntity = nil
                },
                askAI: { prompt in
                    seededPrompt = prompt
                    destination = .chat
                    focusedEntity = nil
                }
            )
        }
        .sheet(isPresented: $isSearchPresented) {
            SearchPalette(
                workspace: workspace,
                isPresented: $isSearchPresented,
                onOpen: { open($0) },
                onAskAI: { entity, prompt in
                    seededPrompt = prompt
                    destination = .chat
                    isSearchPresented = false
                    _ = entity
                },
                onOpenInGraph: { entity in
                    focusInGraph(entity)
                    destination = .knowledge
                    isSearchPresented = false
                }
            )
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $destination) {
            Section {
                ForEach(WorkspaceDestination.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                        .accessibilityHint("Show \(item.title)")
                }
            }

            if !workspace.activeProjects.isEmpty {
                Section("Active projects") {
                    ForEach(workspace.activeProjects.prefix(6)) { project in
                        Button {
                            selectedProjectID = project.id
                            destination = .projects
                        } label: {
                            HStack(spacing: DS.Space.s) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 6))
                                    .foregroundColor(.accentColor.opacity(0.7))
                                Text(project.name).lineLimit(1)
                                Spacer()
                                let open = workspace.openItems(in: project.id).count
                                if open > 0 {
                                    Text("\(open)").font(DS.Font.caption).foregroundColor(.secondary).monospacedDigit()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(project.name), \(workspace.openItems(in: project.id).count.pluralised("open item"))")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 208, idealWidth: 232)
        .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 300)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .chat:
            ChatView(
                engine: engine,
                sessions: workspace.sessions,
                evidence: engine.responseEvidence,
                workspace: workspace,
                seededPrompt: $seededPrompt
            ) { reference in
                focusedEntity = EntityReference(reference)   // nil for evidence with no dedicated screen
            }
        case .home:
            HomeView(
                workspace: workspace,
                openProject: { projectID in
                    selectedProjectID = projectID
                    destination = .projects
                },
                openEntity: { focusedEntity = $0 },
                createProject: { isCreatingProject = true }
            )
        case .projects:
            ProjectsView(workspace: workspace, selectedProjectID: $selectedProjectID)
        case .work:
            WorkView(workspace: workspace)
        case .decisions:
            DecisionsView(workspace: workspace)
        case .people:
            PeopleView(workspace: workspace)
        case .timeline:
            ActivityTimelineView(workspace: workspace) { focusedEntity = $0 }
        case .knowledge:
            GraphView(model: graphModel) { focusedEntity = $0 }
        }
    }

    /// Selects and centres an entity's node in the graph. Nothing is drawn that the graph did
    /// not already contain - this only moves the camera and the selection to a node that exists.
    private func focusInGraph(_ entity: EntityReference) {
        guard let node = entity.graphNodeID else { return }
        graphModel.reload()
        graphModel.selection = node
        graphModel.focusSelection()
    }

    /// Search is a navigator, not a dead end: choosing a result lands the user on the surface
    /// that actually explains it.
    private func open(_ result: WorkspaceModel.SearchResult) {
        switch result {
        case .project(let project):
            selectedProjectID = project.id
            destination = .projects
        case .item(let item):
            selectedProjectID = item.projectID
            destination = .projects
        case .decision(let decision):
            selectedProjectID = decision.projectID
            destination = .projects
        case .person:
            destination = .people
        case .session(let session):
            focusedEntity = EntityReference(kind: .conversation(session.id))
        }
        isSearchPresented = false
    }
}

// MARK: - Search palette

/// ⌘F opens this. Keyboard-first: type, arrow through grouped results, Return to open, Escape to
/// dismiss - no pointer required at any step.
struct SearchPalette: View {
    @ObservedObject var workspace: WorkspaceModel
    @Binding var isPresented: Bool
    let onOpen: (WorkspaceModel.SearchResult) -> Void
    /// Ask about the result without leaving the keyboard. Seeds the composer - never submits.
    let onAskAI: (EntityReference, String) -> Void
    /// Focus the result's node in the knowledge graph.
    let onOpenInGraph: (EntityReference) -> Void

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private var results: [WorkspaceModel.SearchResult] { workspace.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search projects, work, decisions, people and conversations", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Font.title)
                    .focused($isFieldFocused)
                Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Close search")
            }
            .padding(DS.Space.l)

            Divider()

            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                EmptyStateView(icon: "magnifyingglass", title: "Search your workspace",
                               message: "Find any project, work item, decision, person or conversation. Type at least two characters.")
                    .frame(height: 260)
            } else if results.isEmpty {
                EmptyStateView(icon: "questionmark.circle", title: "Nothing found",
                               message: "No project, work item, decision, person or conversation matches “\(query)”.")
                    .frame(height: 260)
            } else {
                List {
                    group("Projects", results.compactMap { if case .project(let p) = $0 { return (p.id, p.name, p.status.rawValue, WorkspaceModel.SearchResult.project(p)) } else { return nil } })
                    group("Work", results.compactMap { if case .item(let i) = $0 { return (i.id, i.name, DS.lifecycleLabel(i.status), WorkspaceModel.SearchResult.item(i)) } else { return nil } })
                    group("Decisions", results.compactMap { if case .decision(let d) = $0 { return (d.id, d.statement, workspace.projectName(d.projectID) ?? "", WorkspaceModel.SearchResult.decision(d)) } else { return nil } })
                    group("People", results.compactMap { if case .person(let p) = $0 { return (p.id, p.name, "person", WorkspaceModel.SearchResult.person(p)) } else { return nil } })
                    group("Conversations", results.compactMap { if case .session(let s) = $0 { return (s.id, s.title, s.messages.count.pluralised("message"), WorkspaceModel.SearchResult.session(s)) } else { return nil } })
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 680, height: 480)
        .background(DS.Surface.canvas)
        .onAppear { isFieldFocused = true }
    }

    /// Maps a search result to the app's navigation currency, so search actions reuse exactly
    /// the same entity resolution the inspector and the graph use.
    private func entity(for result: WorkspaceModel.SearchResult) -> EntityReference? {
        switch result {
        case .project(let p): return EntityReference(kind: .project(p.id))
        case .item(let i): return EntityReference(kind: .workItem(i.id))
        case .decision(let d): return EntityReference(kind: .decision(d.id))
        case .person(let p): return EntityReference(kind: .person(p.id))
        case .session(let s): return EntityReference(kind: .conversation(s.id))
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [(UUID, String, String, WorkspaceModel.SearchResult)]) -> some View {
        if !rows.isEmpty {
            Section(header: Text(title.uppercased()).font(DS.Font.metadata)) {
                ForEach(rows, id: \.0) { row in
                    SearchResultRow(
                        title: row.1,
                        subtitle: row.2,
                        entity: entity(for: row.3),
                        open: { onOpen(row.3) },
                        askAI: { entity, prompt in onAskAI(entity, prompt) },
                        openInGraph: onOpenInGraph
                    )
                    .accessibilityLabel("\(title): \(row.1)")
                }
            }
        }
    }
}


// MARK: - Search result row

/// A result plus its actions. Actions appear on hover/focus so the list stays calm when simply
/// scanning, and every one of them operates on the resolved entity rather than on the row's text.
private struct SearchResultRow: View {
    let title: String
    let subtitle: String
    let entity: EntityReference?
    let open: () -> Void
    let askAI: (EntityReference, String) -> Void
    let openInGraph: (EntityReference) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.Font.body).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(DS.Font.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let entity, isHovering {
                Button { askAI(entity, prompt(for: entity)) } label: {
                    Image(systemName: "sparkles")
                }
                .help("Ask AI about this").accessibilityLabel("Ask AI about \(title)")

                Button { openInGraph(entity) } label: {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                }
                .help("Open in graph").accessibilityLabel("Open \(title) in graph")
            }
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
    }

    /// Same phrasing the inspector seeds, so the two entry points behave identically.
    private func prompt(for entity: EntityReference) -> String {
        switch entity.kind {
        case .decision: return "Why did we decide: \(title)?"
        case .workItem: return "What is the current state of \(title)?"
        case .project: return "What is happening in \(title)?"
        case .person: return "What has \(title) been involved in?"
        case .conversation: return "What was discussed in \(title)?"
        }
    }
}
