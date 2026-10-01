import Foundation

// MARK: - Episode Summary
/// "What happened during this meeting/session" - a PROJECTION built on demand from already
/// -persisted data, never itself persisted (no `EpisodeStore`, no new Core Data entity). Built
/// by reusing exactly what Phase 3.1-3.3 already established: `Meeting` when one exists,
/// `ChatSession` as a fallback when it doesn't, plus whatever `ProjectItem`/`Decision`/
/// `ProjectEvent` rows carry that session's id as their `sourceSessionID`.
///
/// This directly answers the Phase 3.4 audit question "can episodic memory be represented
/// using existing Meeting/ProjectEvent/ChatSession data rather than creating another store" -
/// yes, and this type is exactly that representation, not a new persistence model.
struct EpisodeSummary: Equatable {
    let sessionID: UUID
    /// Nil when no `Meeting` record exists yet for this session - a real, currently-true gap
    /// in the write path (nothing in Phase 3.1-3.3 populates `Meeting` automatically; it's a
    /// write-side capability that doesn't exist yet, not a bug in this read-side type). When
    /// nil, `title`/`occurredAt` fall back to the underlying `ChatSession`'s own fields.
    let meetingID: UUID?
    let title: String
    let occurredAt: Date
    let participantEntityIDs: [UUID]
    let decisions: [Decision]
    let projectItems: [ProjectItem]
    let projectEvents: [ProjectEvent]
    /// From `Meeting.checkpointSummary` when a Meeting exists - nil otherwise. Meeting
    /// checkpoint generation is also a write-side capability that doesn't exist yet (Phase 3.3
    /// explicitly excluded it) - this field being nil for most sessions today is expected, not
    /// a defect in this projection.
    let checkpointSummary: String?
    /// A representative set of message ids drawn from this episode's constituent decisions/
    /// items/events - NOT the full transcript. Historical raw evidence (verbatim text) is
    /// resolved lazily, later, only for whichever of these ids retrieval actually decides are
    /// worth surfacing - never eagerly loaded here.
    let sourceMessageIDs: [UUID]

    /// Builds an EpisodeSummary for `sessionID` from already-loaded manager state only - no
    /// fresh Core Data queries, no full-history scan. `projectItems`/`decisions`/`projectEvents`
    /// are found by filtering `ProjectManager`'s already-in-memory arrays for a matching
    /// `sourceSessionID`, exactly the same bounded, in-memory approach already established for
    /// dedup matching in Phase 3.3.
    ///
    /// Returns nil only if `sessionID` doesn't resolve to any known `ChatSession` at all (a
    /// dangling/unknown session id) - an episode with genuinely nothing else attached (no
    /// Meeting, no project rows) still returns a minimal EpisodeSummary built from the
    /// ChatSession alone, since "nothing structured was extracted from this conversation yet"
    /// is a valid, meaningful answer, not an error.
    static func build(
        forSession sessionID: UUID,
        chatSessionManager: ChatSessionManager,
        projectManager: ProjectManager
    ) -> EpisodeSummary? {
        guard let session = chatSessionManager.sessions.first(where: { $0.id == sessionID }) else {
            return nil
        }

        let meeting = projectManager.meetings.first { $0.sessionIDs.contains(sessionID) }

        let decisions = projectManager.decisions.filter { $0.sourceSessionID == sessionID }
        let projectItems = projectManager.items.filter { $0.sourceSessionID == sessionID }
        let projectEvents = projectManager.events.filter { $0.sourceSessionID == sessionID }

        var messageIDs = decisions.flatMap(\.sourceMessageIDs)
        messageIDs += projectItems.flatMap(\.sourceMessageIDs)
        messageIDs += projectEvents.flatMap(\.sourceMessageIDs)

        return EpisodeSummary(
            sessionID: sessionID,
            meetingID: meeting?.id,
            title: meeting?.title ?? session.title,
            occurredAt: meeting?.occurredAt ?? (session.lastMessageAt ?? session.createdAt),
            participantEntityIDs: meeting?.participantEntityIDs ?? [],
            decisions: decisions,
            projectItems: projectItems,
            projectEvents: projectEvents,
            checkpointSummary: meeting?.checkpointSummary,
            sourceMessageIDs: Array(Set(messageIDs))
        )
    }
}
