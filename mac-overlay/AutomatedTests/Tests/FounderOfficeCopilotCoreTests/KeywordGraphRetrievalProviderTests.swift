import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `KeywordGraphRetrievalProvider` - the V1 `RetrievalProvider`: keyword/exact
/// matching, entity matching, shallow UUID graph traversal (decision supersession chains),
/// temporal filtering, and project filtering. Confirms project isolation (no cross-project
/// contamination), temporal admissibility filtering applied BEFORE scoring, the pinned/
/// procedural split, supersession-chain traversal for changeReason/whenDecided intents, and
/// that historical evidence resolution only ever returns already-known references.
final class KeywordGraphRetrievalProviderTests: XCTestCase {
    private var memoryManager: MemoryManager!
    private var projectManager: ProjectManager!
    private var chatSessionManager: ChatSessionManager!
    private var provider: KeywordGraphRetrievalProvider!

    override func setUp() {
        super.setUp()
        memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        provider = KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager)
    }

    override func tearDown() {
        provider = nil
        chatSessionManager = nil
        projectManager = nil
        memoryManager = nil
        super.tearDown()
    }

    private func makeQuery(text: String = "", activeProjectID: UUID? = nil, intent: TemporalQueryClassifier.Intent = .unspecified) -> RetrievalQuery {
        RetrievalQuery(text: text, sessionID: UUID(), activeProjectID: activeProjectID, temporalIntent: intent)
    }

    // MARK: retrieveMemories

    func testRetrieveMemoriesExcludesForgottenAndPinnedEdges() {
        let subject = memoryManager.createEntity(MemoryEntity(kind: .self, name: "Shivam"))
        let active = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "prefers", literalValue: "dark mode", category: .preference, confidence: 0.9, sourceSessionID: UUID()))
        _ = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "prefers", literalValue: "light mode", category: .preference, confidence: 0.9, status: .forgotten, sourceSessionID: UUID()))
        _ = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "always", literalValue: "be concise", category: .preference, confidence: 0.9, sourceSessionID: UUID(), isPinned: true))

        let results = provider.retrieveMemories(matching: makeQuery(), limit: 10)
        XCTAssertEqual(results.map(\.value.id), [active.id])
    }

    func testRetrieveMemoriesAppliesTemporalAdmissibilityBeforeScoring() {
        let subject = memoryManager.createEntity(MemoryEntity(kind: .self, name: "Shivam"))
        let oldEdge = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "uses", literalValue: "MongoDB", category: .fact, confidence: 0.9, status: .superseded, sourceSessionID: UUID()))
        let newEdge = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "uses", literalValue: "Postgres", category: .fact, confidence: 0.9, status: .active, sourceSessionID: UUID(), supersedes: oldEdge.id))

        let currentResults = provider.retrieveMemories(matching: makeQuery(intent: .unspecified), limit: 10)
        XCTAssertEqual(Set(currentResults.map(\.value.id)), [newEdge.id], "unspecified/current intent must never surface superseded memory")

        let historicalResults = provider.retrieveMemories(matching: makeQuery(intent: .historical), limit: 10)
        XCTAssertEqual(Set(historicalResults.map(\.value.id)), [newEdge.id, oldEdge.id], "historical intent may surface superseded memory")
    }

    func testRetrieveMemoriesRespectsLimit() {
        let subject = memoryManager.createEntity(MemoryEntity(kind: .self, name: "Shivam"))
        for i in 0..<5 {
            _ = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "likes", literalValue: "thing \(i)", category: .preference, confidence: 0.9, sourceSessionID: UUID()))
        }
        let results = provider.retrieveMemories(matching: makeQuery(), limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: retrieveProceduralInstructions

    func testRetrieveProceduralInstructionsReturnsOnlyPinnedActiveEdges() {
        let subject = memoryManager.createEntity(MemoryEntity(kind: .self, name: "Shivam"))
        let pinned = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "always", literalValue: "be concise", category: .preference, confidence: 0.9, sourceSessionID: UUID(), isPinned: true))
        _ = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "prefers", literalValue: "dark mode", category: .preference, confidence: 0.9, sourceSessionID: UUID(), isPinned: false))
        _ = memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "always", literalValue: "old instruction", category: .preference, confidence: 0.9, status: .superseded, sourceSessionID: UUID(), isPinned: true))

        let results = provider.retrieveProceduralInstructions(matching: makeQuery(text: "completely unrelated query text"), limit: 10)
        XCTAssertEqual(results.map(\.value.id), [pinned.id], "pinned instructions must be returned regardless of keyword match, and superseded pinned edges must still be excluded")
    }

    // MARK: retrieveProjectItems - project isolation

    func testRetrieveProjectItemsReturnsEmptyWithNoActiveProject() {
        let results = provider.retrieveProjectItems(matching: makeQuery(activeProjectID: nil), limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testRetrieveProjectItemsNeverLeaksAcrossProjects() {
        let projectA = projectManager.createProject(Project(name: "Project A"))
        let projectB = projectManager.createProject(Project(name: "Project B"))
        let itemA = projectManager.createProjectItem(ProjectItem(projectID: projectA.id, kind: .task, name: "Task A", sourceSessionID: UUID()))
        _ = projectManager.createProjectItem(ProjectItem(projectID: projectB.id, kind: .task, name: "Task B", sourceSessionID: UUID()))

        let results = provider.retrieveProjectItems(matching: makeQuery(activeProjectID: projectA.id), limit: 10)
        XCTAssertEqual(results.map(\.value.id), [itemA.id])
    }

    func testRetrieveProjectItemsExcludesAbandonedUnlessChangeIntent() {
        let project = projectManager.createProject(Project(name: "Friday"))
        let active = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Live task", sourceSessionID: UUID()))
        let abandoned = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Dead task", status: .abandoned, sourceSessionID: UUID()))

        let unspecified = provider.retrieveProjectItems(matching: makeQuery(activeProjectID: project.id, intent: .unspecified), limit: 10)
        XCTAssertEqual(Set(unspecified.map(\.value.id)), [active.id])

        let changeReason = provider.retrieveProjectItems(matching: makeQuery(activeProjectID: project.id, intent: .changeReason), limit: 10)
        XCTAssertEqual(Set(changeReason.map(\.value.id)), [active.id, abandoned.id])
    }

    // MARK: retrieveDecisions - supersession chain traversal

    func testRetrieveDecisionsReturnsEmptyWithNoActiveProject() {
        XCTAssertTrue(provider.retrieveDecisions(matching: makeQuery(activeProjectID: nil), limit: 10).isEmpty)
    }

    func testRetrieveDecisionsSupersessionChainOnlySurfacedForChangeIntents() {
        let project = projectManager.createProject(Project(name: "Friday"))
        let original = projectManager.createDecision(Decision(projectID: project.id, statement: "Use MongoDB", sourceSessionID: UUID()))
        let replacement = projectManager.supersedeDecision(original.id, with: Decision(projectID: project.id, statement: "Use Postgres", sourceSessionID: UUID()))!

        let unspecified = provider.retrieveDecisions(matching: makeQuery(activeProjectID: project.id, intent: .unspecified), limit: 10)
        XCTAssertEqual(Set(unspecified.map(\.value.id)), [replacement.id], "unspecified intent must not surface the superseded decision")

        let whyChanged = provider.retrieveDecisions(matching: makeQuery(activeProjectID: project.id, intent: .changeReason), limit: 10)
        XCTAssertEqual(Set(whyChanged.map(\.value.id)), [replacement.id, original.id], "changeReason intent must walk the supersession chain")

        let whenDecided = provider.retrieveDecisions(matching: makeQuery(activeProjectID: project.id, intent: .whenDecided), limit: 10)
        XCTAssertEqual(Set(whenDecided.map(\.value.id)), [replacement.id, original.id])
    }

    func testRetrieveDecisionsNeverLeaksAcrossProjects() {
        let projectA = projectManager.createProject(Project(name: "Project A"))
        let projectB = projectManager.createProject(Project(name: "Project B"))
        let decisionA = projectManager.createDecision(Decision(projectID: projectA.id, statement: "Decision A", sourceSessionID: UUID()))
        _ = projectManager.createDecision(Decision(projectID: projectB.id, statement: "Decision B", sourceSessionID: UUID()))

        let results = provider.retrieveDecisions(matching: makeQuery(activeProjectID: projectA.id), limit: 10)
        XCTAssertEqual(results.map(\.value.id), [decisionA.id])
    }

    // MARK: retrieveProjectEvents

    func testRetrieveProjectEventsScopedToActiveProject() {
        let projectA = projectManager.createProject(Project(name: "Project A"))
        let projectB = projectManager.createProject(Project(name: "Project B"))
        let itemA = projectManager.createProjectItem(ProjectItem(projectID: projectA.id, kind: .task, name: "Task A", sourceSessionID: UUID()))
        let eventA = projectManager.createProjectEvent(ProjectEvent(projectID: projectA.id, relatedItemID: itemA.id, eventType: .itemCreated, description: "created A"))
        _ = projectManager.createProjectEvent(ProjectEvent(projectID: projectB.id, relatedItemID: UUID(), eventType: .itemCreated, description: "created B"))

        XCTAssertTrue(provider.retrieveProjectEvents(matching: makeQuery(activeProjectID: nil), limit: 10).isEmpty)
        let results = provider.retrieveProjectEvents(matching: makeQuery(activeProjectID: projectA.id), limit: 10)
        XCTAssertEqual(results.map(\.value.id), [eventA.id])
    }

    // MARK: retrieveEpisodes

    func testRetrieveEpisodesReturnsEmptyWithNoActiveProject() {
        XCTAssertTrue(provider.retrieveEpisodes(matching: makeQuery(activeProjectID: nil), limit: 10).isEmpty)
    }

    func testRetrieveEpisodesBuildsSummariesForLinkedSessionsOnly() {
        let project = projectManager.createProject(Project(name: "Friday"))
        let linkedSession = chatSessionManager.beginRecording()
        chatSessionManager.rename(linkedSession, to: "Linked Session")
        chatSessionManager.endRecording()
        let unlinkedSession = chatSessionManager.createSession(title: "Unlinked Session")
        projectManager.assignSession(linkedSession, to: project.id)

        let results = provider.retrieveEpisodes(matching: makeQuery(activeProjectID: project.id), limit: 10)
        XCTAssertEqual(results.map(\.value.sessionID), [linkedSession])
        XCTAssertFalse(results.map(\.value.sessionID).contains(unlinkedSession))
    }

    // MARK: retrieveHistoricalEvidence

    func testRetrieveHistoricalEvidenceResolvesOnlyKnownReferences() {
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.appendHeardDelta("the actual message text")
        let messageID = chatSessionManager.recordingSession!.messages.last!.id
        chatSessionManager.endRecording()

        let knownReference = EvidenceReference(sessionID: sessionID, messageID: messageID)
        let unknownReference = EvidenceReference(sessionID: UUID(), messageID: UUID())

        let results = provider.retrieveHistoricalEvidence(for: [knownReference, unknownReference], limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.renderedText, "the actual message text")
    }

    func testRetrieveHistoricalEvidenceRespectsLimit() {
        // Each begin/end cycle below lands in its OWN session (beginRecording() only reuses
        // the most recent session when it's still empty), which is fine here - the method
        // under test resolves each reference independently by (sessionID, messageID), never
        // assuming they share a session.
        var references: [EvidenceReference] = []
        for i in 0..<5 {
            let sessionID = chatSessionManager.beginRecording()
            chatSessionManager.appendHeardDelta("message \(i)")
            let messageID = chatSessionManager.recordingSession!.messages.last!.id
            chatSessionManager.endRecording()
            references.append(EvidenceReference(sessionID: sessionID, messageID: messageID))
        }

        let results = provider.retrieveHistoricalEvidence(for: references, limit: 2)
        XCTAssertEqual(results.count, 2)
    }
}
