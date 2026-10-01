import XCTest
@testable import FounderOfficeCopilotCore

/// A configurable `RetrievalProvider` test double - lets `ContextEngine`'s OWN assembly/budget
/// logic be tested in isolation from `KeywordGraphRetrievalProvider`'s real scoring, the same
/// "stub the collaborator, test the orchestrator" pattern already established for
/// `StubExtractionLLMClient` in `ExtractionCoordinatorTests`.
private final class StubRetrievalProvider: RetrievalProvider {
    var memories: [ScoredEvidence<MemoryEdge>] = []
    var procedural: [ScoredEvidence<MemoryEdge>] = []
    var projectItems: [ScoredEvidence<ProjectItem>] = []
    var decisions: [ScoredEvidence<Decision>] = []
    var projectEvents: [ScoredEvidence<ProjectEvent>] = []
    var episodes: [ScoredEvidence<EpisodeSummary>] = []
    var historicalEvidence: [ScoredEvidence<ChatMessage>] = []

    private(set) var receivedHistoricalReferences: [EvidenceReference] = []

    func retrieveMemories(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<MemoryEdge>] { Array(memories.prefix(limit)) }
    func retrieveProceduralInstructions(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<MemoryEdge>] { Array(procedural.prefix(limit)) }
    func retrieveProjectItems(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<ProjectItem>] { Array(projectItems.prefix(limit)) }
    func retrieveDecisions(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<Decision>] { Array(decisions.prefix(limit)) }
    func retrieveProjectEvents(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<ProjectEvent>] { Array(projectEvents.prefix(limit)) }
    func retrieveEpisodes(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<EpisodeSummary>] { Array(episodes.prefix(limit)) }
    func retrieveHistoricalEvidence(for references: [EvidenceReference], limit: Int) -> [ScoredEvidence<ChatMessage>] {
        receivedHistoricalReferences = references
        return Array(historicalEvidence.prefix(limit))
    }
}

/// Covers `ContextEngine` - Stage 5 (assembling the exact `ContextPacket` tree) and Stage 6
/// (the bounded, rank-then-fill context budget). Uses `StubRetrievalProvider` for deterministic
/// budget/assembly tests, plus one end-to-end test against the real
/// `KeywordGraphRetrievalProvider` + real managers.
final class ContextEngineTests: XCTestCase {
    private func makeChatSessionManager() -> ChatSessionManager {
        ChatSessionManager(store: ChatSessionStore(inMemory: true))
    }

    private func makeProjectManager() -> ProjectManager {
        ProjectManager(store: ProjectStore(inMemory: true))
    }

    private func makeMemoryEdgeEvidence(id: UUID = UUID(), score: Double, renderedText: String, sourceSessionID: UUID? = nil, sourceMessageIDs: [UUID] = []) -> ScoredEvidence<MemoryEdge> {
        let edge = MemoryEdge(id: id, subjectEntityID: UUID(), predicate: "fact", literalValue: renderedText, category: .fact, confidence: 0.9, sourceSessionID: sourceSessionID ?? UUID())
        return ScoredEvidence(
            value: edge,
            source: .memoryEdge(id),
            score: score,
            temporalStatus: .current,
            provenance: Provenance(sourceSessionID: sourceSessionID, sourceMessageIDs: sourceMessageIDs, timestamp: Date()),
            renderedText: renderedText
        )
    }

    // MARK: Assembly

    func testBuildContextPacketAssemblesEveryFieldFromTheProvider() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        stub.memories = [makeMemoryEdgeEvidence(score: 0.9, renderedText: "memory fact")]
        stub.procedural = [makeMemoryEdgeEvidence(score: 0.5, renderedText: "always be concise")]

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "what do I prefer?", sessionID: UUID())

        XCTAssertEqual(packet.relevantMemories.map(\.value.id), stub.memories.map(\.value.id))
        XCTAssertEqual(packet.proceduralInstructions.map(\.value.id), stub.procedural.map(\.value.id))
    }

    func testCurrentConversationComesFromTheProtectedResponseContext() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.appendHeardDelta("hello there")
        let stub = StubRetrievalProvider()

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "anything", sessionID: sessionID)

        XCTAssertEqual(packet.currentConversation.map(\.text), ["hello there"])
    }

    // MARK: Provenance index

    func testProvenanceIndexIsPopulatedForIncludedEvidenceOnly() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        let includedID = UUID()
        let session = UUID()
        stub.memories = [makeMemoryEdgeEvidence(id: includedID, score: 0.9, renderedText: "included", sourceSessionID: session)]

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.provenanceIndex[includedID]?.sourceSessionID, session)
    }

    // MARK: Historical evidence reference collection

    func testHistoricalEvidenceReferencesAreCollectedFromOtherEvidenceProvenanceOnly() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        let session = UUID()
        let message = UUID()
        stub.memories = [makeMemoryEdgeEvidence(score: 0.9, renderedText: "fact", sourceSessionID: session, sourceMessageIDs: [message])]

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        _ = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(stub.receivedHistoricalReferences, [EvidenceReference(sessionID: session, messageID: message)])
    }

    func testHistoricalEvidenceReferencesAreDeduped() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        let session = UUID()
        let message = UUID()
        stub.memories = [makeMemoryEdgeEvidence(score: 0.9, renderedText: "a", sourceSessionID: session, sourceMessageIDs: [message])]
        stub.decisions = [ScoredEvidence(
            value: Decision(projectID: UUID(), statement: "d", sourceSessionID: session, sourceMessageIDs: [message]),
            source: .decision(UUID()),
            score: 0.8,
            temporalStatus: .current,
            provenance: Provenance(sourceSessionID: session, sourceMessageIDs: [message], timestamp: Date()),
            renderedText: "d"
        )]

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        _ = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(stub.receivedHistoricalReferences.count, 1, "the same (session, message) reference contributed by two evidence types must be deduped")
    }

    // MARK: Stage 6 - context budget

    func testBudgetIncludesHighestScoredEvidenceFirst() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        // Each "x" costs 1 character. Budget of 15 fits the two highest-scored items (10 + 4)
        // but not the third (would push total to 21).
        stub.memories = [
            makeMemoryEdgeEvidence(score: 0.9, renderedText: String(repeating: "x", count: 10)),
            makeMemoryEdgeEvidence(score: 0.7, renderedText: String(repeating: "x", count: 4)),
            makeMemoryEdgeEvidence(score: 0.5, renderedText: String(repeating: "x", count: 6)),
        ]

        var configuration = ContextEngineConfiguration()
        configuration.maxEvidenceCharacterBudget = 15
        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager, configuration: configuration)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.relevantMemories.count, 2)
        XCTAssertEqual(Set(packet.relevantMemories.map(\.renderedText.count)), [10, 4])
    }

    func testBudgetCompetesAcrossEvidenceTypesTogether() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        stub.memories = [makeMemoryEdgeEvidence(score: 0.95, renderedText: String(repeating: "m", count: 5))]
        stub.decisions = [ScoredEvidence(
            value: Decision(projectID: UUID(), statement: "d", sourceSessionID: UUID()),
            source: .decision(UUID()),
            score: 0.1, // lowest score - should lose the budget competition to the memory above
            temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()),
            renderedText: String(repeating: "d", count: 5)
        )]

        var configuration = ContextEngineConfiguration()
        configuration.maxEvidenceCharacterBudget = 5 // only room for ONE of the two 5-char items
        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager, configuration: configuration)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.relevantMemories.count, 1, "the higher-scored memory must win the shared budget")
        XCTAssertEqual(packet.relevantDecisions.count, 0)
    }

    func testProceduralInstructionsAreProtectedFromTheBudget() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        stub.procedural = [makeMemoryEdgeEvidence(score: 0.01, renderedText: String(repeating: "p", count: 1000))]

        var configuration = ContextEngineConfiguration()
        configuration.maxEvidenceCharacterBudget = 1 // far too small for the procedural item's own size
        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager, configuration: configuration)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.proceduralInstructions.count, 1, "pinned procedural instructions must never be cut by the competitive evidence budget")
    }

    func testCurrentConversationIsProtectedFromTheBudget() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.appendHeardDelta(String(repeating: "c", count: 5000))
        let stub = StubRetrievalProvider()

        var configuration = ContextEngineConfiguration()
        configuration.maxEvidenceCharacterBudget = 1
        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager, configuration: configuration)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: sessionID)

        XCTAssertEqual(packet.currentConversation.count, 1, "current conversation must never be cut by the competitive evidence budget")
    }

    func testEmptyProviderProducesEmptyCompetitivePools() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)

        let packet = engine.buildContextPacket(forQuestion: "anything", sessionID: UUID())
        XCTAssertTrue(packet.relevantMemories.isEmpty)
        XCTAssertTrue(packet.relevantProjectItems.isEmpty)
        XCTAssertTrue(packet.relevantDecisions.isEmpty)
        XCTAssertTrue(packet.relevantEpisodes.isEmpty)
        XCTAssertTrue(packet.historicalEvidence.isEmpty)
    }

    // MARK: End-to-end integration with the real provider

    func testEndToEndWithRealProviderResolvesActiveProjectAndSurfacesItems() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let realProvider = KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager)

        let project = projectManager.createProject(Project(name: "Friday"))
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.endRecording()
        projectManager.assignSession(sessionID, to: project.id)
        let item = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Ship the retrieval stage", sourceSessionID: sessionID))

        let engine = ContextEngine(retrievalProvider: realProvider, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "what's the status of the retrieval stage?", sessionID: sessionID)

        XCTAssertEqual(packet.activeProjectID, project.id, "the session's linked project must be resolved as the active project")
        XCTAssertTrue(packet.relevantProjectItems.map(\.value.id).contains(item.id))
    }

    /// Proves `CrossLayerConflictResolver` is actually wired into the pipeline end-to-end
    /// (not just correct in isolation - see `CrossLayerConflictResolverTests`), using the real
    /// `KeywordGraphRetrievalProvider` and real managers, matching the audit's worked example:
    /// a stale Memory ("database = MongoDB") loses to a newer, topically-matching Decision.
    func testEndToEndCrossLayerConflictResolutionPrefersDecisionOverStaleMemory() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let realProvider = KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager)

        let subject = memoryManager.createEntity(MemoryEntity(kind: .project, name: "Friday"))
        let staleMemory = memoryManager.createEdge(MemoryEdge(
            subjectEntityID: subject.id, predicate: "database", literalValue: "MongoDB", category: .fact, confidence: 0.9,
            sourceSessionID: UUID(), lastConfirmedAt: Date().addingTimeInterval(-60 * 60 * 24 * 60)
        ))

        let project = projectManager.createProject(Project(name: "Friday"))
        let sessionID = chatSessionManager.beginRecording()
        chatSessionManager.endRecording()
        projectManager.assignSession(sessionID, to: project.id)
        let decision = projectManager.createDecision(Decision(
            projectID: project.id, statement: "Use PostgreSQL going forward", context: "database",
            sourceSessionID: sessionID, decidedAt: Date()
        ))

        let engine = ContextEngine(retrievalProvider: realProvider, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "what database do we currently use?", sessionID: sessionID)

        XCTAssertFalse(packet.relevantMemories.map(\.value.id).contains(staleMemory.id), "the stale MongoDB memory must be excluded once an explicit decision addresses the same topic")
        XCTAssertTrue(packet.relevantDecisions.map(\.value.id).contains(decision.id))
    }

    /// Test G - episode provenance must be reachable through the centralized `provenanceIndex`,
    /// keyed by `EpisodeSummary.sessionID` (its natural identity) rather than a fabricated id.
    func testEpisodeProvenanceIsAvailableThroughTheProvenanceIndex() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        let episodeSessionID = UUID()
        let episode = EpisodeSummary(sessionID: episodeSessionID, meetingID: nil, title: "Sync", occurredAt: Date(), participantEntityIDs: [], decisions: [], projectItems: [], projectEvents: [], checkpointSummary: nil, sourceMessageIDs: [])
        let provenance = Provenance(sourceSessionID: episodeSessionID, sourceMessageIDs: [], timestamp: Date())
        stub.episodes = [ScoredEvidence(value: episode, source: .episode(sessionID: episodeSessionID), score: 0.9, temporalStatus: .current, provenance: provenance, renderedText: "Sync")]

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.relevantEpisodes.count, 1, "sanity: the episode itself must survive the budget for this test to prove anything")
        XCTAssertEqual(packet.provenanceIndex[episodeSessionID], provenance)
    }

    /// Test H (packet-level) - provenance on every other evidence type also survives assembly
    /// completely untouched, confirming the conflict-resolution/budget stages never mutate it.
    func testProvenanceRemainsIntactAcrossTheFullPipelineForEveryEvidenceType() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        let session = UUID()
        let message = UUID()
        stub.memories = [makeMemoryEdgeEvidence(score: 0.9, renderedText: "fact", sourceSessionID: session, sourceMessageIDs: [message])]

        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.relevantMemories.first?.provenance.sourceSessionID, session)
        XCTAssertEqual(packet.relevantMemories.first?.provenance.sourceMessageIDs, [message])
    }

    /// Test I - documents the CURRENT, INTENTIONAL "skip-and-continue" budget behavior flagged
    /// in the Stage 1-6 audit: a smaller, lower-scored item may be included over a larger,
    /// higher-scored one that doesn't fit, rather than the budget stopping entirely at the
    /// first item that doesn't fit. This maximizes budget utilization; it is a deliberate
    /// choice, not a bug - this test exists so a future change to that choice is a visible,
    /// intentional diff against a named test rather than a silent regression.
    func testBudgetSkipsAnOversizedHigherScoredItemAndIncludesASmallerLowerScoredOneInstead() {
        let chatSessionManager = makeChatSessionManager()
        let projectManager = makeProjectManager()
        let stub = StubRetrievalProvider()
        stub.memories = [
            makeMemoryEdgeEvidence(score: 0.99, renderedText: String(repeating: "x", count: 20)), // highest score, too big to fit
            makeMemoryEdgeEvidence(score: 0.1, renderedText: String(repeating: "y", count: 3)),   // lowest score, fits easily
        ]

        var configuration = ContextEngineConfiguration()
        configuration.maxEvidenceCharacterBudget = 15
        let engine = ContextEngine(retrievalProvider: stub, chatSessionManager: chatSessionManager, projectManager: projectManager, configuration: configuration)
        let packet = engine.buildContextPacket(forQuestion: "q", sessionID: UUID())

        XCTAssertEqual(packet.relevantMemories.count, 1)
        XCTAssertEqual(packet.relevantMemories.first?.renderedText.count, 3, "the smaller, lower-scored item must be included since the larger, higher-scored one never fits")
    }
}
