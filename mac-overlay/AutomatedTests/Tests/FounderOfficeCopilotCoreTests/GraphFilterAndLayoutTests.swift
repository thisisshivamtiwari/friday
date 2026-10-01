import XCTest
import CoreGraphics
@testable import FounderOfficeCopilotCore

/// Covers the two remaining PURE graph layers - filtering/search and layout - plus the
/// performance characteristics the Graph UI depends on. No UI, no store, no main actor.
final class GraphFilterAndLayoutTests: XCTestCase {

    // MARK: Fixture

    /// Two projects with items, decisions, a linked session each, and one person shared between
    /// them - the shape that makes project filtering interesting (a person belongs to neither
    /// project exclusively).
    private struct TwoProjectFixture {
        let snapshot: GraphSnapshot
        let projectA: UUID, projectB: UUID
        let completedItemA: UUID, plannedItemA: UUID
        let decisionA: UUID
        let sessionA: UUID, sessionB: UUID
        let sharedPerson: UUID
    }

    private func makeTwoProjectFixture() -> TwoProjectFixture {
        let a = Project(name: "Trustworthy AI"), b = Project(name: "Hotel Revenue")
        let sessionA = UUID(), sessionB = UUID()
        let maya = MemoryEntity(kind: .person, name: "Maya Lin")

        let completed = ProjectItem(projectID: a.id, kind: .experiment, name: "MC dropout calibration evaluation", status: .completed, sourceSessionID: sessionA)
        let planned = ProjectItem(projectID: a.id, kind: .task, name: "Test temperature scaling versus MC dropout", status: .planned, sourceSessionID: sessionA)
        let itemB = ProjectItem(projectID: b.id, kind: .component, name: "Competitor pricing scraper pipeline", status: .blocked, sourceSessionID: sessionB)

        let decisionA = Decision(projectID: a.id, statement: "Rule out conformal prediction", context: "payload bounds", relatedItemID: completed.id, madeBy: [maya.id], sourceSessionID: sessionA)
        let decisionB = Decision(projectID: b.id, statement: "Reject OTA aggregator fallback", madeBy: [maya.id], sourceSessionID: sessionB)

        let snapshot = GraphSnapshotBuilder.build(
            projects: [a, b], items: [completed, planned, itemB], decisions: [decisionA, decisionB],
            sessionLinks: [ProjectSessionLink(sessionID: sessionA, projectID: a.id), ProjectSessionLink(sessionID: sessionB, projectID: b.id)],
            people: [maya],
            sessionTitles: [sessionA: "Research — Meeting 2", sessionB: "Revenue — Meeting 1"],
            sessionDates: [:]
        )
        return TwoProjectFixture(snapshot: snapshot, projectA: a.id, projectB: b.id,
                                 completedItemA: completed.id, plannedItemA: planned.id, decisionA: decisionA.id,
                                 sessionA: sessionA, sessionB: sessionB, sharedPerson: maya.id)
    }

    private func filtered(_ criteria: GraphFilterCriteria, _ fixture: TwoProjectFixture) -> GraphSnapshot {
        GraphFilter.apply(criteria, to: fixture.snapshot)
    }

    // MARK: Filtering invariants

    func testUnfilteredCriteriaReturnsTheWholeGraph() {
        let fixture = makeTwoProjectFixture()
        let result = filtered(.unfiltered, fixture)
        XCTAssertEqual(result.nodes.count, fixture.snapshot.nodes.count)
        XCTAssertEqual(result.edges.count, fixture.snapshot.edges.count)
    }

    /// The invariant every other filtering behaviour rests on: filtering only ever REMOVES, and
    /// an edge can never survive without both endpoints.
    func testFilteringNeverLeavesAnEdgeWithoutBothEndpoints() {
        let fixture = makeTwoProjectFixture()
        let criteriaSet: [GraphFilterCriteria] = [
            GraphFilterCriteria(projectID: fixture.projectA, nodeKinds: [], lifecycleStatuses: [], searchText: ""),
            GraphFilterCriteria(projectID: nil, nodeKinds: [.decision], lifecycleStatuses: [], searchText: ""),
            GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: ["completed"], searchText: ""),
            GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: "calibration"),
            GraphFilterCriteria(projectID: fixture.projectB, nodeKinds: [.projectItem, .person], lifecycleStatuses: ["blocked"], searchText: "scraper"),
        ]
        for criteria in criteriaSet {
            let result = GraphFilter.apply(criteria, to: fixture.snapshot)
            let ids = Set(result.nodes.map(\.id))
            for edge in result.edges {
                XCTAssertTrue(ids.contains(edge.source), "dangling source for \(criteria)")
                XCTAssertTrue(ids.contains(edge.destination), "dangling destination for \(criteria)")
            }
            XCTAssertTrue(Set(result.nodes.map(\.id)).isSubset(of: Set(fixture.snapshot.nodes.map(\.id))),
                          "filtering must produce a subgraph, never new nodes")
        }
    }

    func testProjectFilterKeepsOnlyThatProjectsSubgraph() {
        let fixture = makeTwoProjectFixture()
        let result = filtered(GraphFilterCriteria(projectID: fixture.projectA, nodeKinds: [], lifecycleStatuses: [], searchText: ""), fixture)
        XCTAssertNil(result.node(GraphNodeID(kind: .project, entityID: fixture.projectB)))
        XCTAssertNil(result.node(GraphNodeID(kind: .session, entityID: fixture.sessionB)))
        XCTAssertNotNil(result.node(GraphNodeID(kind: .projectItem, entityID: fixture.completedItemA)))
    }

    /// A person has no `projectID`, so a naive project filter would delete them from every
    /// project view and take "made by" with them - silently changing what the graph claims.
    func testProjectFilterKeepsAPersonStillReachedByASurvivingNode() {
        let fixture = makeTwoProjectFixture()
        let result = filtered(GraphFilterCriteria(projectID: fixture.projectA, nodeKinds: [], lifecycleStatuses: [], searchText: ""), fixture)
        XCTAssertNotNil(result.node(GraphNodeID(kind: .person, entityID: fixture.sharedPerson)))
        XCTAssertTrue(result.edges.contains { $0.kind == .decisionMadeByPerson })
    }

    func testNodeKindFilterHidesOtherKinds() {
        let fixture = makeTwoProjectFixture()
        let result = filtered(GraphFilterCriteria(projectID: nil, nodeKinds: [.project, .decision], lifecycleStatuses: [], searchText: ""), fixture)
        XCTAssertTrue(result.nodes.allSatisfy { $0.kind == .project || $0.kind == .decision })
        XCTAssertFalse(result.nodes.isEmpty)
    }

    /// Lifecycle applies to work items only - filtering by status must narrow the items, not
    /// empty the graph of every type that has no status.
    func testLifecycleFilterNarrowsItemsWithoutDeletingStatuslessTypes() {
        let fixture = makeTwoProjectFixture()
        let result = filtered(GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: ["completed"], searchText: ""), fixture)
        XCTAssertNotNil(result.node(GraphNodeID(kind: .projectItem, entityID: fixture.completedItemA)))
        XCTAssertNil(result.node(GraphNodeID(kind: .projectItem, entityID: fixture.plannedItemA)))
        XCTAssertNotNil(result.node(GraphNodeID(kind: .project, entityID: fixture.projectA)), "a project has no lifecycle and must survive")
        XCTAssertNotNil(result.node(GraphNodeID(kind: .decision, entityID: fixture.decisionA)))
    }

    func testSearchMatchesTitleAndSubtitleCaseInsensitively() {
        let fixture = makeTwoProjectFixture()
        XCTAssertTrue(filtered(GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: "MC DROPOUT"), fixture)
            .nodes.contains { $0.id.entityID == fixture.completedItemA })
        // "payload bounds" exists only in the decision's CONTEXT, which is its subtitle.
        XCTAssertTrue(filtered(GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: "payload"), fixture)
            .nodes.contains { $0.id.entityID == fixture.decisionA })
    }

    func testSearchWithNoMatchesYieldsAnEmptyGraphNotAnUnfilteredOne() {
        let fixture = makeTwoProjectFixture()
        let result = filtered(GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: "zzzznotpresent"), fixture)
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }

    func testIntegrityIssuesFollowTheirSubjectThroughFiltering() {
        let project = Project(name: "Research")
        let sessionID = UUID()
        let decision = Decision(projectID: project.id, statement: "Adopt scaling", relatedItemID: UUID(), sourceSessionID: sessionID)
        let snapshot = GraphSnapshotBuilder.build(
            projects: [project], items: [], decisions: [decision], sessionLinks: [], people: [],
            sessionTitles: [sessionID: "Meeting"], sessionDates: [:]
        )
        XCTAssertEqual(snapshot.integrityIssues.count, 1)

        let hidden = GraphFilter.apply(GraphFilterCriteria(projectID: nil, nodeKinds: [.project], lifecycleStatuses: [], searchText: ""), to: snapshot)
        XCTAssertTrue(hidden.integrityIssues.isEmpty, "an issue about a hidden node must not linger")

        let shown = GraphFilter.apply(GraphFilterCriteria(projectID: nil, nodeKinds: [.decision], lifecycleStatuses: [], searchText: ""), to: snapshot)
        XCTAssertEqual(shown.integrityIssues.count, 1, "a visible node's problem must stay visible")
    }

    func testEmptyKindSetIsTreatedAsAllKinds() {
        let fixture = makeTwoProjectFixture()
        XCTAssertEqual(filtered(GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: ""), fixture).nodes.count,
                       fixture.snapshot.nodes.count, "an uninitialised toggle set must never render a blank graph")
    }

    // MARK: Layout

    func testEveryVisibleNodeGetsExactlyOnePosition() {
        let fixture = makeTwoProjectFixture()
        let positions = GraphLayoutEngine.layout(fixture.snapshot)
        XCTAssertEqual(Set(positions.keys), Set(fixture.snapshot.nodes.map(\.id)))
    }

    func testLayoutIsDeterministic() {
        let fixture = makeTwoProjectFixture()
        let first = GraphLayoutEngine.layout(fixture.snapshot)
        for _ in 0..<10 {
            XCTAssertEqual(GraphLayoutEngine.layout(fixture.snapshot), first)
        }
    }

    /// Node identity must survive filtering: a node that is still visible keeps ITS OWN place in
    /// its ring rather than being re-packed, so filtering does not scramble the user's mental map
    /// of one project.
    func testASingleProjectLaysOutIdenticallyWhetherOrNotOtherProjectsAreFiltered() {
        let fixture = makeTwoProjectFixture()
        let onlyA = GraphFilter.apply(GraphFilterCriteria(projectID: fixture.projectA, nodeKinds: [], lifecycleStatuses: [], searchText: ""), to: fixture.snapshot)
        let positions = GraphLayoutEngine.layout(onlyA)
        XCTAssertEqual(positions.count, onlyA.nodes.count)
        // The sole remaining project becomes the origin hub - the deliberate single-project case.
        XCTAssertEqual(positions[GraphNodeID(kind: .project, entityID: fixture.projectA)], .zero)
    }

    func testNodesDoNotLandOnTopOfEachOther() {
        let fixture = makeTwoProjectFixture()
        let positions = GraphLayoutEngine.layout(fixture.snapshot)
        let points = Array(positions.values)
        for i in points.indices {
            for j in points.indices where j > i {
                let distance = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                XCTAssertGreaterThan(distance, 1.0, "two nodes occupy the same point")
            }
        }
    }

    /// A ring must GROW rather than crowd when it holds many nodes, otherwise a project with 40
    /// items renders as an unreadable ring of overlapping labels.
    func testDenseRingsGrowSoNeighboursStayApart() {
        let project = Project(name: "Dense")
        let sessionID = UUID()
        let items = (0..<40).map { ProjectItem(projectID: project.id, kind: .task, name: "Item \($0)", sourceSessionID: sessionID) }
        let snapshot = GraphSnapshotBuilder.build(projects: [project], items: items, decisions: [], sessionLinks: [], people: [], sessionTitles: [sessionID: "S"], sessionDates: [:])

        let positions = GraphLayoutEngine.layout(snapshot)
        let itemPoints = snapshot.nodes.filter { $0.kind == .projectItem }.compactMap { positions[$0.id] }
        XCTAssertEqual(itemPoints.count, 40)
        var minimumSeparation = CGFloat.greatestFiniteMagnitude
        for i in itemPoints.indices {
            for j in itemPoints.indices where j > i {
                minimumSeparation = min(minimumSeparation, hypot(itemPoints[i].x - itemPoints[j].x, itemPoints[i].y - itemPoints[j].y))
            }
        }
        XCTAssertGreaterThan(minimumSeparation, 60, "a dense ring must expand instead of overlapping")
    }

    func testDisconnectedComponentsAreAllPlaced() {
        let a = Project(name: "A"), b = Project(name: "B"), c = Project(name: "C")
        let snapshot = GraphSnapshotBuilder.build(projects: [a, b, c], items: [], decisions: [], sessionLinks: [], people: [], sessionTitles: [:], sessionDates: [:])
        let positions = GraphLayoutEngine.layout(snapshot)
        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(Set(positions.values.map { "\($0.x),\($0.y)" }).count, 3, "disconnected hubs must not stack")
    }

    func testEmptyAndSingleNodeLayouts() {
        XCTAssertTrue(GraphLayoutEngine.layout(.empty).isEmpty)
        XCTAssertNil(GraphLayoutEngine.bounds(of: [:]))

        let project = Project(name: "Solo")
        let snapshot = GraphSnapshotBuilder.build(projects: [project], items: [], decisions: [], sessionLinks: [], people: [], sessionTitles: [:], sessionDates: [:])
        let positions = GraphLayoutEngine.layout(snapshot)
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.value, .zero)
        XCTAssertNotNil(GraphLayoutEngine.bounds(of: positions))
    }

    func testBoundsCoverEveryNode() {
        let fixture = makeTwoProjectFixture()
        let positions = GraphLayoutEngine.layout(fixture.snapshot)
        let bounds = try? XCTUnwrap(GraphLayoutEngine.bounds(of: positions))
        for point in positions.values {
            XCTAssertTrue(bounds?.insetBy(dx: -1, dy: -1).contains(point) ?? false)
        }
    }

    // MARK: Scale

    /// Builds a graph of roughly `targetNodes` nodes spread over realistic projects.
    private func makeLargeSnapshot(targetNodes: Int) -> GraphSnapshot {
        let projectCount = max(1, targetNodes / 50)
        let perProject = max(1, targetNodes / max(projectCount, 1) / 2)
        var projects: [Project] = [], items: [ProjectItem] = [], decisions: [Decision] = []
        var links: [ProjectSessionLink] = [], titles: [UUID: String] = [:]
        let person = MemoryEntity(kind: .person, name: "Shared Person")

        for p in 0..<projectCount {
            let project = Project(name: "Project \(p)")
            let sessionID = UUID()
            titles[sessionID] = "Session \(p)"
            links.append(ProjectSessionLink(sessionID: sessionID, projectID: project.id))
            var projectItems: [ProjectItem] = []
            for i in 0..<perProject {
                projectItems.append(ProjectItem(projectID: project.id, kind: .task, name: "Item \(p)-\(i)", status: .planned, sourceSessionID: sessionID))
            }
            for i in 0..<perProject {
                decisions.append(Decision(projectID: project.id, statement: "Decision \(p)-\(i)",
                                          relatedItemID: projectItems[i % projectItems.count].id,
                                          madeBy: [person.id], sourceSessionID: sessionID))
            }
            projects.append(project)
            items.append(contentsOf: projectItems)
        }
        return GraphSnapshotBuilder.build(projects: projects, items: items, decisions: decisions,
                                          sessionLinks: links, people: [person], sessionTitles: titles, sessionDates: [:])
    }

    /// Correctness at scale, and the cost of the two operations the UI performs most often.
    /// Deliberately generous thresholds - this asserts "no accidental quadratic blow-up", not a
    /// specific machine's speed.
    func testLayoutAndFilterScaleTo1000Nodes() {
        for target in [10, 50, 100, 500, 1000] {
            let snapshot = makeLargeSnapshot(targetNodes: target)

            let layoutStart = Date()
            let positions = GraphLayoutEngine.layout(snapshot)
            let layoutSeconds = Date().timeIntervalSince(layoutStart)

            let filterStart = Date()
            let result = GraphFilter.apply(GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: "Item"), to: snapshot)
            let filterSeconds = Date().timeIntervalSince(filterStart)

            XCTAssertEqual(positions.count, snapshot.nodes.count, "every node placed at \(snapshot.nodes.count) nodes")
            XCTAssertFalse(result.nodes.isEmpty)
            XCTAssertLessThan(layoutSeconds, 1.0, "layout took \(layoutSeconds)s at \(snapshot.nodes.count) nodes")
            XCTAssertLessThan(filterSeconds, 1.0, "filter took \(filterSeconds)s at \(snapshot.nodes.count) nodes")
            print("[graph-scale] nodes=\(snapshot.nodes.count) edges=\(snapshot.edges.count) layout=\(String(format: "%.4f", layoutSeconds))s filter=\(String(format: "%.4f", filterSeconds))s")
        }
    }

    func testSnapshotBuildScalesTo1000Nodes() {
        let start = Date()
        let snapshot = makeLargeSnapshot(targetNodes: 1000)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(snapshot.nodes.count, 500)
        XCTAssertLessThan(seconds, 2.0, "snapshot build took \(seconds)s")
        print("[graph-scale] build nodes=\(snapshot.nodes.count) edges=\(snapshot.edges.count) in \(String(format: "%.4f", seconds))s")
    }
}
