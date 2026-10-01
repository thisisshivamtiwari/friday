import Foundation

// MARK: - Meeting
/// A physical (or call/video) meeting, kept as a first-class but deliberately minimal type -
/// it exists so a checkpoint summary and participant list have somewhere to live, and so
/// "which meeting was this decided in" is answerable. It does NOT duplicate a list of
/// decisions/tasks/questions discussed - those are found by querying `Decision`/`ProjectItem`/
/// `ProjectEvent` rows whose `sourceSessionID` falls within `sessionIDs` and whose timestamp
/// falls in range, keeping a single source of truth on each item's own provenance rather than
/// a second, driftable bookkeeping list here.
struct Meeting: Identifiable, Equatable {
    let id: UUID
    let projectID: UUID
    var title: String
    /// `MemoryEntity` people - plain UUIDs, no Core Data relationship to MemoryStore.
    var participantEntityIDs: [UUID]
    /// Which `ChatSession`(s) correspond to this meeting - could be more than one if the
    /// conversation spanned a Stop/Start cycle. Plain UUIDs, no Core Data relationship to
    /// ChatSessionStore.
    var sessionIDs: [UUID]
    let occurredAt: Date
    /// The human-readable recap - see the Phase 3.2 design notes on meeting checkpoints: this
    /// IS the checkpoint concept, not a separate persistent type. Filled by a later
    /// extraction phase, not this foundation.
    var checkpointSummary: String?

    init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String,
        participantEntityIDs: [UUID] = [],
        sessionIDs: [UUID] = [],
        occurredAt: Date = Date(),
        checkpointSummary: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.participantEntityIDs = participantEntityIDs
        self.sessionIDs = sessionIDs
        self.occurredAt = occurredAt
        self.checkpointSummary = checkpointSummary
    }
}
