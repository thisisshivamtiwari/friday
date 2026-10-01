import Foundation

// MARK: - Context Engine Configuration
/// Per-source result caps and the shared evidence character budget - internal, configurable
/// properties (not hard-coded constants baked into the algorithm), matching the same
/// discipline already established for `ExtractionCoordinator`'s tuning knobs. No settings UI
/// exists for these; they're `var` specifically so tests (and any future tuning pass) can
/// override them.
struct ContextEngineConfiguration {
    var memoryLimit: Int = 8
    var proceduralLimit: Int = 5
    var projectItemLimit: Int = 8
    var decisionLimit: Int = 6
    var episodeLimit: Int = 3
    var projectEventLimit: Int = 5
    var historicalEvidenceLimit: Int = 6
    /// A character-count budget for the COMPETITIVE evidence pool (memories/items/decisions/
    /// episodes/historical evidence) - deliberately NOT a token count: this project has no
    /// tokenizer dependency, and a fabricated "token count" would be less honest than a plain
    /// character count. Current conversation and pinned procedural instructions are NOT
    /// counted against this budget - both are protected (see `ContextEngine.buildContextPacket`).
    var maxEvidenceCharacterBudget: Int = 6000

    init(
        memoryLimit: Int = 8,
        proceduralLimit: Int = 5,
        projectItemLimit: Int = 8,
        decisionLimit: Int = 6,
        episodeLimit: Int = 3,
        projectEventLimit: Int = 5,
        historicalEvidenceLimit: Int = 6,
        maxEvidenceCharacterBudget: Int = 6000
    ) {
        self.memoryLimit = memoryLimit
        self.proceduralLimit = proceduralLimit
        self.projectItemLimit = projectItemLimit
        self.decisionLimit = decisionLimit
        self.episodeLimit = episodeLimit
        self.projectEventLimit = projectEventLimit
        self.historicalEvidenceLimit = historicalEvidenceLimit
        self.maxEvidenceCharacterBudget = maxEvidenceCharacterBudget
    }
}

// MARK: - Context Engine
/// Assembles a `ContextPacket` for a given question - the READ PATH's top-level orchestrator,
/// sitting between `AIEngineController` (a later, not-yet-implemented integration stage) and
/// `RetrievalProvider`. Depends only on the `RetrievalProvider` PROTOCOL (never a concrete
/// database), `ChatSessionManager` (read-only, for the already-protected `responseContext()`
/// and session lookups), and `ProjectManager` (read-only, for `ProjectResolution`).
///
/// `GeminiResponseGenerator` never sees this type, `ContextPacket`, or any manager - that
/// boundary is preserved by construction: nothing in this file imports or references
/// `GeminiResponseGenerator` at all.
///
/// Performance: every step here operates on already-loaded in-memory manager state
/// (`memoryManager.edges`, `projectManager.items(forProject:)`, etc.) via simple O(n)
/// filter/map/sort over realistic personal-scale data, plus targeted lookups by already-known
/// id for historical evidence - never a full conversation-history scan, never a fresh Core
/// Data query. `currentConversation` is read via the EXISTING, already-bounded
/// `ChatSessionManager.responseContext()`, untouched - this does not reintroduce the long-chat
/// rendering/performance issue that was previously diagnosed and fixed.
final class ContextEngine {
    private let retrievalProvider: RetrievalProvider
    private let chatSessionManager: ChatSessionManager
    private let projectManager: ProjectManager
    var configuration: ContextEngineConfiguration

    init(
        retrievalProvider: RetrievalProvider,
        chatSessionManager: ChatSessionManager,
        projectManager: ProjectManager,
        configuration: ContextEngineConfiguration = ContextEngineConfiguration()
    ) {
        self.retrievalProvider = retrievalProvider
        self.chatSessionManager = chatSessionManager
        self.projectManager = projectManager
        self.configuration = configuration
    }

    /// The full read-path pipeline for one question: resolve the active project (via the
    /// SAME shared `ProjectResolution` the write path uses) -> classify temporal intent ->
    /// retrieve independently from every source -> collect provenance references -> resolve
    /// historical evidence for exactly those references -> apply the context budget -> return
    /// the assembled packet.
    func buildContextPacket(forQuestion questionText: String, sessionID: UUID, now: Date = Date()) -> ContextPacket {
        let mentionedProject = ProjectResolution.detectMentionedProjectName(in: questionText, projectManager: projectManager)
        let activeProjectID = ProjectResolution.resolve(
            sessionID: sessionID,
            mentionedProjectName: mentionedProject,
            probeTexts: [questionText],
            projectManager: projectManager
        )
        let temporalIntent = TemporalQueryClassifier.classify(questionText)
        let query = RetrievalQuery(text: questionText, sessionID: sessionID, activeProjectID: activeProjectID, temporalIntent: temporalIntent, now: now)

        let rawMemories = retrievalProvider.retrieveMemories(matching: query, limit: configuration.memoryLimit)
        let procedural = retrievalProvider.retrieveProceduralInstructions(matching: query, limit: configuration.proceduralLimit)
        let rawProjectItems = retrievalProvider.retrieveProjectItems(matching: query, limit: configuration.projectItemLimit)
        let decisions = retrievalProvider.retrieveDecisions(matching: query, limit: configuration.decisionLimit)
        let episodes = retrievalProvider.retrieveEpisodes(matching: query, limit: configuration.episodeLimit)
        // ProjectEvents aren't a top-level ContextPacket field per the approved tree - they're
        // retrieved only to fold their provenance into historical-evidence resolution below.
        let projectEvents = retrievalProvider.retrieveProjectEvents(matching: query, limit: configuration.projectEventLimit)

        // Cross-layer conflict resolution runs AFTER retrieval/temporal admissibility/scoring
        // and BEFORE provenance collection/budget, per the approved pipeline order - see
        // CrossLayerConflictResolver's own doc comment for what it does and doesn't attempt.
        // Decisions are never filtered by this step (they're never the losing side).
        let resolved = CrossLayerConflictResolver.resolve(
            memories: rawMemories,
            projectItems: rawProjectItems,
            decisions: decisions,
            intent: temporalIntent
        )
        let memories = resolved.memories
        let projectItems = resolved.projectItems

        let references = Self.collectReferences(memories: memories, projectItems: projectItems, decisions: decisions, projectEvents: projectEvents)
        let historicalEvidence = retrievalProvider.retrieveHistoricalEvidence(for: references, limit: configuration.historicalEvidenceLimit)

        // Stage 6: rank the COMPETITIVE evidence pool together and greedily include by
        // character cost until the budget is reached - never a fixed always-include-N
        // approach. Current conversation and pinned procedural instructions are excluded from
        // this competition entirely (both protected, see below).
        let budgeted = Self.applyBudget(
            memories: memories,
            projectItems: projectItems,
            decisions: decisions,
            episodes: episodes,
            historicalEvidence: historicalEvidence,
            characterBudget: configuration.maxEvidenceCharacterBudget
        )

        var provenanceIndex: [UUID: Provenance] = [:]
        for e in budgeted.memories { provenanceIndex[e.value.id] = e.provenance }
        for e in budgeted.projectItems { provenanceIndex[e.value.id] = e.provenance }
        for e in budgeted.decisions { provenanceIndex[e.value.id] = e.provenance }
        for e in procedural { provenanceIndex[e.value.id] = e.provenance }
        for e in budgeted.historicalEvidence { provenanceIndex[e.value.id] = e.provenance }
        // EpisodeSummary has no `id` of its own - `sessionID` is its natural, already-UUID
        // identity, and (being generated independently via UUID()) carries the same
        // effectively-zero collision risk as any other UUID already used as a dictionary key
        // in this codebase, not a new risk introduced here.
        for e in budgeted.episodes { provenanceIndex[e.value.sessionID] = e.provenance }

        // Protected, per Stage 6 - untouched, exactly what already exists and was already
        // fixed for long-chat correctness.
        let currentConversation = chatSessionManager.responseContext().orderedMessages

        return ContextPacket(
            currentConversation: currentConversation,
            activeProjectID: activeProjectID,
            relevantMemories: budgeted.memories,
            relevantProjectItems: budgeted.projectItems,
            relevantDecisions: budgeted.decisions,
            relevantEpisodes: budgeted.episodes,
            historicalEvidence: budgeted.historicalEvidence,
            proceduralInstructions: procedural,
            provenanceIndex: provenanceIndex
        )
    }

    /// Gathers (sessionID, messageID) references from every OTHER evidence type's own
    /// provenance - "historical raw evidence must only fetch messages using already-known
    /// sourceMessageIDs", never an independent search. De-duplicated, order-preserving.
    private static func collectReferences(
        memories: [ScoredEvidence<MemoryEdge>],
        projectItems: [ScoredEvidence<ProjectItem>],
        decisions: [ScoredEvidence<Decision>],
        projectEvents: [ScoredEvidence<ProjectEvent>]
    ) -> [EvidenceReference] {
        var seen = Set<EvidenceReference>()
        var ordered: [EvidenceReference] = []
        func absorb<T>(_ items: [ScoredEvidence<T>]) {
            for item in items {
                guard let sessionID = item.provenance.sourceSessionID else { continue }
                for messageID in item.provenance.sourceMessageIDs {
                    let reference = EvidenceReference(sessionID: sessionID, messageID: messageID)
                    if seen.insert(reference).inserted {
                        ordered.append(reference)
                    }
                }
            }
        }
        absorb(memories)
        absorb(projectItems)
        absorb(decisions)
        absorb(projectEvents)
        return ordered
    }

    private struct BudgetResult {
        let memories: [ScoredEvidence<MemoryEdge>]
        let projectItems: [ScoredEvidence<ProjectItem>]
        let decisions: [ScoredEvidence<Decision>]
        let episodes: [ScoredEvidence<EpisodeSummary>]
        let historicalEvidence: [ScoredEvidence<ChatMessage>]
    }

    /// Ranks every candidate across ALL competitive evidence types together by score, then
    /// greedily includes highest-scored-first until `characterBudget` (measured via each
    /// item's already-computed `renderedText.count`) is exhausted. A `kind`+`index` tag lets
    /// this stay simple (no type erasure/protocol needed) while still comparing heterogeneous
    /// `ScoredEvidence<T>` arrays against one shared budget.
    private static func applyBudget(
        memories: [ScoredEvidence<MemoryEdge>],
        projectItems: [ScoredEvidence<ProjectItem>],
        decisions: [ScoredEvidence<Decision>],
        episodes: [ScoredEvidence<EpisodeSummary>],
        historicalEvidence: [ScoredEvidence<ChatMessage>],
        characterBudget: Int
    ) -> BudgetResult {
        enum Kind { case memory, projectItem, decision, episode, historical }
        struct Candidate { let kind: Kind; let index: Int; let score: Double; let cost: Int }

        var candidates: [Candidate] = []
        memories.enumerated().forEach { candidates.append(Candidate(kind: .memory, index: $0.offset, score: $0.element.score, cost: $0.element.renderedText.count)) }
        projectItems.enumerated().forEach { candidates.append(Candidate(kind: .projectItem, index: $0.offset, score: $0.element.score, cost: $0.element.renderedText.count)) }
        decisions.enumerated().forEach { candidates.append(Candidate(kind: .decision, index: $0.offset, score: $0.element.score, cost: $0.element.renderedText.count)) }
        episodes.enumerated().forEach { candidates.append(Candidate(kind: .episode, index: $0.offset, score: $0.element.score, cost: $0.element.renderedText.count)) }
        historicalEvidence.enumerated().forEach { candidates.append(Candidate(kind: .historical, index: $0.offset, score: $0.element.score, cost: $0.element.renderedText.count)) }

        var remaining = characterBudget
        var includedMemory = Set<Int>()
        var includedProjectItem = Set<Int>()
        var includedDecision = Set<Int>()
        var includedEpisode = Set<Int>()
        var includedHistorical = Set<Int>()

        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard candidate.cost <= remaining else { continue }
            switch candidate.kind {
            case .memory: includedMemory.insert(candidate.index)
            case .projectItem: includedProjectItem.insert(candidate.index)
            case .decision: includedDecision.insert(candidate.index)
            case .episode: includedEpisode.insert(candidate.index)
            case .historical: includedHistorical.insert(candidate.index)
            }
            remaining -= candidate.cost
        }

        func filterSort<T>(_ items: [ScoredEvidence<T>], _ included: Set<Int>) -> [ScoredEvidence<T>] {
            items.enumerated().filter { included.contains($0.offset) }.map(\.element).sorted { $0.score > $1.score }
        }

        return BudgetResult(
            memories: filterSort(memories, includedMemory),
            projectItems: filterSort(projectItems, includedProjectItem),
            decisions: filterSort(decisions, includedDecision),
            episodes: filterSort(episodes, includedEpisode),
            historicalEvidence: filterSort(historicalEvidence, includedHistorical)
        )
    }
}
