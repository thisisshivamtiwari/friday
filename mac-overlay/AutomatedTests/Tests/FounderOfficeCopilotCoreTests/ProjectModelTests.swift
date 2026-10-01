import XCTest
@testable import FounderOfficeCopilotCore

/// Covers the six Project-layer value types' plain value-type behavior - initialization,
/// equality, and enum coverage. No Core Data, no ProjectManager here - see
/// ProjectStoreTests/ProjectManagerTests for persistence-layer coverage. One file, six
/// XCTestCase classes (mirrors the granularity of MemoryEntityTests/MemoryEdgeTests from
/// Phase 3.1, consolidated into fewer files given how many types this phase introduces).

// MARK: - Project

final class ProjectTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let project = Project(name: "Trustworthy AI")
        XCTAssertEqual(project.name, "Trustworthy AI")
        XCTAssertEqual(project.status, .active)
    }

    func testAllStatusValuesAreDistinct() {
        let all = Project.Status.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        XCTAssertTrue(all.contains(.active))
        XCTAssertTrue(all.contains(.completed))
        XCTAssertTrue(all.contains(.archived))
    }

    func testEqualityMatchesOnID() {
        let id = UUID()
        let date = Date()
        let a = Project(id: id, name: "X", createdAt: date, updatedAt: date)
        let b = Project(id: id, name: "X", createdAt: date, updatedAt: date)
        XCTAssertEqual(a, b)
    }

    func testTwoProjectsWithDifferentIDsAreNotEqual() {
        XCTAssertNotEqual(Project(name: "X"), Project(name: "X"))
    }
}

// MARK: - ProjectItem

final class ProjectItemTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let item = ProjectItem(projectID: UUID(), kind: .task, name: "Implement calibration", sourceSessionID: UUID())
        XCTAssertEqual(item.status, .proposed)
        XCTAssertNil(item.relatedItemID)
        XCTAssertNil(item.assignedTo)
        XCTAssertEqual(item.sourceMessageIDs, [])
        XCTAssertEqual(item.confidence, 0.5)
        XCTAssertFalse(item.isExplicit)
    }

    func testAllKindValuesAreDistinct() {
        let all = ProjectItem.Kind.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        for kind: ProjectItem.Kind in [.task, .objective, .researchQuestion, .component, .requirement, .artifact, .milestone, .openQuestion, .risk, .experiment, .result] {
            XCTAssertTrue(all.contains(kind))
        }
    }

    func testAllStatusValuesAreDistinct() {
        let all = ProjectItem.Status.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        for status: ProjectItem.Status in [.proposed, .planned, .active, .inProgress, .blocked, .completed, .achieved, .resolved, .abandoned] {
            XCTAssertTrue(all.contains(status))
        }
    }

    func testResultCanReferenceItsExperimentViaRelatedItemID() {
        let projectID = UUID()
        let sessionID = UUID()
        let experiment = ProjectItem(projectID: projectID, kind: .experiment, name: "Experiment 4", sourceSessionID: sessionID)
        let result = ProjectItem(projectID: projectID, kind: .result, name: "Calibration improved by 12%", relatedItemID: experiment.id, sourceSessionID: sessionID)
        XCTAssertEqual(result.relatedItemID, experiment.id)
    }
}

// MARK: - Decision

final class DecisionTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let decision = Decision(projectID: UUID(), statement: "Use Bayesian calibration", sourceSessionID: UUID())
        XCTAssertEqual(decision.status, .active)
        XCTAssertEqual(decision.madeBy, [])
        XCTAssertNil(decision.supersedes)
        XCTAssertNil(decision.supersededBy)
    }

    func testMultiplePeopleCanBeRecordedAsMakingADecision() {
        let professor = UUID()
        let shivam = UUID()
        let decision = Decision(projectID: UUID(), statement: "Use Bayesian calibration", madeBy: [professor, shivam], reason: "better uncertainty estimates", sourceSessionID: UUID())
        XCTAssertEqual(decision.madeBy, [professor, shivam])
        XCTAssertEqual(decision.reason, "better uncertainty estimates")
    }

    func testAllStatusValuesAreDistinct() {
        let all = Decision.Status.allCases
        XCTAssertEqual(Set(all), [.active, .superseded])
    }
}

// MARK: - Meeting

final class MeetingTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let meeting = Meeting(projectID: UUID(), title: "Weekly sync")
        XCTAssertEqual(meeting.participantEntityIDs, [])
        XCTAssertEqual(meeting.sessionIDs, [])
        XCTAssertNil(meeting.checkpointSummary)
    }

    func testMeetingCanSpanMultipleSessions() {
        let sessionA = UUID()
        let sessionB = UUID()
        let meeting = Meeting(projectID: UUID(), title: "Weekly sync", sessionIDs: [sessionA, sessionB])
        XCTAssertEqual(meeting.sessionIDs, [sessionA, sessionB])
    }
}

// MARK: - ProjectEvent

final class ProjectEventTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let event = ProjectEvent(projectID: UUID(), relatedItemID: UUID(), eventType: .itemCreated, description: "Task created")
        XCTAssertNil(event.sourceSessionID)
        XCTAssertEqual(event.sourceMessageIDs, [])
    }

    func testAllEventTypeValuesAreDistinct() {
        let all = ProjectEvent.EventType.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        for type: ProjectEvent.EventType in [.itemCreated, .statusChanged, .decisionMade, .decisionSuperseded, .meetingOccurred, .sessionAssigned, .sessionReassigned] {
            XCTAssertTrue(all.contains(type))
        }
    }
}

// MARK: - ProjectSessionLink

final class ProjectSessionLinkTests: XCTestCase {
    func testInitializerAppliesDefaults() {
        let link = ProjectSessionLink(sessionID: UUID(), projectID: UUID())
        XCTAssertNil(link.lastReassignedAt)
    }

    func testEqualityMatchesOnID() {
        let id = UUID()
        let session = UUID()
        let project = UUID()
        let date = Date()
        let a = ProjectSessionLink(id: id, sessionID: session, projectID: project, assignedAt: date)
        let b = ProjectSessionLink(id: id, sessionID: session, projectID: project, assignedAt: date)
        XCTAssertEqual(a, b)
    }
}
