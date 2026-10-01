import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `EpisodeSummary.build` - a projection over already-persisted data, never itself
/// persisted. Confirms the Meeting-present / ChatSession-fallback paths, the "unknown session
/// returns nil, known-but-empty session returns a minimal summary" distinction, and
/// sourceMessageIDs aggregation/dedup across Decisions/ProjectItems/ProjectEvents.
final class EpisodeSummaryTests: XCTestCase {
    private func makeChatSessionManager() -> ChatSessionManager {
        ChatSessionManager(store: ChatSessionStore(inMemory: true))
    }

    private func makeProjectManager() -> ProjectManager {
        ProjectManager(store: ProjectStore(inMemory: true))
    }

    /// Records one heard message into the manager's current recording session and returns
    /// (sessionID, messageID) - the standard way these tests establish a real, resolvable
    /// (session, message) pair for provenance fields.
    @discardableResult
    private func recordOneMessage(_ chatSessionManager: ChatSessionManager, text: String = "hello") -> (sessionID: UUID, messageID: UUID) {
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.appendHeardDelta(text)
        let messageID = chatSessionManager.recordingSession!.messages.last!.id
        chatSessionManager.endRecording()
        return (sessionID, messageID)
    }

    func testBuildReturnsNilForCompletelyUnknownSession() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()

        let summary = EpisodeSummary.build(forSession: UUID(), chatSessionManager: chatSessionManager, projectManager: projectManager)
        XCTAssertNil(summary)
    }

    func testBuildFallsBackToChatSessionWhenNoMeetingExists() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.rename(sessionID, to: "Standup Notes")
        chatSessionManager.endRecording()

        let summary = EpisodeSummary.build(forSession: sessionID, chatSessionManager: chatSessionManager, projectManager: projectManager)
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.meetingID)
        XCTAssertEqual(summary?.title, "Standup Notes")
        XCTAssertNil(summary?.checkpointSummary)
        XCTAssertTrue(summary?.participantEntityIDs.isEmpty ?? false)
        XCTAssertTrue(summary?.decisions.isEmpty ?? false)
        XCTAssertTrue(summary?.projectItems.isEmpty ?? false)
        XCTAssertTrue(summary?.projectEvents.isEmpty ?? false)
    }

    func testBuildUsesMeetingWhenOneExists() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let project = projectManager.createProject(Project(name: "Friday"))
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.endRecording()
        let participant = UUID()
        let occurredAt = Date().addingTimeInterval(-3600)
        let meeting = projectManager.createMeeting(Meeting(
            projectID: project.id,
            title: "Weekly Sync",
            participantEntityIDs: [participant],
            sessionIDs: [sessionID],
            occurredAt: occurredAt,
            checkpointSummary: "Discussed roadmap."
        ))

        let summary = EpisodeSummary.build(forSession: sessionID, chatSessionManager: chatSessionManager, projectManager: projectManager)
        XCTAssertEqual(summary?.meetingID, meeting.id)
        XCTAssertEqual(summary?.title, "Weekly Sync")
        XCTAssertEqual(summary?.occurredAt, occurredAt)
        XCTAssertEqual(summary?.participantEntityIDs, [participant])
        XCTAssertEqual(summary?.checkpointSummary, "Discussed roadmap.")
    }

    func testBuildFiltersDecisionsItemsAndEventsBySourceSession() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let project = projectManager.createProject(Project(name: "Friday"))
        let (thisSession, thisMessage) = recordOneMessage(chatSessionManager, text: "we decided on X")
        let (otherSession, otherMessage) = recordOneMessage(chatSessionManager, text: "unrelated")

        let matchingDecision = projectManager.createDecision(Decision(
            projectID: project.id, statement: "Use Postgres", sourceSessionID: thisSession, sourceMessageIDs: [thisMessage]
        ))
        _ = projectManager.createDecision(Decision(
            projectID: project.id, statement: "Unrelated decision", sourceSessionID: otherSession, sourceMessageIDs: [otherMessage]
        ))
        let matchingItem = projectManager.createProjectItem(ProjectItem(
            projectID: project.id, kind: .task, name: "Ship it", sourceSessionID: thisSession, sourceMessageIDs: [thisMessage]
        ))
        _ = projectManager.createProjectItem(ProjectItem(
            projectID: project.id, kind: .task, name: "Unrelated task", sourceSessionID: otherSession, sourceMessageIDs: [otherMessage]
        ))
        let matchingEvent = projectManager.createProjectEvent(ProjectEvent(
            projectID: project.id, relatedItemID: matchingItem.id, eventType: .itemCreated, description: "Item created",
            sourceSessionID: thisSession, sourceMessageIDs: [thisMessage]
        ))

        let summary = EpisodeSummary.build(forSession: thisSession, chatSessionManager: chatSessionManager, projectManager: projectManager)
        XCTAssertEqual(summary?.decisions.map(\.id), [matchingDecision.id])
        XCTAssertEqual(summary?.projectItems.map(\.id), [matchingItem.id])
        XCTAssertEqual(summary?.projectEvents.map(\.id), [matchingEvent.id])
    }

    func testSourceMessageIDsAreAggregatedAndDeduped() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let project = projectManager.createProject(Project(name: "Friday"))
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.appendHeardDelta("first")
        let messageA = chatSessionManager.recordingSession!.messages.last!.id
        chatSessionManager.appendHeardDelta("second")
        chatSessionManager.endRecording()

        let item = projectManager.createProjectItem(ProjectItem(
            projectID: project.id, kind: .task, name: "Task", sourceSessionID: sessionID, sourceMessageIDs: [messageA]
        ))
        _ = projectManager.createDecision(Decision(
            projectID: project.id, statement: "Decision", sourceSessionID: sessionID, sourceMessageIDs: [messageA]
        ))
        _ = projectManager.createProjectEvent(ProjectEvent(
            projectID: project.id, relatedItemID: item.id, eventType: .itemCreated, description: "created",
            sourceSessionID: sessionID, sourceMessageIDs: [messageA]
        ))

        let summary = EpisodeSummary.build(forSession: sessionID, chatSessionManager: chatSessionManager, projectManager: projectManager)
        XCTAssertEqual(summary?.sourceMessageIDs, [messageA], "the same message id contributed by three different sources must be deduped to one")
    }
}
