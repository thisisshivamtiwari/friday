import Foundation

// MARK: - Project Event
/// An append-only entry in a project's timeline - "what happened, when, and what evidence
/// supports it". `Project`/`ProjectItem`/`Decision`/`Meeting` hold CURRENT state;
/// `ProjectEvent` holds HISTORY. Nothing here is ever mutated after creation - a status change
/// or a decision superseding another creates a NEW event, never edits an old one, matching the
/// same "never overwrite history" principle `Decision` supersession follows.
///
/// "Is this still active/current" is deliberately NOT duplicated onto this type - that's
/// always resolved by reading the CURRENT state of whatever `relatedItemID` points at, so
/// there's exactly one place that fact can live.
struct ProjectEvent: Identifiable, Equatable {
    enum EventType: String, Equatable, CaseIterable {
        case itemCreated
        case statusChanged
        case decisionMade
        case decisionSuperseded
        case meetingOccurred
        /// A ChatSession was linked to this project for the first time - `relatedItemID` is
        /// the sessionID (not a ProjectItem/Decision/Meeting id) for these two event types.
        case sessionAssigned
        /// A ChatSession's project link changed - emitted on BOTH the old and new project.
        case sessionReassigned
    }

    let id: UUID
    let projectID: UUID
    /// What this event is about - a `ProjectItem`/`Decision`/`Meeting` id for most event
    /// types, or a ChatSession id for `.sessionAssigned`/`.sessionReassigned` (see EventType's
    /// doc comment). Always a plain UUID, resolved by the reader, never a Core Data
    /// relationship.
    let relatedItemID: UUID
    var eventType: EventType
    var description: String
    let occurredAt: Date
    /// Optional - not every event has message-level conversational evidence (e.g. a
    /// reassignment performed via a UI action rather than extracted from conversation).
    var sourceSessionID: UUID?
    var sourceMessageIDs: [UUID]

    init(
        id: UUID = UUID(),
        projectID: UUID,
        relatedItemID: UUID,
        eventType: EventType,
        description: String,
        occurredAt: Date = Date(),
        sourceSessionID: UUID? = nil,
        sourceMessageIDs: [UUID] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.relatedItemID = relatedItemID
        self.eventType = eventType
        self.description = description
        self.occurredAt = occurredAt
        self.sourceSessionID = sourceSessionID
        self.sourceMessageIDs = sourceMessageIDs
    }
}
