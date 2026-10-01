import Foundation

// MARK: - Memory Edge
/// An edge in Friday's memory graph - a single piece of persistent, evidenced knowledge
/// connecting a subject `MemoryEntity` to either another `MemoryEntity` or a literal value,
/// via a named predicate ("prefers", "studies-at", "builds", "goal-is", ...). This IS the
/// unit of "memory" - there is no separate Memory type sitting between two entities; a memory
/// is a relationship, matching how the approved graph example (Shivam → studies → UOB) shows
/// relationships as edges directly rather than as a third node type.
struct MemoryEdge: Identifiable, Equatable {
    enum Category: String, Equatable, CaseIterable {
        /// Stable statements about the user themselves (name, role) - distinct from
        /// `.preference`/`.goal` since identity facts are typically the most permanent and
        /// most broadly relevant category, and later phases' relevance/pinning logic is
        /// expected to treat them specially.
        case identity
        case preference
        case goal
        case fact
        case relationship
        case project
        case contact
        case other
    }

    /// Deliberately only four stored cases, not five - "stale" is a COMPUTED property
    /// (`isStale(now:)` below), not a stored status. Staleness is purely a function of how
    /// long it's been since `lastConfirmedAt`, so computing it live keeps it always accurate
    /// with no background sweep/maintenance job needed to transition it, and it layers
    /// cleanly on top of `.active` rather than needing to be reasoned about as a fifth
    /// mutually-exclusive state.
    enum Status: String, Equatable, CaseIterable {
        case active
        /// Contradicted/replaced by a newer edge - see `supersededBy`. The old edge is kept,
        /// never deleted, so history is preserved.
        case superseded
        /// Explicitly retracted by the user as simply wrong, with no replacement edge -
        /// distinct from `.superseded`, which implies a replacement exists.
        case invalidated
        /// Soft user-requested removal - excluded from graph/relevance by later phases, but
        /// the row itself is not deleted (see MemoryManager.forgetEdge vs.
        /// permanentlyDeleteEdge).
        case forgotten
    }

    let id: UUID
    let subjectEntityID: UUID
    var predicate: String
    var objectEntityID: UUID?
    /// Used when there's no natural target entity - e.g. "target ship date is October"
    /// doesn't need an Entity node, just a value attached to the edge.
    var literalValue: String?
    var category: Category
    /// 0.0...1.0. Not clamped by this type - assigning/adjusting confidence is a business
    /// rule that belongs to whatever creates/corroborates an edge (a later phase), not to
    /// this plain value type.
    var confidence: Float
    var status: Status
    let sourceSessionID: UUID
    /// Every message id that has ever corroborated this edge - appended to, never replaced,
    /// on each independent corroboration.
    var sourceMessageIDs: [UUID]
    let firstObservedAt: Date
    var lastConfirmedAt: Date
    var confirmationCount: Int
    /// Set on the OLD edge when it's superseded by a newer one.
    var supersedes: UUID?
    /// Set on the NEW edge, pointing back at what it replaced.
    var supersededBy: UUID?
    /// True if the user directly asked Friday to remember this ("remember that...") rather
    /// than it being inferred from a declarative statement.
    var isExplicit: Bool
    /// User-marked as always relevant, regardless of topic match - later phases' relevance
    /// engine includes pinned edges unconditionally.
    var isPinned: Bool

    /// The approved V1 default: a single fixed threshold rather than per-category tuning.
    /// Per-category thresholds are a reasonable later refinement, not a V1 requirement.
    static let staleThreshold: TimeInterval = 60 * 60 * 24 * 90 // 90 days

    /// An `.active` edge that hasn't been reconfirmed within `staleThreshold` is stale - for
    /// relevance-scoring/visual purposes only. Staleness is NOT destructive: a stale edge is
    /// still fully present, editable, and can become fresh again simply by being reconfirmed
    /// (which updates `lastConfirmedAt`). Only `.active` edges can be stale -
    /// `.superseded`/`.invalidated`/`.forgotten` are already excluded from relevance/graph
    /// consideration for other reasons, so staleness doesn't apply to them.
    func isStale(now: Date = Date()) -> Bool {
        status == .active && now.timeIntervalSince(lastConfirmedAt) > Self.staleThreshold
    }

    init(
        id: UUID = UUID(),
        subjectEntityID: UUID,
        predicate: String,
        objectEntityID: UUID? = nil,
        literalValue: String? = nil,
        category: Category,
        confidence: Float,
        status: Status = .active,
        sourceSessionID: UUID,
        sourceMessageIDs: [UUID] = [],
        firstObservedAt: Date = Date(),
        lastConfirmedAt: Date = Date(),
        confirmationCount: Int = 1,
        supersedes: UUID? = nil,
        supersededBy: UUID? = nil,
        isExplicit: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.subjectEntityID = subjectEntityID
        self.predicate = predicate
        self.objectEntityID = objectEntityID
        self.literalValue = literalValue
        self.category = category
        self.confidence = confidence
        self.status = status
        self.sourceSessionID = sourceSessionID
        self.sourceMessageIDs = sourceMessageIDs
        self.firstObservedAt = firstObservedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.confirmationCount = confirmationCount
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.isExplicit = isExplicit
        self.isPinned = isPinned
    }
}
