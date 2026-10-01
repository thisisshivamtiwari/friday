import XCTest
@testable import FounderOfficeCopilotCore

/// Covers the graph PROJECTION - persisted state -> nodes/edges/integrity issues - with no UI,
/// no store and no main actor, because `GraphSnapshotBuilder` is a pure static function.
///
/// The rule these tests exist to defend: the graph may never fabricate a relationship. A
/// `Decision` with `relatedItemID == nil` must produce no edge, and a link that dangles or
/// crosses a project boundary must produce an integrity issue and STILL no edge. If that ever
/// regresses, the graph would start showing plausible-looking Decision -> ProjectItem
/// relationships that the data does not contain - which would destroy the only visible evidence
/// that Phase 4.3 linking works at all.
final class GraphSnapshotBuilderTests: XCTestCase {

    // MARK: Fixture

    private struct Fixture {
        var projects: [Project] = []
        var items: [ProjectItem] = []
        var decisions: [Decision] = []
        var links: [ProjectSessionLink] = []
        var people: [MemoryEntity] = []
        var sessionTitles: [UUID: String] = [:]
        var sessionDates: [UUID: Date] = [:]

        func build() -> GraphSnapshot {
            GraphSnapshotBuilder.build(
                projects: projects, items: items, decisions: decisions, sessionLinks: links,
                people: people, sessionTitles: sessionTitles, sessionDates: sessionDates
            )
        }
    }

    private func person(_ name: String) -> MemoryEntity {
        MemoryEntity(kind: .person, name: name)
    }

    /// Mirrors the shape of the real CleanFixture: three projects, work items and decisions per
    /// project, sessions linked through `ProjectSessionLink`, people referenced by `madeBy`.
    private func standardFixture() -> (Fixture, project: Project, item: ProjectItem, session: UUID, maya: MemoryEntity) {
        var fixture = Fixture()
        let project = Project(name: "Trustworthy Multi-Agent AI Research")
        let sessionID = UUID()
        let maya = person("Maya Lin")

        let item = ProjectItem(projectID: project.id, kind: .experiment, name: "MC dropout calibration evaluation", status: .completed, sourceSessionID: sessionID)
        let decision = Decision(projectID: project.id, statement: "Rule out conformal prediction for message payload bounds", context: "Message payload bounds calibration", relatedItemID: item.id, madeBy: [maya.id], sourceSessionID: sessionID)

        fixture.projects = [project]
        fixture.items = [item]
        fixture.decisions = [decision]
        fixture.links = [ProjectSessionLink(sessionID: sessionID, projectID: project.id)]
        fixture.people = [maya]
        fixture.sessionTitles = [sessionID: "Research — Meeting 2"]
        fixture.sessionDates = [sessionID: Date(timeIntervalSince1970: 1_700_000_000)]
        return (fixture, project, item, sessionID, maya)
    }

    private func hasEdge(_ snapshot: GraphSnapshot, _ kind: GraphEdgeKind, from source: GraphNodeID, to destination: GraphNodeID) -> Bool {
        snapshot.edges.contains { $0.kind == kind && $0.source == source && $0.destination == destination }
    }

    // MARK: Node projection

    func testProjectsItemsDecisionsSessionsAndPeopleAllBecomeNodes() {
        let (fixture, project, item, sessionID, maya) = standardFixture()
        let snapshot = fixture.build()

        XCTAssertNotNil(snapshot.node(GraphNodeID(kind: .project, entityID: project.id)))
        XCTAssertNotNil(snapshot.node(GraphNodeID(kind: .projectItem, entityID: item.id)))
        XCTAssertNotNil(snapshot.node(GraphNodeID(kind: .session, entityID: sessionID)))
        XCTAssertNotNil(snapshot.node(GraphNodeID(kind: .person, entityID: maya.id)))
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .decision }.count, 1)
    }

    func testNodeIdentityIsThePersistedEntityIDNotAFreshUUID() {
        let (fixture, project, item, _, _) = standardFixture()
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.node(GraphNodeID(kind: .project, entityID: project.id))?.title, project.name)
        XCTAssertEqual(snapshot.node(GraphNodeID(kind: .projectItem, entityID: item.id))?.title, item.name)
    }

    func testWorkItemsCarryLifecycleAndOtherKindsDoNot() {
        let (fixture, _, item, _, _) = standardFixture()
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.node(GraphNodeID(kind: .projectItem, entityID: item.id))?.lifecycleStatus, "completed")
        XCTAssertNil(snapshot.nodes.first { $0.kind == .decision }?.lifecycleStatus)
        XCTAssertNil(snapshot.nodes.first { $0.kind == .session }?.lifecycleStatus)
    }

    /// Determinism is the property everything else rests on - stable selection, stable layout,
    /// stable tests. Dictionary and Set iteration order is unspecified, so this would fail if
    /// any collection leaked its order into the output.
    func testSnapshotIsDeterministicAcrossRepeatedBuilds() {
        let (fixture, _, _, _, _) = standardFixture()
        let first = fixture.build()
        for _ in 0..<10 {
            let next = fixture.build()
            XCTAssertEqual(first.nodes.map(\.id), next.nodes.map(\.id))
            XCTAssertEqual(first.edges.map(\.id), next.edges.map(\.id))
            XCTAssertEqual(first, next)
        }
    }

    // MARK: Structural edges

    func testProjectContainsItemAndHasDecisionAndLinksSession() {
        let (fixture, project, item, sessionID, _) = standardFixture()
        let snapshot = fixture.build()
        let projectNode = GraphNodeID(kind: .project, entityID: project.id)

        XCTAssertTrue(hasEdge(snapshot, .projectContainsItem, from: projectNode, to: GraphNodeID(kind: .projectItem, entityID: item.id)))
        XCTAssertTrue(hasEdge(snapshot, .projectLinkedToSession, from: projectNode, to: GraphNodeID(kind: .session, entityID: sessionID)))
        XCTAssertTrue(snapshot.edges.contains { $0.kind == .projectHasDecision && $0.source == projectNode })
    }

    func testItemAndDecisionBothPointAtTheSessionTheyCameFrom() {
        let (fixture, _, item, sessionID, _) = standardFixture()
        let snapshot = fixture.build()
        let sessionNode = GraphNodeID(kind: .session, entityID: sessionID)
        XCTAssertTrue(hasEdge(snapshot, .itemDiscussedInSession, from: GraphNodeID(kind: .projectItem, entityID: item.id), to: sessionNode))
        XCTAssertTrue(snapshot.edges.contains { $0.kind == .decisionDiscussedInSession && $0.destination == sessionNode })
    }

    func testDecisionMadeByPersonBecomesAnEdge() {
        let (fixture, _, _, _, maya) = standardFixture()
        let snapshot = fixture.build()
        XCTAssertTrue(snapshot.edges.contains { $0.kind == .decisionMadeByPerson && $0.destination == GraphNodeID(kind: .person, entityID: maya.id) })
    }

    func testItemAssignedToPersonBecomesAnEdge() {
        var (fixture, project, _, sessionID, maya) = standardFixture()
        let assigned = ProjectItem(projectID: project.id, kind: .task, name: "Write up results", assignedTo: maya.id, sourceSessionID: sessionID)
        fixture.items.append(assigned)
        let snapshot = fixture.build()
        XCTAssertTrue(hasEdge(snapshot, .itemAssignedToPerson,
                              from: GraphNodeID(kind: .projectItem, entityID: assigned.id),
                              to: GraphNodeID(kind: .person, entityID: maya.id)))
    }

    // MARK: THE Phase 4.3 edge

    func testDecisionRelatesToItemEdgeExistsWhenRelatedItemIDIsSet() {
        let (fixture, _, item, _, _) = standardFixture()
        let snapshot = fixture.build()
        XCTAssertTrue(snapshot.edges.contains {
            $0.kind == .decisionRelatesToItem && $0.destination == GraphNodeID(kind: .projectItem, entityID: item.id)
        })
    }

    /// THE most important negative test in the graph layer. Every decision in the reference
    /// fixture has `relatedItemID == nil`; if the graph invented edges from text similarity,
    /// this fixture would produce one, since the decision and the item share several words.
    func testNilRelatedItemIDProducesNoEdgeAndNoIssue() {
        var fixture = Fixture()
        let project = Project(name: "Research")
        let sessionID = UUID()
        let item = ProjectItem(projectID: project.id, kind: .experiment, name: "Conformal prediction calibration gridworld runs", sourceSessionID: sessionID)
        // Deliberately heavy lexical overlap with the item, and relatedItemID left nil.
        let decision = Decision(projectID: project.id, statement: "Rule out conformal prediction calibration for gridworld runs", relatedItemID: nil, sourceSessionID: sessionID)
        fixture.projects = [project]; fixture.items = [item]; fixture.decisions = [decision]
        fixture.sessionTitles = [sessionID: "Meeting"]

        let snapshot = fixture.build()
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .decisionRelatesToItem }.isEmpty,
                      "a nil link must never be inferred from overlapping text")
        XCTAssertTrue(snapshot.integrityIssues.isEmpty, "nil is a valid, complete answer - not a data problem")
    }

    func testDanglingRelatedItemIDIsReportedAndDrawsNoEdge() {
        var (fixture, project, _, sessionID, _) = standardFixture()
        fixture.decisions = [Decision(projectID: project.id, statement: "Adopt temperature scaling", relatedItemID: UUID(), sourceSessionID: sessionID)]
        let snapshot = fixture.build()

        XCTAssertTrue(snapshot.edges.filter { $0.kind == .decisionRelatesToItem }.isEmpty)
        XCTAssertEqual(snapshot.integrityIssues.filter { $0.kind == .danglingRelatedItem }.count, 1)
    }

    func testCrossProjectRelatedItemIDIsReportedAsAnIsolationViolationAndDrawsNoEdge() {
        var (fixture, project, _, sessionID, _) = standardFixture()
        let otherProject = Project(name: "Hotel Revenue Forecasting System")
        let foreignItem = ProjectItem(projectID: otherProject.id, kind: .component, name: "Competitor pricing scraper", sourceSessionID: UUID())
        fixture.projects.append(otherProject)
        fixture.items.append(foreignItem)
        fixture.decisions = [Decision(projectID: project.id, statement: "Reject OTA fallback", relatedItemID: foreignItem.id, sourceSessionID: sessionID)]

        let snapshot = fixture.build()
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .decisionRelatesToItem }.isEmpty,
                      "a cross-project link must never be drawn as if valid")
        let issue = snapshot.integrityIssues.first { $0.kind == .crossProjectRelatedItem }
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.detail.contains("project isolation violation") ?? false)
    }

    func testTwoDecisionsMayReferenceTheSameItemWithoutCollision() {
        var (fixture, project, item, sessionID, _) = standardFixture()
        fixture.decisions.append(Decision(projectID: project.id, statement: "Re-run the evaluation", relatedItemID: item.id, sourceSessionID: sessionID))
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .decisionRelatesToItem }.count, 2,
                       "two distinct decisions about one item are two distinct edges")
    }

    // MARK: Supersession

    func testSupersessionProducesExactlyOneNormalisedEdgeFromBothSides() {
        var (fixture, project, _, sessionID, _) = standardFixture()
        let old = Decision(projectID: project.id, statement: "Use conformal prediction", status: .superseded, sourceSessionID: sessionID)
        let new = Decision(projectID: project.id, statement: "Use temperature scaling", supersedes: old.id, sourceSessionID: sessionID)
        var oldWithBackPointer = old
        oldWithBackPointer.supersededBy = new.id
        fixture.decisions = [oldWithBackPointer, new]

        let snapshot = fixture.build()
        let superEdges = snapshot.edges.filter { $0.kind == .decisionSupersedesDecision }
        XCTAssertEqual(superEdges.count, 1, "both rows record the chain; it must not become two opposite edges")
        XCTAssertEqual(superEdges.first?.source, GraphNodeID(kind: .decision, entityID: new.id))
        XCTAssertEqual(superEdges.first?.destination, GraphNodeID(kind: .decision, entityID: old.id))
    }

    func testDanglingSupersessionIsReported() {
        var (fixture, project, _, sessionID, _) = standardFixture()
        fixture.decisions = [Decision(projectID: project.id, statement: "Use temperature scaling", supersedes: UUID(), sourceSessionID: sessionID)]
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.integrityIssues.filter { $0.kind == .danglingSupersession }.count, 1)
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .decisionSupersedesDecision }.isEmpty)
    }

    // MARK: Orphans and edge cases

    func testItemNamingAMissingProjectIsReportedAsOrphaned() {
        var fixture = Fixture()
        let sessionID = UUID()
        fixture.items = [ProjectItem(projectID: UUID(), kind: .task, name: "Stray task", sourceSessionID: sessionID)]
        fixture.sessionTitles = [sessionID: "Meeting"]
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.integrityIssues.filter { $0.kind == .orphanedProjectReference }.count, 1)
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .projectContainsItem }.isEmpty)
    }

    func testEmptyInputProducesAnEmptySnapshot() {
        let snapshot = Fixture().build()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(snapshot.edges.isEmpty)
        XCTAssertTrue(snapshot.integrityIssues.isEmpty)
    }

    func testProjectWithNoItemsOrDecisionsIsStillASingleNode() {
        var fixture = Fixture()
        fixture.projects = [Project(name: "Empty project")]
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.nodes.count, 1)
        XCTAssertTrue(snapshot.edges.isEmpty)
    }

    func testProjectWithDecisionsButNoItemsProducesNoItemEdges() {
        var fixture = Fixture()
        let project = Project(name: "Decisions only")
        let sessionID = UUID()
        fixture.projects = [project]
        fixture.decisions = [Decision(projectID: project.id, statement: "Ship it", sourceSessionID: sessionID)]
        fixture.sessionTitles = [sessionID: "Meeting"]
        let snapshot = fixture.build()
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .projectContainsItem }.isEmpty)
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .projectHasDecision }.count, 1)
    }

    /// Unlinked chat sessions are the overwhelming majority in a real install. They are not
    /// project-graph nodes, and projecting them would bury the structure.
    func testSessionsWithNoProjectRelationshipAreNotProjected() {
        var (fixture, _, _, _, _) = standardFixture()
        let unrelated = UUID()
        fixture.sessionTitles[unrelated] = "Chat about lunch"
        let snapshot = fixture.build()
        XCTAssertNil(snapshot.node(GraphNodeID(kind: .session, entityID: unrelated)))
    }

    func testPeopleWithNoProjectRelationshipAreNotProjected() {
        var (fixture, _, _, _, _) = standardFixture()
        fixture.people.append(person("Unrelated Person"))
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .person }.count, 1)
    }

    func testAPersonReferencedByManyDecisionsGetsOneNodeAndManyEdges() {
        var (fixture, project, _, sessionID, maya) = standardFixture()
        for index in 0..<12 {
            fixture.decisions.append(Decision(projectID: project.id, statement: "Decision \(index)", madeBy: [maya.id], sourceSessionID: sessionID))
        }
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .person }.count, 1, "one person is one node however many decisions cite them")
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .decisionMadeByPerson }.count, 13)
    }

    func testDuplicateTitlesAcrossProjectsRemainDistinctNodes() {
        var fixture = Fixture()
        let a = Project(name: "Project A"), b = Project(name: "Project B")
        let sessionID = UUID()
        let itemA = ProjectItem(projectID: a.id, kind: .task, name: "Calibration", sourceSessionID: sessionID)
        let itemB = ProjectItem(projectID: b.id, kind: .task, name: "Calibration", sourceSessionID: sessionID)
        fixture.projects = [a, b]; fixture.items = [itemA, itemB]
        fixture.sessionTitles = [sessionID: "Meeting"]

        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .projectItem }.count, 2, "identical names must not merge across projects")
    }

    func testTheSameRelationshipDiscoveredTwiceCollapsesToOneEdge() {
        var (fixture, project, _, sessionID, maya) = standardFixture()
        // A decision naming the same person twice - the model permits it, the graph must not
        // render a doubled edge.
        fixture.decisions = [Decision(projectID: project.id, statement: "Agreed", madeBy: [maya.id, maya.id], sourceSessionID: sessionID)]
        let snapshot = fixture.build()
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .decisionMadeByPerson }.count, 1)
    }

    // MARK: Degree / helpers

    func testDegreeCountsEveryEdgeTouchingANodeInEitherDirection() {
        let (fixture, project, _, _, _) = standardFixture()
        let snapshot = fixture.build()
        // project -> item, project -> decision, project -> session
        XCTAssertEqual(snapshot.degree(of: GraphNodeID(kind: .project, entityID: project.id)), 3)
    }
}
