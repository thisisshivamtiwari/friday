import Foundation
import Combine

// MARK: - Project Manager
/// Owns Friday's project state (Project, ProjectItem, Decision, Meeting, ProjectEvent,
/// ProjectSessionLink) - the persistent, structured-work counterpart to ChatSessionManager's
/// conversational state and MemoryManager's entity/edge graph. Same shape as both: loads
/// everything into memory once at init, mutates in-memory synchronously, mirrors to
/// ProjectStore fire-and-forget.
///
/// This phase (Phase 3.2, Project Foundation) is foundation only: load/hold/mutate/persist/
/// read, plus the session<->project association primitives. No extraction, no relevance
/// retrieval, no response integration, no UI, no automatic project detection, no meeting
/// checkpoint generation - those are later phases, and none of them are wired up yet.
///
/// Deliberately has NO reference to GeminiLiveClient, GeminiResponseGenerator,
/// AudioCaptureManager, AudioMixer, or SystemAudioCaptureManager - same purity guarantee
/// ChatSessionManager/MemoryManager hold.
///
/// CRITICAL: there is no `activeProjectID`/`currentProjectID`/`selectedProjectID` stored
/// ANYWHERE on this class (or anywhere else in the codebase). "Which project is active" is
/// always a DERIVED lookup - `project(forSession:)` - never a piece of state that could get
/// out of sync with `recordingSessionID`/`viewingSessionID`. This is what actually guarantees
/// the three stay independent: there is only one mutable fact in this whole layer
/// (`ProjectSessionLink.projectID`), and everything else is a question asked of it.
final class ProjectManager: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var items: [ProjectItem] = []
    @Published private(set) var decisions: [Decision] = []
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var events: [ProjectEvent] = []
    @Published private(set) var sessionLinks: [ProjectSessionLink] = []

    private let store: ProjectStore

    /// `store` defaults to a real on-disk-backed instance; tests inject
    /// `ProjectStore(inMemory: true)` so nothing ever touches real saved project data - same
    /// seam pattern as ChatSessionManager's/MemoryManager's `store:` parameter.
    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        projects = store.loadAllProjects()
        items = store.loadAllProjectItems()
        decisions = store.loadAllDecisions()
        meetings = store.loadAllMeetings()
        events = store.loadAllProjectEvents()
        sessionLinks = store.loadAllProjectSessionLinks()
    }

    // MARK: Projects

    @discardableResult
    func createProject(_ project: Project) -> Project {
        projects.append(project)
        store.createProject(project)
        return project
    }

    /// No-op if `project.id` isn't already known in-memory - mirrors ProjectStore.updateProject's
    /// "must already exist" semantics.
    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        store.updateProject(project)
    }

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// Permanent, irreversible removal of the Project row AND its ProjectSessionLinks -
    /// deliberately does NOT touch ChatSessions (no reference to ChatSessionManager/
    /// ChatSessionStore exists here to do so, and none is needed - see this class's own doc
    /// comment) and deliberately does NOT cascade-delete this project's own ProjectItems/
    /// Decisions/Meetings/ProjectEvents, which are left in place (pointing at a projectID
    /// that no longer resolves) rather than destroyed - the same "let dangling references
    /// degrade gracefully, never destroy derived state" principle already used everywhere
    /// else in this design, rather than assuming deletion should cascade further than what
    /// was actually specified.
    func permanentlyDeleteProject(id: UUID) {
        projects.removeAll { $0.id == id }
        sessionLinks.removeAll { $0.projectID == id }
        store.deleteProject(id: id)
        store.deleteProjectSessionLinks(forProject: id)
    }

    // MARK: Project Items

    @discardableResult
    func createProjectItem(_ item: ProjectItem) -> ProjectItem {
        items.append(item)
        store.createProjectItem(item)
        return item
    }

    func updateProjectItem(_ item: ProjectItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        store.updateProjectItem(item)
    }

    func projectItem(id: UUID) -> ProjectItem? {
        items.first { $0.id == id }
    }

    func items(forProject projectID: UUID) -> [ProjectItem] {
        items.filter { $0.projectID == projectID }
    }

    // MARK: Decisions

    @discardableResult
    func createDecision(_ decision: Decision) -> Decision {
        decisions.append(decision)
        store.createDecision(decision)
        return decision
    }

    func updateDecision(_ decision: Decision) {
        guard let index = decisions.firstIndex(where: { $0.id == decision.id }) else { return }
        decisions[index] = decision
        store.updateDecision(decision)
    }

    func decision(id: UUID) -> Decision? {
        decisions.first { $0.id == id }
    }

    func decisions(forProject projectID: UUID) -> [Decision] {
        decisions.filter { $0.projectID == projectID }
    }

    /// The mechanically-correct orchestration for "this decision changed": marks the OLD
    /// decision `.superseded` with `supersededBy` set, creates the NEW decision with
    /// `supersedes` pointing back, and logs a `.decisionSuperseded` ProjectEvent - never
    /// mutates or deletes the old row. Deciding WHEN to call this (detecting that a new
    /// statement actually contradicts an existing decision) is a later extraction phase's
    /// job, not this foundation's - this only guarantees the mechanics are correct once that
    /// decision has been made, the same "foundation provides mechanically correct primitives,
    /// extraction decides when to invoke them" split already used for
    /// MemoryManager.forgetEdge/permanentlyDeleteEdge in Phase 3.1.
    @discardableResult
    func supersedeDecision(_ oldDecisionID: UUID, with newDecision: Decision) -> Decision? {
        guard let oldIndex = decisions.firstIndex(where: { $0.id == oldDecisionID }) else { return nil }

        var old = decisions[oldIndex]
        old.status = .superseded
        old.supersededBy = newDecision.id
        decisions[oldIndex] = old
        store.updateDecision(old)

        var new = newDecision
        new.supersedes = oldDecisionID
        decisions.append(new)
        store.createDecision(new)

        createProjectEvent(ProjectEvent(
            projectID: new.projectID,
            relatedItemID: new.id,
            eventType: .decisionSuperseded,
            description: "Decision superseded: \(old.statement)",
            sourceSessionID: new.sourceSessionID,
            sourceMessageIDs: new.sourceMessageIDs
        ))

        return new
    }

    // MARK: Meetings

    @discardableResult
    func createMeeting(_ meeting: Meeting) -> Meeting {
        meetings.append(meeting)
        store.createMeeting(meeting)
        return meeting
    }

    func updateMeeting(_ meeting: Meeting) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
        store.updateMeeting(meeting)
    }

    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func meetings(forProject projectID: UUID) -> [Meeting] {
        meetings.filter { $0.projectID == projectID }
    }

    // MARK: Project Events (append-only - preserves project-state history)

    /// No update/delete API is exposed for ProjectEvent, by design - it's an append-only log.
    /// A correction is a NEW event, never an edit to an old one.
    @discardableResult
    func createProjectEvent(_ event: ProjectEvent) -> ProjectEvent {
        events.append(event)
        store.createProjectEvent(event)
        return event
    }

    func events(forProject projectID: UUID) -> [ProjectEvent] {
        events.filter { $0.projectID == projectID }
    }

    // MARK: Session <-> Project association
    // ProjectSessionLink is the SINGLE SOURCE OF TRUTH for this - see its own doc comment.

    /// Creates or updates the ONE ProjectSessionLink for `sessionID` - if no link exists yet,
    /// creates one and logs a single `.sessionAssigned` event on `projectID`. If a link
    /// already exists (reassignment), updates it IN PLACE (never creates a duplicate row),
    /// sets `lastReassignedAt`, and logs a `.sessionReassigned` event on BOTH the old and new
    /// project. Reassigning to the SAME project a session is already linked to is a no-op -
    /// no duplicate event, no `lastReassignedAt` change.
    ///
    /// Does not touch `recordingSessionID`/`viewingSessionID` in any way - it doesn't even
    /// know they exist, since this class has no reference to ChatSessionManager at all.
    @discardableResult
    func assignSession(_ sessionID: UUID, to projectID: UUID) -> ProjectSessionLink {
        if let index = sessionLinks.firstIndex(where: { $0.sessionID == sessionID }) {
            let existing = sessionLinks[index]
            guard existing.projectID != projectID else { return existing }

            let oldProjectID = existing.projectID
            var updated = existing
            updated.projectID = projectID
            updated.lastReassignedAt = Date()
            sessionLinks[index] = updated
            store.updateProjectSessionLink(updated)

            createProjectEvent(ProjectEvent(
                projectID: oldProjectID,
                relatedItemID: sessionID,
                eventType: .sessionReassigned,
                description: "Session reassigned to a different project"
            ))
            createProjectEvent(ProjectEvent(
                projectID: projectID,
                relatedItemID: sessionID,
                eventType: .sessionReassigned,
                description: "Session reassigned from a different project"
            ))

            return updated
        } else {
            let link = ProjectSessionLink(sessionID: sessionID, projectID: projectID)
            sessionLinks.append(link)
            store.createProjectSessionLink(link)

            createProjectEvent(ProjectEvent(
                projectID: projectID,
                relatedItemID: sessionID,
                eventType: .sessionAssigned,
                description: "Session assigned to project"
            ))

            return link
        }
    }

    /// Removes `sessionID`'s ProjectSessionLink entirely, if one exists - the counterpart to
    /// `assignSession(_:to:)`. A no-op if the session isn't currently linked to anything.
    /// Emits a `.sessionReassigned` event on the (former) project - reusing that existing
    /// EventType rather than adding a new case for "unassigned", exactly the same "closest
    /// existing vocabulary" reasoning already used elsewhere (see ExtractionCoordinator's
    /// correction handling for ProjectItem/Decision). Like `assignSession`, this has no idea
    /// `recordingSessionID`/`viewingSessionID` even exist.
    func unassignSession(_ sessionID: UUID) {
        guard let index = sessionLinks.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        let link = sessionLinks[index]
        sessionLinks.remove(at: index)
        store.deleteProjectSessionLink(id: link.id)

        createProjectEvent(ProjectEvent(
            projectID: link.projectID,
            relatedItemID: sessionID,
            eventType: .sessionReassigned,
            description: "Session unassigned from project"
        ))
    }

    /// THE canonical way to determine "what project is this session's work" - always a live
    /// lookup against `sessionLinks`, never a cached/stored "current project" value. Returns
    /// nil if the session has never been assigned. Works identically for a session currently
    /// being recorded, a session being viewed, or a long-dormant historical session - this
    /// method has no notion of "current" at all, it just answers the question for whichever
    /// sessionID it's given.
    func project(forSession sessionID: UUID) -> UUID? {
        sessionLinks.first { $0.sessionID == sessionID }?.projectID
    }

    /// The forward lookup - every session currently linked to `projectID`.
    func sessions(forProject projectID: UUID) -> [UUID] {
        sessionLinks.filter { $0.projectID == projectID }.map(\.sessionID)
    }
}
