import XCTest
@testable import FounderOfficeCopilotCore

/// Covers ProjectManager: in-memory state management, persistence mirroring, the session
/// <-> project association primitives (the actual point of the Phase 3.2 follow-up design),
/// decision supersession orchestration, and the structural guarantees - no stored
/// "active project" state anywhere, no forbidden audio/Gemini dependencies, and genuine
/// independence from ChatSessionManager's recordingSessionID/viewingSessionID. Every test
/// uses in-memory stores, so nothing here ever touches real saved data.
final class ProjectManagerTests: XCTestCase {
    private func makeManager(store: ProjectStore = ProjectStore(inMemory: true)) -> ProjectManager {
        ProjectManager(store: store)
    }

    /// Polls a ProjectStore's synchronous read until `predicate` is satisfied or the timeout
    /// elapses - same technique MemoryManagerTests uses to verify fire-and-forget mirroring
    /// without adding a completion parameter ProjectManager itself doesn't have.
    private func pollUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: Initial load / fresh state

    func testFreshManagerHasNoState() {
        let manager = makeManager()
        XCTAssertTrue(manager.projects.isEmpty)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(manager.decisions.isEmpty)
        XCTAssertTrue(manager.meetings.isEmpty)
        XCTAssertTrue(manager.events.isEmpty)
        XCTAssertTrue(manager.sessionLinks.isEmpty)
    }

    // MARK: Project CRUD

    func testCreateProjectAddsItToInMemoryState() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        XCTAssertEqual(manager.projects.count, 1)
        XCTAssertEqual(manager.project(id: project.id)?.name, "Trustworthy AI")
    }

    func testUpdateProjectChangesInMemoryStateInPlace() {
        let manager = makeManager()
        var project = manager.createProject(Project(name: "Trustworthy AI"))
        project.status = .completed
        manager.updateProject(project)
        XCTAssertEqual(manager.projects.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(manager.project(id: project.id)?.status, .completed)
    }

    func testCreateProjectMirrorsToTheStore() {
        let store = ProjectStore(inMemory: true)
        let manager = makeManager(store: store)
        let project = manager.createProject(Project(name: "Trustworthy AI"))

        pollUntil { store.loadAllProjects().contains { $0.id == project.id } }
        XCTAssertTrue(store.loadAllProjects().contains { $0.id == project.id })
    }

    // MARK: ProjectItem CRUD

    func testCreateProjectItemAddsItToInMemoryStateAndScopesToProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let other = manager.createProject(Project(name: "Retvens"))
        let item = manager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Implement calibration", sourceSessionID: UUID()))
        manager.createProjectItem(ProjectItem(projectID: other.id, kind: .task, name: "Unrelated task", sourceSessionID: UUID()))

        let itemsForProject = manager.items(forProject: project.id)
        XCTAssertEqual(itemsForProject.count, 1)
        XCTAssertEqual(itemsForProject.first?.id, item.id)
    }

    func testUpdateProjectItemChangesInMemoryStateInPlace() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        var item = manager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Compare methods", sourceSessionID: UUID()))
        item.status = .completed
        manager.updateProjectItem(item)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.projectItem(id: item.id)?.status, .completed)
    }

    // MARK: Decision CRUD and supersession

    func testCreateDecisionAddsItToInMemoryStateAndScopesToProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let decision = manager.createDecision(Decision(projectID: project.id, statement: "Use Bayesian calibration", sourceSessionID: UUID()))

        XCTAssertEqual(manager.decisions(forProject: project.id).map(\.id), [decision.id])
    }

    func testSupersedeDecisionMarksOldAsSupersededAndCreatesLinkedNewDecision() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let old = manager.createDecision(Decision(projectID: project.id, statement: "Use method B", sourceSessionID: UUID()))

        let new = manager.supersedeDecision(old.id, with: Decision(projectID: project.id, statement: "Use Bayesian calibration instead", sourceSessionID: UUID()))

        XCTAssertNotNil(new)
        XCTAssertEqual(manager.decision(id: old.id)?.status, .superseded)
        XCTAssertEqual(manager.decision(id: old.id)?.supersededBy, new?.id)
        XCTAssertEqual(new?.supersedes, old.id)
        XCTAssertEqual(new?.status, .active)
        XCTAssertEqual(manager.decisions(forProject: project.id).count, 2, "the old decision must never be deleted - history is preserved")
    }

    func testSupersedeDecisionLogsAProjectEvent() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let old = manager.createDecision(Decision(projectID: project.id, statement: "Use method B", sourceSessionID: UUID()))

        manager.supersedeDecision(old.id, with: Decision(projectID: project.id, statement: "Use Bayesian calibration instead", sourceSessionID: UUID()))

        XCTAssertTrue(manager.events(forProject: project.id).contains { $0.eventType == .decisionSuperseded })
    }

    func testSupersedeDecisionWithUnknownOldIDReturnsNilAndChangesNothing() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let result = manager.supersedeDecision(UUID(), with: Decision(projectID: project.id, statement: "New", sourceSessionID: UUID()))
        XCTAssertNil(result)
        XCTAssertTrue(manager.decisions.isEmpty)
    }

    // MARK: Meeting CRUD

    func testCreateMeetingAddsItToInMemoryStateAndScopesToProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let meeting = manager.createMeeting(Meeting(projectID: project.id, title: "Weekly sync"))
        XCTAssertEqual(manager.meetings(forProject: project.id).map(\.id), [meeting.id])
    }

    // MARK: ProjectEvent (append-only)

    func testCreateProjectEventAddsItToInMemoryStateAndScopesToProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let event = manager.createProjectEvent(ProjectEvent(projectID: project.id, relatedItemID: UUID(), eventType: .itemCreated, description: "Task created"))
        XCTAssertEqual(manager.events(forProject: project.id).map(\.id), [event.id])
    }

    // MARK: assignSession - forward/reverse lookup, reassignment, no duplicates

    func testAssignSessionCreatesALink() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: project.id)

        XCTAssertEqual(manager.sessionLinks.count, 1)
        XCTAssertEqual(manager.project(forSession: sessionID), project.id)
    }

    func testForwardLookupReturnsAllSessionsForAProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionA = UUID()
        let sessionB = UUID()

        manager.assignSession(sessionA, to: project.id)
        manager.assignSession(sessionB, to: project.id)

        XCTAssertEqual(Set(manager.sessions(forProject: project.id)), Set([sessionA, sessionB]))
    }

    func testReverseLookupForUnassignedSessionReturnsNil() {
        let manager = makeManager()
        XCTAssertNil(manager.project(forSession: UUID()))
    }

    func testMultipleSessionsCanBelongToOneProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessions = (0..<5).map { _ in UUID() }
        for session in sessions {
            manager.assignSession(session, to: project.id)
        }
        XCTAssertEqual(manager.sessionLinks.count, 5)
        for session in sessions {
            XCTAssertEqual(manager.project(forSession: session), project.id)
        }
    }

    func testReassigningASessionUpdatesTheExistingLinkRatherThanCreatingADuplicate() {
        let manager = makeManager()
        let projectA = manager.createProject(Project(name: "A"))
        let projectB = manager.createProject(Project(name: "B"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: projectA.id)
        manager.assignSession(sessionID, to: projectB.id)

        XCTAssertEqual(manager.sessionLinks.count, 1, "reassignment must update the existing link, never create a second one")
        XCTAssertEqual(manager.project(forSession: sessionID), projectB.id)
    }

    func testReassignmentSetsLastReassignedAt() {
        let manager = makeManager()
        let projectA = manager.createProject(Project(name: "A"))
        let projectB = manager.createProject(Project(name: "B"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: projectA.id)
        XCTAssertNil(manager.sessionLinks.first?.lastReassignedAt, "first assignment is not a reassignment")

        manager.assignSession(sessionID, to: projectB.id)
        XCTAssertNotNil(manager.sessionLinks.first?.lastReassignedAt)
    }

    func testReassignmentEmitsProjectEventsOnBothOldAndNewProject() {
        let manager = makeManager()
        let projectA = manager.createProject(Project(name: "A"))
        let projectB = manager.createProject(Project(name: "B"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: projectA.id)
        manager.assignSession(sessionID, to: projectB.id)

        XCTAssertTrue(manager.events(forProject: projectA.id).contains { $0.eventType == .sessionReassigned }, "the OLD project must get a reassignment event")
        XCTAssertTrue(manager.events(forProject: projectB.id).contains { $0.eventType == .sessionReassigned }, "the NEW project must get a reassignment event")
    }

    func testInitialAssignmentEmitsASessionAssignedEventNotReassigned() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: project.id)

        let events = manager.events(forProject: project.id)
        XCTAssertTrue(events.contains { $0.eventType == .sessionAssigned })
        XCTAssertFalse(events.contains { $0.eventType == .sessionReassigned })
    }

    func testReassigningToTheSameProjectIsANoOp() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: project.id)
        let eventCountBefore = manager.events.count
        manager.assignSession(sessionID, to: project.id)

        XCTAssertEqual(manager.sessionLinks.count, 1)
        XCTAssertEqual(manager.events.count, eventCountBefore, "reassigning to the same project must not emit a new event")
        XCTAssertNil(manager.sessionLinks.first?.lastReassignedAt, "must not count as a reassignment")
    }

    func testAssignSessionMirrorsToTheStore() {
        let store = ProjectStore(inMemory: true)
        let manager = makeManager(store: store)
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()

        manager.assignSession(sessionID, to: project.id)

        pollUntil { store.loadAllProjectSessionLinks().contains { $0.sessionID == sessionID } }
        XCTAssertTrue(store.loadAllProjectSessionLinks().contains { $0.sessionID == sessionID && $0.projectID == project.id })
    }

    // MARK: unassignSession (Phase 4.1) - the counterpart to assignSession

    func testUnassignSessionRemovesTheLink() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)

        manager.unassignSession(sessionID)

        XCTAssertTrue(manager.sessionLinks.isEmpty)
        XCTAssertNil(manager.project(forSession: sessionID))
    }

    func testUnassignSessionOnAnUnassignedSessionIsANoOp() {
        let manager = makeManager()
        let sessionID = UUID()
        manager.unassignSession(sessionID)
        XCTAssertTrue(manager.sessionLinks.isEmpty)
        XCTAssertTrue(manager.events.isEmpty, "a no-op unassign must not emit an event either")
    }

    func testUnassignSessionEmitsASessionReassignedEventOnTheFormerProject() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)

        manager.unassignSession(sessionID)

        let events = manager.events(forProject: project.id)
        XCTAssertTrue(events.contains { $0.eventType == .sessionReassigned && $0.description == "Session unassigned from project" }, "must reuse the existing .sessionReassigned case, per the approved decision - no new EventType case")
    }

    func testUnassignSessionMirrorsToTheStore() {
        let store = ProjectStore(inMemory: true)
        let manager = makeManager(store: store)
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)
        pollUntil { !store.loadAllProjectSessionLinks().isEmpty }

        manager.unassignSession(sessionID)

        pollUntil { store.loadAllProjectSessionLinks().isEmpty }
        XCTAssertTrue(store.loadAllProjectSessionLinks().isEmpty)
    }

    func testUnassignThenReassignToADifferentProjectWorksCorrectly() {
        let manager = makeManager()
        let projectA = manager.createProject(Project(name: "A"))
        let projectB = manager.createProject(Project(name: "B"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: projectA.id)

        manager.unassignSession(sessionID)
        manager.assignSession(sessionID, to: projectB.id)

        XCTAssertEqual(manager.sessionLinks.count, 1)
        XCTAssertEqual(manager.project(forSession: sessionID), projectB.id)
        XCTAssertFalse(manager.sessions(forProject: projectA.id).contains(sessionID))
    }

    // MARK: Historical session assignment

    func testHistoricalSessionCanBeAssignedExactlyLikeAnyOtherSession() {
        // ProjectManager has no notion of "recent" vs "historical" at all - assignSession just
        // takes a UUID. This documents that explicitly: an arbitrary, long-dormant sessionID
        // (simulated here simply as "a UUID nothing else in this test touches") is assigned
        // identically to any other.
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let historicalSessionID = UUID()

        manager.assignSession(historicalSessionID, to: project.id)

        XCTAssertEqual(manager.project(forSession: historicalSessionID), project.id)
    }

    // MARK: Project deletion

    func testDeletingAProjectRemovesItsSessionLinks() {
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)

        manager.permanentlyDeleteProject(id: project.id)

        XCTAssertNil(manager.project(forSession: sessionID))
        XCTAssertTrue(manager.sessionLinks.isEmpty)
    }

    func testDeletingAProjectDoesNotAffectAnotherProjectsSessionLinks() {
        let manager = makeManager()
        let projectA = manager.createProject(Project(name: "A"))
        let projectB = manager.createProject(Project(name: "B"))
        let sessionForA = UUID()
        let sessionForB = UUID()
        manager.assignSession(sessionForA, to: projectA.id)
        manager.assignSession(sessionForB, to: projectB.id)

        manager.permanentlyDeleteProject(id: projectA.id)

        XCTAssertNil(manager.project(forSession: sessionForA))
        XCTAssertEqual(manager.project(forSession: sessionForB), projectB.id, "an unrelated project's links must be untouched")
    }

    func testDeletingAProjectMirrorsLinkRemovalToTheStore() {
        let store = ProjectStore(inMemory: true)
        let manager = makeManager(store: store)
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)
        pollUntil { store.loadAllProjectSessionLinks().contains { $0.sessionID == sessionID } }

        manager.permanentlyDeleteProject(id: project.id)

        pollUntil { store.loadAllProjectSessionLinks().isEmpty }
        XCTAssertTrue(store.loadAllProjectSessionLinks().isEmpty)
        XCTAssertTrue(store.loadAllProjects().isEmpty)
    }

    // MARK: Chat deletion tolerance (dangling links)

    func testProjectManagerHasNoWayToKnowASessionWasDeletedAndToleratesItGracefully() {
        // ProjectManager has zero reference to ChatSessionManager (see the structural test
        // below), so it cannot possibly be notified when a session is deleted - a link whose
        // sessionID no longer resolves to anything real is simply returned as-is, faithfully,
        // never crashing and never behaving specially. Resolving "does this session still
        // exist" is a future UI concern that queries ChatSessionManager separately.
        let manager = makeManager()
        let project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionIDThatWillNeverExistAnywhere = UUID()

        manager.assignSession(sessionIDThatWillNeverExistAnywhere, to: project.id)

        XCTAssertEqual(manager.project(forSession: sessionIDThatWillNeverExistAnywhere), project.id)
        XCTAssertEqual(manager.sessions(forProject: project.id), [sessionIDThatWillNeverExistAnywhere])
    }

    // MARK: Archived project behavior

    func testArchivingAProjectLeavesItsSessionLinksUntouched() {
        let manager = makeManager()
        var project = manager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        manager.assignSession(sessionID, to: project.id)

        project.status = .archived
        manager.updateProject(project)

        XCTAssertEqual(manager.project(forSession: sessionID), project.id, "archiving must not unlink sessions")
        XCTAssertEqual(manager.project(id: project.id)?.status, .archived)
    }

    // MARK: recordingSessionID / viewingSessionID independence

    func testAssigningASessionToAProjectDoesNotAffectRecordingOrViewingState() {
        let chatManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let projectManager = makeManager()
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))

        chatManager.beginRecording()
        let recordingBefore = chatManager.recordingSessionID
        let viewingBefore = chatManager.viewingSessionID

        projectManager.assignSession(recordingBefore!, to: project.id)

        XCTAssertEqual(chatManager.recordingSessionID, recordingBefore, "assigning a project must not affect recording")
        XCTAssertEqual(chatManager.viewingSessionID, viewingBefore, "assigning a project must not affect viewing")
    }

    func testSwitchingViewingSessionDoesNotAffectAnyProjectSessionLink() {
        let chatManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let projectManager = makeManager()
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))

        chatManager.beginRecording()
        let recordingSessionID = chatManager.recordingSessionID!
        projectManager.assignSession(recordingSessionID, to: project.id)

        let otherSessionID = chatManager.createSession(title: "Other")
        chatManager.switchViewing(to: otherSessionID)

        XCTAssertEqual(projectManager.project(forSession: recordingSessionID), project.id, "switching viewing must not affect an existing link")
        XCTAssertNil(projectManager.project(forSession: otherSessionID), "switching viewing must not implicitly create a link for the newly-viewed session")
    }

    func testRecordingIntoASessionDoesNotImplicitlyAssignOrChangeItsProject() {
        let chatManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let projectManager = makeManager()

        chatManager.beginRecording()
        chatManager.appendHeardDelta("hello")
        chatManager.appendHeardDelta(" world")

        XCTAssertNil(projectManager.project(forSession: chatManager.recordingSessionID!), "recording activity alone must never create a project association")
    }

    // MARK: State surviving reload

    func testStateSurvivesReloadIntoAFreshManagerInstance() {
        let store = ProjectStore(inMemory: true)
        let firstManager = makeManager(store: store)
        let project = firstManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        firstManager.assignSession(sessionID, to: project.id)

        pollUntil {
            store.loadAllProjects().contains { $0.id == project.id }
                && store.loadAllProjectSessionLinks().contains { $0.sessionID == sessionID }
        }

        let reloadedManager = makeManager(store: store)

        XCTAssertEqual(reloadedManager.projects.count, 1)
        XCTAssertEqual(reloadedManager.project(forSession: sessionID), project.id)
    }

    // MARK: Structural guarantees

    /// No stored property anywhere on ProjectManager named/labeled like an "active project" -
    /// checks the property LABEL (not type, since this would be a plain `UUID?` which reveals
    /// nothing by type alone) for any of the three forbidden names. This is what actually
    /// enforces "there is no activeProjectID/currentProjectID/selectedProjectID anywhere",
    /// not just the doc comment saying so.
    func testNoActiveProjectIDStoredAnywhereOnProjectManager() {
        let forbiddenNames = ["activeProjectID", "currentProjectID", "selectedProjectID"]
        let manager = makeManager()
        let mirror = Mirror(reflecting: manager)

        for child in mirror.children {
            let label = (child.label ?? "").lowercased()
            for forbidden in forbiddenNames {
                XCTAssertFalse(label.contains(forbidden.lowercased()), "found a forbidden stored property: \(child.label ?? "?")")
            }
        }
    }

    /// Same technique as MemoryManagerTests' equivalent test - enumerates ProjectManager's
    /// actual stored properties and asserts none of their type names mention any forbidden
    /// component.
    func testProjectManagerHasNoAudioOrGeminiStoredDependencies() {
        let forbidden = [
            "GeminiLiveClient",
            "GeminiResponseGenerator",
            "AudioCaptureManager",
            "AudioMixer",
            "SystemAudioCaptureManager"
        ]
        let manager = makeManager()
        let mirror = Mirror(reflecting: manager)

        for child in mirror.children {
            let typeName = String(describing: type(of: child.value))
            for name in forbidden {
                XCTAssertFalse(typeName.contains(name), "ProjectManager must not hold a stored property referencing \(name) (found on '\(child.label ?? "?")': \(typeName))")
            }
        }
    }

    /// ProjectManager also has no reference to ChatSessionManager or MemoryManager - it's
    /// independent of every other manager in the app, only ever handed plain UUIDs.
    func testProjectManagerHasNoChatOrMemoryManagerStoredDependencies() {
        let forbidden = ["ChatSessionManager", "MemoryManager"]
        let manager = makeManager()
        let mirror = Mirror(reflecting: manager)

        for child in mirror.children {
            let typeName = String(describing: type(of: child.value))
            for name in forbidden {
                XCTAssertFalse(typeName.contains(name), "ProjectManager must not hold a stored property referencing \(name) (found on '\(child.label ?? "?")': \(typeName))")
            }
        }
    }
}
