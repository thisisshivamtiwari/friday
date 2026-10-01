import Foundation

// MARK: - Decision
/// A project decision - kept as its own type rather than folded into `ProjectItem`, since its
/// shape (multiple people who made it, a stated reason, a supersession chain) is meaningfully
/// richer than what any `ProjectItem` kind needs, and you explicitly flagged decisions as
/// extremely important to preserve correctly.
///
/// Supersession mirrors `MemoryEdge`'s contradiction handling exactly: when a decision
/// changes, the OLD row is never mutated or deleted - it's marked `.superseded` with
/// `supersededBy` set, and a NEW `Decision` row is created with `supersedes` pointing back.
/// History is never overwritten.
struct Decision: Identifiable, Equatable {
    enum Status: String, Equatable, CaseIterable {
        case active
        case superseded
    }

    let id: UUID
    let projectID: UUID
    var statement: String
    /// Free-text context (e.g. "XYZ algorithm") - a lightweight alternative to
    /// `relatedItemID` for when the decision's context isn't itself a tracked `ProjectItem`.
    var context: String?
    /// The `ProjectItem` (typically a `.component`) this decision concerns, if any.
    var relatedItemID: UUID?
    /// `MemoryEntity` people who made this decision - plain UUIDs, no Core Data relationship
    /// to MemoryStore. Can be more than one (e.g. "Professor + Shivam").
    var madeBy: [UUID]
    var reason: String?
    var status: Status
    /// Set on the OLD decision when superseded.
    var supersedes: UUID?
    /// Set on the NEW decision, pointing back at what it replaced.
    var supersededBy: UUID?
    let sourceSessionID: UUID
    var sourceMessageIDs: [UUID]
    let decidedAt: Date

    init(
        id: UUID = UUID(),
        projectID: UUID,
        statement: String,
        context: String? = nil,
        relatedItemID: UUID? = nil,
        madeBy: [UUID] = [],
        reason: String? = nil,
        status: Status = .active,
        supersedes: UUID? = nil,
        supersededBy: UUID? = nil,
        sourceSessionID: UUID,
        sourceMessageIDs: [UUID] = [],
        decidedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.statement = statement
        self.context = context
        self.relatedItemID = relatedItemID
        self.madeBy = madeBy
        self.reason = reason
        self.status = status
        self.supersedes = supersedes
        self.supersededBy = supersededBy
        self.sourceSessionID = sourceSessionID
        self.sourceMessageIDs = sourceMessageIDs
        self.decidedAt = decidedAt
    }
}
