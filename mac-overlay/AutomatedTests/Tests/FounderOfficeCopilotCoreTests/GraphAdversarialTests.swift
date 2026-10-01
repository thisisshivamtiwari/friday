import XCTest
@testable import FounderOfficeCopilotCore

/// Hostile inputs for the graph projection. Everything here is a shape the persisted model
/// PERMITS - cycles, chains, near-identical names, orphaned sessions - and the graph must stay
/// deterministic, terminate, and never invent or repair a relationship in any of them.
final class GraphAdversarialTests: XCTestCase {

    private func build(
        projects: [Project] = [], items: [ProjectItem] = [], decisions: [Decision] = [],
        links: [ProjectSessionLink] = [], people: [MemoryEntity] = [], sessions: [UUID: String] = [:]
    ) -> GraphSnapshot {
        GraphSnapshotBuilder.build(
            projects: projects, items: items, decisions: decisions, sessionLinks: links,
            people: people, sessionTitles: sessions, sessionDates: [:]
        )
    }

    // MARK: Cycles and chains

    /// `ProjectItem.relatedItemID` is a plain UUID with no constraint, so A -> B -> A is
    /// representable. The projection must not recurse, hang, or de-duplicate the two distinct
    /// directed edges into one.
    func testATwoItemCycleTerminatesAndKeepsBothDirectedEdges() {
        let project = Project(name: "Cyclic")
        let sessionID = UUID()
        var a = ProjectItem(projectID: project.id, kind: .experiment, name: "Experiment A", sourceSessionID: sessionID)
        var b = ProjectItem(projectID: project.id, kind: .result, name: "Result B", sourceSessionID: sessionID)
        a.relatedItemID = b.id
        b.relatedItemID = a.id

        let snapshot = build(projects: [project], items: [a, b], sessions: [sessionID: "Meeting"])
        let edges = snapshot.edges.filter { $0.kind == .itemRelatesToItem }
        XCTAssertEqual(edges.count, 2, "a cycle is two distinct directed edges, not one merged edge")
        XCTAssertTrue(snapshot.integrityIssues.isEmpty, "a cycle is legal in this model, not an integrity failure")
        XCTAssertEqual(GraphLayoutEngine.layout(snapshot).count, snapshot.nodes.count)
    }

    /// An item pointing at ITSELF - degenerate but representable.
    func testASelfReferencingItemProducesASelfEdgeWithoutCrashing() {
        let project = Project(name: "Self")
        let sessionID = UUID()
        var item = ProjectItem(projectID: project.id, kind: .task, name: "Recursive task", sourceSessionID: sessionID)
        item.relatedItemID = item.id

        let snapshot = build(projects: [project], items: [item], sessions: [sessionID: "Meeting"])
        let node = GraphNodeID(kind: .projectItem, entityID: item.id)
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .itemRelatesToItem && $0.source == node && $0.destination == node }.count, 1)
        XCTAssertNotNil(GraphLayoutEngine.layout(snapshot)[node])
    }

    /// A supersession CHAIN of four decisions: three edges, each normalised to newer -> older,
    /// with no duplicates even though every row records the link from both sides.
    func testALongSupersessionChainProducesOneEdgePerLink() {
        let project = Project(name: "Chain")
        let sessionID = UUID()
        var decisions = (0..<4).map { Decision(projectID: project.id, statement: "Revision \($0)", sourceSessionID: sessionID) }
        for index in 0..<3 {
            decisions[index + 1].supersedes = decisions[index].id
            decisions[index].supersededBy = decisions[index + 1].id
            decisions[index].status = .superseded
        }

        let snapshot = build(projects: [project], decisions: decisions, sessions: [sessionID: "Meeting"])
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .decisionSupersedesDecision }.count, 3)
    }

    // MARK: Near-identical names

    /// The exact hazard Phase 4.3's matcher guards against, seen from the graph's side: two
    /// items in ONE project whose names differ by a word must stay two nodes, and a decision
    /// linked to one must not gain an edge to the other.
    func testNearIdenticalItemNamesInOneProjectStayDistinctAndLinkPrecisely() {
        let project = Project(name: "Research")
        let sessionID = UUID()
        let short = ProjectItem(projectID: project.id, kind: .experiment, name: "Monte Carlo Dropout", sourceSessionID: sessionID)
        let long = ProjectItem(projectID: project.id, kind: .component, name: "Monte Carlo Dropout approach", sourceSessionID: sessionID)
        let decision = Decision(projectID: project.id, statement: "Keep MC dropout as the baseline", relatedItemID: short.id, sourceSessionID: sessionID)

        let snapshot = build(projects: [project], items: [short, long], decisions: [decision], sessions: [sessionID: "Meeting"])
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .projectItem }.count, 2)
        let links = snapshot.edges.filter { $0.kind == .decisionRelatesToItem }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.destination, GraphNodeID(kind: .projectItem, entityID: short.id),
                       "the edge must follow relatedItemID exactly, never the similarly-named neighbour")
    }

    // MARK: Sessions and orphans

    /// A session cited as an item's source but never LINKED to a project. It is still a real
    /// participant, so it must appear - but with no project edge and no invented association.
    func testASessionReferencedButNeverLinkedAppearsWithoutAProjectEdge() {
        let project = Project(name: "Research")
        let unlinked = UUID()
        let item = ProjectItem(projectID: project.id, kind: .task, name: "Task", sourceSessionID: unlinked)

        let snapshot = build(projects: [project], items: [item], sessions: [unlinked: "Unlinked session"])
        let node = GraphNodeID(kind: .session, entityID: unlinked)
        XCTAssertNotNil(snapshot.node(node))
        XCTAssertNil(snapshot.node(node)?.projectID, "an unlinked session must not be given a project")
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .projectLinkedToSession }.isEmpty)
        XCTAssertTrue(snapshot.edges.contains { $0.kind == .itemDiscussedInSession && $0.destination == node })
    }

    /// A link row naming a session the chat store no longer holds must not produce a phantom node.
    func testALinkToAMissingSessionProducesNoNode() {
        let project = Project(name: "Research")
        let snapshot = build(projects: [project], links: [ProjectSessionLink(sessionID: UUID(), projectID: project.id)])
        XCTAssertTrue(snapshot.nodes.filter { $0.kind == .session }.isEmpty)
        XCTAssertTrue(snapshot.edges.isEmpty)
    }

    func testProjectWithItemsButNoDecisionsHasNoDecisionEdges() {
        let project = Project(name: "Items only")
        let sessionID = UUID()
        let items = (0..<3).map { ProjectItem(projectID: project.id, kind: .task, name: "Task \($0)", sourceSessionID: sessionID) }
        let snapshot = build(projects: [project], items: items, sessions: [sessionID: "Meeting"])
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .projectHasDecision }.isEmpty)
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .projectContainsItem }.count, 3)
    }

    /// A decision naming a person the memory store no longer holds: no phantom person node, no
    /// edge, and - because the model does not treat this as corruption - no integrity issue.
    func testADecisionNamingAMissingPersonProducesNoPhantomNode() {
        let project = Project(name: "Research")
        let sessionID = UUID()
        let decision = Decision(projectID: project.id, statement: "Agreed", madeBy: [UUID()], sourceSessionID: sessionID)
        let snapshot = build(projects: [project], decisions: [decision], sessions: [sessionID: "Meeting"])
        XCTAssertTrue(snapshot.nodes.filter { $0.kind == .person }.isEmpty)
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .decisionMadeByPerson }.isEmpty)
    }

    // MARK: Real fixture regression
    //
    // The reference CleanFixture verbatim: 3 projects, 9 items, 6 decisions, ALL SIX with
    // relatedItemID == NULL. It is the strongest available regression against the graph ever
    // inventing a Decision -> ProjectItem edge, because these decisions and items share a great
    // deal of vocabulary - any similarity-based inference would light this fixture up.

    private func cleanFixtureSnapshot() -> GraphSnapshot {
        let research = Project(name: "Trustworthy Multi-Agent AI Research")
        let hotel = Project(name: "Hotel Revenue Forecasting System")
        let friday = Project(name: "Friday Personal AI Assistant")
        let s1 = UUID(), s2 = UUID(), s3 = UUID(), s4 = UUID()

        let items: [ProjectItem] = [
            ProjectItem(projectID: research.id, kind: .task, name: "Set up 5-agent gridworld search-and-rescue environment", status: .planned, sourceSessionID: s1),
            ProjectItem(projectID: research.id, kind: .task, name: "Generate initial calibration curves for MC dropout and conformal prediction", status: .planned, sourceSessionID: s1),
            ProjectItem(projectID: research.id, kind: .experiment, name: "Conformal prediction calibration gridworld runs", status: .completed, sourceSessionID: s2),
            ProjectItem(projectID: research.id, kind: .experiment, name: "MC dropout calibration evaluation", status: .completed, sourceSessionID: s2),
            ProjectItem(projectID: research.id, kind: .task, name: "Fix message payload normalization layer", status: .completed, sourceSessionID: s2),
            ProjectItem(projectID: research.id, kind: .task, name: "Test temperature scaling versus MC dropout", status: .planned, sourceSessionID: s2),
            ProjectItem(projectID: hotel.id, kind: .task, name: "Investigate rate-limiting fixes with exponential retry backoffs for rate shopper scraper", status: .planned, sourceSessionID: s3),
            ProjectItem(projectID: hotel.id, kind: .task, name: "Model transient and group demand separately for 30-to-90 day ADR prediction pipeline", status: .planned, sourceSessionID: s3),
            ProjectItem(projectID: friday.id, kind: .task, name: "Benchmark keychain-encrypted SQLite vs Secure Enclave decryption", status: .planned, sourceSessionID: s4),
        ]
        let decisions: [Decision] = [
            Decision(projectID: research.id, statement: "Test both Monte Carlo dropout and conformal prediction on a 5-agent gridworld environment", context: "Evaluating epistemic uncertainty bounds across multi-agent graph", sourceSessionID: s1),
            Decision(projectID: research.id, statement: "Rule out conformal prediction for message payload bounds", context: "Message payload bounds calibration", sourceSessionID: s2),
            Decision(projectID: research.id, statement: "Reject decentralized Bayesian optimization for updating agent confidence", context: "Agent confidence updates", sourceSessionID: s2),
            Decision(projectID: hotel.id, statement: "Reject third-party OTA aggregator fallback and continue relying on live competitor rate scraping", context: "Competitor pricing scraper pipeline", sourceSessionID: s3),
            Decision(projectID: hotel.id, statement: "Split transient and group demand into two separate sub-models for the demand pipeline", context: "30-to-90 day ADR prediction pipeline", sourceSessionID: s3),
            Decision(projectID: friday.id, statement: "Do not store raw meeting transcripts unencrypted in plain local files", context: "Local transcript storage security", sourceSessionID: s4),
        ]
        return build(
            projects: [research, hotel, friday], items: items, decisions: decisions,
            links: [ProjectSessionLink(sessionID: s1, projectID: research.id),
                    ProjectSessionLink(sessionID: s2, projectID: research.id),
                    ProjectSessionLink(sessionID: s3, projectID: hotel.id),
                    ProjectSessionLink(sessionID: s4, projectID: friday.id)],
            sessions: [s1: "Research — Meeting 1", s2: "Research — Meeting 2", s3: "Revenue — Meeting 1", s4: "Friday — Meeting 1"]
        )
    }

    func testCleanFixtureProjectsToTheExpectedCounts() {
        let snapshot = cleanFixtureSnapshot()
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .project }.count, 3)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .projectItem }.count, 9)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .decision }.count, 6)
        XCTAssertEqual(snapshot.nodes.filter { $0.kind == .session }.count, 4)
        XCTAssertTrue(snapshot.integrityIssues.isEmpty, "the reference fixture must be clean")
    }

    /// THE regression test for "never fabricate an edge", on the real corpus.
    func testCleanFixtureProducesZeroDecisionToItemEdgesBecauseEveryLinkIsNull() {
        let snapshot = cleanFixtureSnapshot()
        XCTAssertTrue(snapshot.edges.filter { $0.kind == .decisionRelatesToItem }.isEmpty,
                      "all six fixture decisions have relatedItemID == nil; any edge here is fabricated")
    }

    /// The same fixture with ONE real link added - the Phase 4.3 outcome - must show exactly one
    /// edge. This is what proves the graph will actually surface linking once it lands, rather
    /// than being blind to it.
    func testAddingOneRealLinkToTheFixtureProducesExactlyOneEdge() {
        let research = Project(name: "Trustworthy Multi-Agent AI Research")
        let sessionID = UUID()
        let item = ProjectItem(projectID: research.id, kind: .task, name: "Fix message payload normalization layer", status: .completed, sourceSessionID: sessionID)
        let linked = Decision(projectID: research.id, statement: "Rule out conformal prediction for message payload bounds", relatedItemID: item.id, sourceSessionID: sessionID)
        let unlinked = Decision(projectID: research.id, statement: "Reject decentralized Bayesian optimization", relatedItemID: nil, sourceSessionID: sessionID)

        let snapshot = build(projects: [research], items: [item], decisions: [linked, unlinked], sessions: [sessionID: "Meeting"])
        let edges = snapshot.edges.filter { $0.kind == .decisionRelatesToItem }
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?.source, GraphNodeID(kind: .decision, entityID: linked.id))
        XCTAssertEqual(edges.first?.destination, GraphNodeID(kind: .projectItem, entityID: item.id))
    }

    /// Filtering the real fixture to one project must not leak another project's work state -
    /// project isolation is structural everywhere else and must remain so on screen.
    func testFilteringTheRealFixtureToOneProjectLeaksNothing() {
        let snapshot = cleanFixtureSnapshot()
        for (projectID, name) in snapshot.projectNames {
            let filtered = GraphFilter.apply(
                GraphFilterCriteria(projectID: projectID, nodeKinds: [], lifecycleStatuses: [], searchText: ""),
                to: snapshot
            )
            for node in filtered.nodes where node.kind != .person {
                XCTAssertEqual(node.projectID, projectID, "\(node.title) leaked into \(name)")
            }
        }
    }
}
