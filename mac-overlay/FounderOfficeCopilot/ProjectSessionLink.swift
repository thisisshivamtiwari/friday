import Foundation

// MARK: - Project Session Link
/// The SINGLE SOURCE OF TRUTH for ChatSession <-> Project association - see the Phase 3.2
/// follow-up design notes. One row per linked session (`sessionID` is treated as unique by
/// ProjectManager's business logic, not a Core Data constraint - see ProjectManager.
/// assignSession(_:to:)), `projectID` is the one MUTABLE field (what reassignment changes).
///
/// Deliberately has NO supersession chain the way `Decision` does - a session's project
/// association is an organizational/foldering choice, not an evolving factual claim, so it
/// doesn't need "never overwrite, preserve every version" treatment. `lastReassignedAt` gives
/// basic auditability without full history; `ProjectManager.assignSession(_:to:)` additionally
/// emits `ProjectEvent`s on both the old and new project for the timeline, which is where the
/// real history of "this session moved" actually lives.
///
/// There is deliberately no `activeProjectID`/`currentProjectID`/`selectedProjectID` anywhere
/// in this codebase - "which project is active" is always DERIVED by looking up a specific
/// session's link (`ProjectManager.project(forSession:)`), never stored as its own field. See
/// ProjectManager's doc comment for why this is what actually guarantees recordingSessionID/
/// viewingSessionID/project-association stay independent, not just careful bookkeeping.
struct ProjectSessionLink: Identifiable, Equatable {
    let id: UUID
    /// Plain UUID reference into ChatSessionStore's data - NEVER a Core Data relationship.
    let sessionID: UUID
    var projectID: UUID
    let assignedAt: Date
    /// Nil until the first reassignment.
    var lastReassignedAt: Date?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        projectID: UUID,
        assignedAt: Date = Date(),
        lastReassignedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectID = projectID
        self.assignedAt = assignedAt
        self.lastReassignedAt = lastReassignedAt
    }
}
