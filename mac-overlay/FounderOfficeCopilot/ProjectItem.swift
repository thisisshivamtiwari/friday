import Foundation

// MARK: - Project Item
/// A single node of project state that shares a common shape - name, kind, status,
/// description, optional evidence. Deliberately ONE type covering nine kinds (task, objective,
/// research question, component, requirement, artifact, milestone, open question, risk,
/// experiment, result) rather than nine separate persistent types - the same collapsing move
/// Phase 3 made for `MemoryEntity.Kind` (Person/Organization/Project/... -> one type with a
/// `kind` tag). See the Phase 3.2 design notes for the full reasoning, including why `Task`
/// specifically was folded in here too (its lifecycle is exactly the kind of state
/// progression `status` already needs to express for milestones/open questions/etc.) and why
/// `Decision` was deliberately NOT folded in (its shape - multiple "made by" people, a stated
/// reason, a supersession chain - is meaningfully richer than what any ProjectItem kind needs).
struct ProjectItem: Identifiable, Equatable {
    enum Kind: String, Equatable, CaseIterable {
        case task
        case objective
        case researchQuestion
        case component
        case requirement
        case artifact
        case milestone
        case openQuestion
        case risk
        case experiment
        case result
    }

    /// A union broad enough to cover every kind's lifecycle - which subset of these actually
    /// applies to a given kind is a later phase's extraction/UI concern, not something this
    /// type enforces. E.g. `.task` items cycle through
    /// proposed/planned/inProgress/blocked/completed/abandoned; `.openQuestion` items use
    /// active/resolved-shaped values; `.milestone` items use proposed/active/achieved.
    enum Status: String, Equatable, CaseIterable {
        case proposed
        case planned
        case active
        case inProgress
        case blocked
        case completed
        case achieved
        case resolved
        case abandoned
    }

    let id: UUID
    let projectID: UUID
    var kind: Kind
    var name: String
    var description: String?
    var status: Status
    /// E.g. a `.result` item pointing back at the `.experiment` item it belongs to. Optional,
    /// meaningful only for some kinds.
    var relatedItemID: UUID?
    /// A `MemoryEntity` person - meaningful mainly for `.task` (who owns it), left nil for
    /// most other kinds. Plain UUID, no Core Data relationship to MemoryStore.
    var assignedTo: UUID?
    let sourceSessionID: UUID
    var sourceMessageIDs: [UUID]
    let createdAt: Date
    var lastUpdatedAt: Date
    var confidence: Float
    var isExplicit: Bool

    init(
        id: UUID = UUID(),
        projectID: UUID,
        kind: Kind,
        name: String,
        description: String? = nil,
        status: Status = .proposed,
        relatedItemID: UUID? = nil,
        assignedTo: UUID? = nil,
        sourceSessionID: UUID,
        sourceMessageIDs: [UUID] = [],
        createdAt: Date = Date(),
        lastUpdatedAt: Date = Date(),
        confidence: Float = 0.5,
        isExplicit: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.name = name
        self.description = description
        self.status = status
        self.relatedItemID = relatedItemID
        self.assignedTo = assignedTo
        self.sourceSessionID = sourceSessionID
        self.sourceMessageIDs = sourceMessageIDs
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.confidence = confidence
        self.isExplicit = isExplicit
    }
}
