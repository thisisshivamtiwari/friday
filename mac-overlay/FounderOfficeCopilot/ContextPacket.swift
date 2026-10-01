import Foundation

// MARK: - Temporal Status
/// The five states Phase 3.4 requires evidence to be classified into. Distinct from
/// `MemoryEdge.Status`/`Decision.Status`/`ProjectItem.Status` (which are STORAGE states) -
/// `TemporalStatus` is a RETRIEVAL-time classification derived from those storage states plus,
/// where nothing exists at all, `.unknown`. Never invented, never guessed - see
/// `isAdmissible(status:intent:)` for the hard rule that keeps superseded/invalidated
/// information from silently posing as current truth.
enum TemporalStatus: String, Equatable, CaseIterable {
    case current
    case historical
    case superseded
    case invalidated
    case unknown

    static func classify(memoryEdgeStatus: MemoryEdge.Status) -> TemporalStatus {
        switch memoryEdgeStatus {
        case .active: return .current
        case .superseded: return .superseded
        case .invalidated: return .invalidated
        // Forgotten edges are excluded from retrieval entirely upstream (RetrievalProvider
        // never even considers them) - classified here only as a defensive fallback so this
        // function is total, never as something retrieval is expected to actually return.
        case .forgotten: return .unknown
        }
    }

    static func classify(decisionStatus: Decision.Status) -> TemporalStatus {
        switch decisionStatus {
        case .active: return .current
        case .superseded: return .superseded
        }
    }

    /// ProjectItem's lifecycle statuses (proposed/planned/.../completed/abandoned) describe
    /// progression, not competing claims about truth the way Memory/Decision supersession
    /// does - there's no "old completed status" to contrast against. Only `.abandoned` maps
    /// to `.invalidated`, matching how ExtractionCoordinator's user-correction handling
    /// already uses `.abandoned` as its closest available "this was wrong" signal (see its own
    /// doc comment) - everything else is simply the item's current known lifecycle state.
    static func classify(projectItemStatus: ProjectItem.Status) -> TemporalStatus {
        projectItemStatus == .abandoned ? .invalidated : .current
    }

    /// The hard filter Stage 3 requires, applied BEFORE relevance scoring - whether evidence
    /// with this temporal status should even be considered for a question with this temporal
    /// intent.
    ///
    /// - CURRENT questions never receive superseded/invalidated evidence as current truth.
    /// - HISTORICAL questions may receive superseded evidence (that's what "what did I use
    ///   before" is asking for) but not invalidated (retracted-as-wrong) evidence, unless the
    ///   question is specifically about a change/decision (where investigating a past mistake
    ///   is plausible).
    /// - Unspecified intent defaults to the SAME safe behavior as `.current` - never surface
    ///   superseded/invalidated information unless the question clearly asked for history.
    static func isAdmissible(status: TemporalStatus, intent: TemporalQueryClassifier.Intent) -> Bool {
        switch status {
        case .current, .unknown:
            return true
        case .historical:
            return true
        case .superseded:
            switch intent {
            case .historical, .changeReason, .whenDecided: return true
            case .current, .unspecified: return false
            }
        case .invalidated:
            switch intent {
            case .changeReason, .whenDecided: return true
            case .current, .historical, .unspecified: return false
            }
        }
    }
}

// MARK: - Evidence Source
/// Which underlying record a piece of retrieved evidence came from - a plain UUID reference
/// tagged with its kind, never a Core Data relationship, matching every other cross-reference
/// in this codebase.
enum EvidenceSource: Equatable {
    case memoryEdge(UUID)
    case projectItem(UUID)
    case decision(UUID)
    case projectEvent(UUID)
    case chatMessage(sessionID: UUID, messageID: UUID)
    case episode(sessionID: UUID)
}

// MARK: - Provenance
/// "Where did this come from, and when" - deliberately minimal, resolved against
/// ChatSessionManager/ChatSessionStore live by whatever eventually renders it (a later phase),
/// never cached/duplicated here beyond the ids themselves.
struct Provenance: Equatable {
    let sourceSessionID: UUID?
    let sourceMessageIDs: [UUID]
    let timestamp: Date
}

// MARK: - Scored Evidence
/// One piece of retrieved evidence, generic over what kind of record it wraps
/// (`MemoryEdge`/`ProjectItem`/`Decision`/`ProjectEvent`/`ChatMessage`/`EpisodeSummary`).
/// `ContextPacket`'s arrays are each homogeneous (`[ScoredEvidence<MemoryEdge>]`, etc.), so
/// this stays a plain generic struct rather than needing a type-erased/protocol-based design.
///
/// `renderedText` is computed once by whatever constructs this (the RetrievalProvider, which
/// already needs a text rendering of each record for keyword-overlap scoring) - reused again
/// for context-budget character-cost estimation (Stage 6) rather than re-deriving it twice.
struct ScoredEvidence<Value: Equatable>: Equatable {
    let value: Value
    let source: EvidenceSource
    let score: Double
    let temporalStatus: TemporalStatus
    let provenance: Provenance
    let renderedText: String
}

// MARK: - Context Packet
/// The single, ephemeral, in-memory-only representation the future Context Engine assembles
/// and hands to AIEngineController - never persisted, never given a Core Data store, exactly
/// like `ExtractionCandidate` before it. `GeminiResponseGenerator` never sees this type at
/// all; AIEngineController is responsible for flattening it into the existing
/// `systemInstruction`/`context: [ChatMessage]` shapes (a later stage, not implemented here).
///
/// `proceduralInstructions` is deliberately a SEPARATE array from `relevantMemories` - pinned,
/// instruction-like MemoryEdges (`isPinned == true`) are kept apart from normal factual
/// memory, per Stage 5's explicit requirement, since they should be treated as
/// always-relevant behavioral instructions rather than topically-scored facts.
struct ContextPacket: Equatable {
    var currentConversation: [ChatMessage]
    var activeProjectID: UUID?
    var relevantMemories: [ScoredEvidence<MemoryEdge>]
    var relevantProjectItems: [ScoredEvidence<ProjectItem>]
    var relevantDecisions: [ScoredEvidence<Decision>]
    var relevantEpisodes: [ScoredEvidence<EpisodeSummary>]
    var historicalEvidence: [ScoredEvidence<ChatMessage>]
    var proceduralInstructions: [ScoredEvidence<MemoryEdge>]
    /// A flattened lookup from an evidence VALUE's own id (MemoryEdge.id, ProjectItem.id,
    /// Decision.id, ChatMessage.id, ...) to its Provenance - a convenience index for whatever
    /// eventually needs to cite sources without re-scanning every typed array above.
    var provenanceIndex: [UUID: Provenance]

    static let empty = ContextPacket(
        currentConversation: [],
        activeProjectID: nil,
        relevantMemories: [],
        relevantProjectItems: [],
        relevantDecisions: [],
        relevantEpisodes: [],
        historicalEvidence: [],
        proceduralInstructions: [],
        provenanceIndex: [:]
    )
}
