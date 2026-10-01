import Foundation

// MARK: - Retrieval Query
/// Everything a `RetrievalProvider` needs to answer "what's relevant to THIS question right
/// now" - assembled once (by the future Context Engine) and passed to every retrieval method,
/// rather than each method re-deriving the same context independently.
struct RetrievalQuery: Equatable {
    let text: String
    let sessionID: UUID
    let activeProjectID: UUID?
    let temporalIntent: TemporalQueryClassifier.Intent
    let now: Date

    init(text: String, sessionID: UUID, activeProjectID: UUID?, temporalIntent: TemporalQueryClassifier.Intent, now: Date = Date()) {
        self.text = text
        self.sessionID = sessionID
        self.activeProjectID = activeProjectID
        self.temporalIntent = temporalIntent
        self.now = now
    }
}

// MARK: - Evidence Reference
/// A pointer to one specific ChatMessage, used to request historical raw evidence by id -
/// deliberately NOT a search query. Historical evidence retrieval only ever resolves
/// REFERENCES already collected from other evidence's `sourceMessageIDs` fields; it never
/// independently scans conversation history looking for relevant messages.
struct EvidenceReference: Equatable, Hashable {
    let sessionID: UUID
    let messageID: UUID
}

// MARK: - Retrieval Provider
/// The abstraction the future Context Engine depends on, never a concrete database - exactly
/// what the approved design calls for so a V2 (embeddings/vector) implementation could be
/// swapped in later without changing any caller. The V1 implementation
/// (`KeywordGraphRetrievalProvider`) uses ONLY keyword/exact matching, entity matching,
/// shallow UUID graph traversal, temporal filtering, and project filtering - no embeddings, no
/// vector database, no network calls of any kind.
///
/// Every method is independently boundable (`limit`) and independently callable - the Context
/// Engine decides which sources to query and how to combine them; no single method call
/// implies or triggers another.
protocol RetrievalProvider {
    /// Non-pinned MemoryEdges - factual/preference/goal/relationship memory, scored against
    /// `query`. Never includes `.forgotten` edges; temporal admissibility (see
    /// `TemporalStatus.isAdmissible`) is applied before scoring, not after.
    func retrieveMemories(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<MemoryEdge>]

    /// Pinned MemoryEdges ONLY - kept separate from `retrieveMemories` per Stage 5's explicit
    /// requirement that procedural/instruction-like memory never gets topically filtered out
    /// the way normal facts do.
    func retrieveProceduralInstructions(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<MemoryEdge>]

    func retrieveProjectItems(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<ProjectItem>]

    /// When `query.temporalIntent` is `.changeReason`/`.whenDecided`, implementations are
    /// expected to also walk the `supersedes` chain from the current active decision backward,
    /// surfacing prior superseded decisions in the SAME project/context - "why did we change"
    /// needs the history, not just the current answer.
    func retrieveDecisions(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<Decision>]

    func retrieveProjectEvents(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<ProjectEvent>]

    /// Episode projections (see `EpisodeSummary`) for sessions linked to `query.activeProjectID`
    /// - built on demand from already-loaded manager state, never persisted.
    func retrieveEpisodes(matching query: RetrievalQuery, limit: Int) -> [ScoredEvidence<EpisodeSummary>]

    /// Resolves specific, ALREADY-KNOWN message references into their verbatim text - never an
    /// independent search over conversation history. `references` is expected to be small
    /// (collected from other evidence's provenance in the same retrieval pass).
    func retrieveHistoricalEvidence(for references: [EvidenceReference], limit: Int) -> [ScoredEvidence<ChatMessage>]
}
