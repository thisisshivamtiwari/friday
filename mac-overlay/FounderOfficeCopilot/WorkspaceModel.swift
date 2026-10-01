import SwiftUI
import Combine

// MARK: - Workspace Model
/// The read model the main window is built on. It sits ON TOP of the existing, validated
/// managers (`ProjectManager`, `MemoryManager`, `ChatSessionManager`) and adds no persistence,
/// no retrieval and no AI of its own - it derives the few cross-cutting views the UI needs
/// (health, open work, recent activity, unified search) that no single manager owns.
///
/// WHY THIS EXISTS rather than screens reading managers directly: "open work", "needs
/// attention" and "recently changed" must mean the SAME thing on Home, in a project header and
/// in search. Deriving them once here is what keeps those numbers agreeing with each other.
@MainActor
final class WorkspaceModel: ObservableObject {
    let projects: ProjectManager
    let memory: MemoryManager
    let sessions: ChatSessionManager

    /// Bumped whenever an underlying manager publishes a change, so views recompute derived
    /// values. The managers are the source of truth; this is only a change signal.
    @Published fileprivate(set) var revision = 0

    private var cancellables: Set<AnyCancellable> = []

    init(projects: ProjectManager, memory: MemoryManager, sessions: ChatSessionManager) {
        self.projects = projects
        self.memory = memory
        self.sessions = sessions

        // Managers are `ObservableObject`s that mutate in memory and mirror to disk. Forwarding
        // their change notifications keeps the UI live without polling and without this type
        // holding a second copy of anything.
        for publisher in [projects.objectWillChange, memory.objectWillChange, sessions.objectWillChange] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.revision &+= 1 }
                .store(in: &cancellables)
        }
    }

    // MARK: Projects

    var activeProjects: [Project] {
        projects.projects
            .filter { $0.status == .active }
            .sorted { lastActivity(for: $0.id) > lastActivity(for: $1.id) }
    }

    var allProjectsByActivity: [Project] {
        projects.projects.sorted { lastActivity(for: $0.id) > lastActivity(for: $1.id) }
    }

    func project(_ id: UUID) -> Project? { projects.project(id: id) }

    func items(in projectID: UUID) -> [ProjectItem] {
        projects.items(forProject: projectID).sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    func decisions(in projectID: UUID) -> [Decision] {
        projects.decisions(forProject: projectID).sorted { $0.decidedAt > $1.decidedAt }
    }

    func openItems(in projectID: UUID) -> [ProjectItem] {
        items(in: projectID).filter { DS.isOpen($0.status) }
    }

    func blockedItems(in projectID: UUID) -> [ProjectItem] {
        items(in: projectID).filter { $0.status == .blocked }
    }

    /// The most recent moment anything in the project changed. Used for ordering everywhere, so
    /// "most recently active" means one thing across the whole app.
    func lastActivity(for projectID: UUID) -> Date {
        var latest = projects.project(id: projectID)?.updatedAt ?? .distantPast
        for item in projects.items(forProject: projectID) { latest = max(latest, item.lastUpdatedAt) }
        for decision in projects.decisions(forProject: projectID) { latest = max(latest, decision.decidedAt) }
        for event in projects.events(forProject: projectID) { latest = max(latest, event.occurredAt) }
        return latest
    }

    // MARK: Cross-project views

    var allOpenWork: [ProjectItem] {
        projects.items.filter { DS.isOpen($0.status) }.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    var blockedWork: [ProjectItem] {
        projects.items.filter { $0.status == .blocked }.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    var recentlyCompleted: [ProjectItem] {
        projects.items
            .filter { $0.status == .completed || $0.status == .achieved || $0.status == .resolved }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    var allDecisions: [Decision] {
        projects.decisions.sorted { $0.decidedAt > $1.decidedAt }
    }

    var recentSessions: [ChatSession] {
        sessions.sessions
            .filter { !$0.isArchived }
            .sorted { ($0.lastMessageAt ?? $0.updatedAt) > ($1.lastMessageAt ?? $1.updatedAt) }
    }

    var people: [MemoryEntity] {
        memory.entities.filter { $0.kind == .person }.sorted { $0.name < $1.name }
    }

    func personName(_ id: UUID) -> String? { memory.entities.first { $0.id == id }?.name }
    func projectName(_ id: UUID?) -> String? { id.flatMap { projects.project(id: $0)?.name } }
    func item(_ id: UUID?) -> ProjectItem? { id.flatMap { projects.projectItem(id: $0) } }

    /// Decisions that concern a given work item - the reverse of `Decision.relatedItemID`, which
    /// only points one way. Read directly from the persisted field: no inference.
    func decisions(referencing itemID: UUID) -> [Decision] {
        projects.decisions.filter { $0.relatedItemID == itemID }.sorted { $0.decidedAt > $1.decidedAt }
    }

    func sessionTitle(_ id: UUID?) -> String? {
        id.flatMap { sid in sessions.sessions.first { $0.id == sid }?.title }
    }

    /// A project's timeline, newest first: real `ProjectEvent` rows, never synthesised.
    func timeline(for projectID: UUID) -> [ProjectEvent] {
        projects.events(forProject: projectID).sorted { $0.occurredAt > $1.occurredAt }
    }

    var isEmptyWorkspace: Bool { projects.projects.isEmpty && sessions.sessions.isEmpty }

    /// True when the user has been talking but nothing has been extracted, because no project
    /// exists to extract INTO. This is not a cosmetic state: `ExtractionCoordinator` refuses to
    /// create a `ProjectItem` or `Decision` without an active project, and all three
    /// `ProjectResolution` tiers match against projects that already exist - so with zero
    /// projects the workspace can never populate itself, however much is said. Surfacing it is
    /// what turns a mysteriously empty dashboard into an obvious next step.
    var needsFirstProject: Bool { projects.projects.isEmpty && !sessions.sessions.isEmpty }

    // MARK: Creating a project

    /// Creates a project and, when given a session, links it so extraction has somewhere to put
    /// what it hears. Explicit by design - nothing infers a project from conversation, because a
    /// wrongly-invented project would silently mis-file everything that followed.
    @discardableResult
    func createProject(named name: String, linking sessionID: UUID? = nil) -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = projects.createProject(Project(name: trimmed))
        if let sessionID { projects.assignSession(sessionID, to: project.id) }
        revision &+= 1
        return project
    }

    // MARK: Unified search

    enum SearchResult: Identifiable {
        case project(Project)
        case item(ProjectItem)
        case decision(Decision)
        case person(MemoryEntity)
        case session(ChatSession)

        var id: String {
            switch self {
            case .project(let p): return "project-\(p.id)"
            case .item(let i): return "item-\(i.id)"
            case .decision(let d): return "decision-\(d.id)"
            case .person(let p): return "person-\(p.id)"
            case .session(let s): return "session-\(s.id)"
            }
        }
    }

    /// Case-insensitive substring search across every entity the workspace holds. Deliberately
    /// simple and synchronous: it runs over already-in-memory arrays, so at realistic workspace
    /// sizes it completes far inside a keystroke and needs no index, debounce or background
    /// queue. If that stops being true, this is the one place to change.
    func search(_ query: String, limitPerGroup: Int = 8) -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        func matches(_ haystack: String?) -> Bool { haystack?.lowercased().contains(needle) ?? false }

        var results: [SearchResult] = []
        results += projects.projects.filter { matches($0.name) }.prefix(limitPerGroup).map(SearchResult.project)
        results += projects.items.filter { matches($0.name) || matches($0.description) }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }.prefix(limitPerGroup).map(SearchResult.item)
        results += projects.decisions.filter { matches($0.statement) || matches($0.context) || matches($0.reason) }
            .sorted { $0.decidedAt > $1.decidedAt }.prefix(limitPerGroup).map(SearchResult.decision)
        results += people.filter { matches($0.name) }.prefix(limitPerGroup).map(SearchResult.person)
        results += sessions.sessions.filter { session in
            matches(session.title) || session.messages.contains { matches($0.text) }
        }
        .sorted { ($0.lastMessageAt ?? $0.updatedAt) > ($1.lastMessageAt ?? $1.updatedAt) }
        .prefix(limitPerGroup).map(SearchResult.session)
        return results
    }
}
