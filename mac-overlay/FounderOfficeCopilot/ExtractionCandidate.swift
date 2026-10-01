import Foundation

// MARK: - Codable conformances for existing enums
// Added via extension here, NOT by editing MemoryEntity.swift/MemoryEdge.swift/
// ProjectItem.swift (protected foundation files) - these are all plain String-backed enums,
// so an empty extension conformance is enough for Codable to synthesize automatically. Nothing
// about the original types' behavior changes; this only adds a capability those files never
// needed until ExtractionCandidate needed to decode LLM JSON into them.
extension MemoryEntity.Kind: Codable {}
extension MemoryEdge.Category: Codable {}
extension ProjectItem.Kind: Codable {}
extension ProjectItem.Status: Codable {}

// MARK: - Extraction Candidate
/// A piece of structured information proposed by the extraction LLM call, before it has been
/// validated, deduplicated, checked for sensitive content, or persisted. Deliberately an
/// EPHEMERAL, in-memory-only type - never written to Core Data, never given its own store.
/// It exists only for the duration of `ExtractionCoordinator` processing one batch, and either
/// becomes a real `MemoryEdge`/`ProjectItem`/`Decision` row or is discarded. See the Phase 3.3
/// design notes for why a persisted "candidate" tier was explicitly rejected as
/// over-engineering for what's fundamentally a short-lived processing artifact.
///
/// One flat, `Codable` struct with a `type` discriminator, rather than a Swift enum with
/// associated values - this is what actually decodes cleanly from the LLM's heterogeneous JSON
/// output (memory/project-item/decision candidates sharing one array) without hand-written
/// custom decoding logic for a sum type. Fields not relevant to a given `type` are simply nil.
struct ExtractionCandidate: Equatable, Codable {
    enum CandidateType: String, Equatable, CaseIterable, Codable {
        case memoryEdge
        case projectItem
        case decision
    }

    /// Every candidate MUST carry this - it's what everything downstream (persistability,
    /// confidence capping, whether a Decision/completion status is allowed) gates on. See
    /// `ModalityPolicy` for the exact rules each value implies.
    enum Modality: String, Equatable, CaseIterable, Codable {
        case directStatement
        case explicitDecision
        case explicitTask
        case suggestion
        case speculation
        /// Never persisted - a request for information, not an assertion of fact.
        case question
        /// Never persisted - conditional framing, not a statement of what IS.
        case hypothetical
        /// May ONLY be used for reference resolution (e.g. resolving "it"/"that" to a named
        /// entity) - never the sole basis for asserting new fact content. A candidate whose
        /// own top-level modality is `.inference` is never persisted as a standalone fact.
        case inference
        /// Routed to the contradiction/supersession path, not scored as a fresh independent
        /// fact - see ExtractionCoordinator's dedup/conflict handling.
        case contradiction
        /// Hedge-worded (maybe/perhaps/I think/possibly/might) - confidence capped low
        /// regardless of what category it would otherwise fall into.
        case uncertain
    }

    let type: CandidateType
    let modality: Modality
    let confidence: Float
    /// True only for direct "remember that..." style requests - a separate axis from
    /// confidence, matching MemoryEdge.isExplicit's existing meaning exactly.
    let isExplicit: Bool

    // MARK: Memory-specific (type == .memoryEdge)
    /// "self" (or "I"/"me"/"user", case-insensitive) resolves to the singleton self
    /// MemoryEntity; any other name resolves via MemoryManager.entity(named:), created if not
    /// found.
    let subjectName: String?
    let subjectKind: MemoryEntity.Kind?
    let predicate: String?
    let objectName: String?
    let objectKind: MemoryEntity.Kind?
    let literalValue: String?
    let memoryCategory: MemoryEdge.Category?

    // MARK: Project-specific (type == .projectItem)
    let projectItemKind: ProjectItem.Kind?
    let name: String?
    let itemDescription: String?
    let projectItemStatus: ProjectItem.Status?
    /// E.g. a `.result` candidate naming the `.experiment` item it belongs to - resolved by
    /// name against the target project's existing items, same as `name` itself.
    let relatedItemName: String?

    // MARK: Decision-specific (type == .decision)
    let statement: String?
    let context: String?
    let reason: String?
    let madeByNames: [String]?

    // MARK: Shared, project-scoped
    /// An explicit project name mentioned in the conversation, if any - used for active-project
    /// resolution tier 2 (ExtractionCoordinator.resolveActiveProject). Applies to
    /// `.projectItem`/`.decision` candidates; nil for `.memoryEdge`.
    let mentionedProjectName: String?

    init(
        type: CandidateType,
        modality: Modality,
        confidence: Float,
        isExplicit: Bool = false,
        subjectName: String? = nil,
        subjectKind: MemoryEntity.Kind? = nil,
        predicate: String? = nil,
        objectName: String? = nil,
        objectKind: MemoryEntity.Kind? = nil,
        literalValue: String? = nil,
        memoryCategory: MemoryEdge.Category? = nil,
        projectItemKind: ProjectItem.Kind? = nil,
        name: String? = nil,
        itemDescription: String? = nil,
        projectItemStatus: ProjectItem.Status? = nil,
        relatedItemName: String? = nil,
        statement: String? = nil,
        context: String? = nil,
        reason: String? = nil,
        madeByNames: [String]? = nil,
        mentionedProjectName: String? = nil
    ) {
        self.type = type
        self.modality = modality
        self.confidence = confidence
        self.isExplicit = isExplicit
        self.subjectName = subjectName
        self.subjectKind = subjectKind
        self.predicate = predicate
        self.objectName = objectName
        self.objectKind = objectKind
        self.literalValue = literalValue
        self.memoryCategory = memoryCategory
        self.projectItemKind = projectItemKind
        self.name = name
        self.itemDescription = itemDescription
        self.projectItemStatus = projectItemStatus
        self.relatedItemName = relatedItemName
        self.statement = statement
        self.context = context
        self.reason = reason
        self.madeByNames = madeByNames
        self.mentionedProjectName = mentionedProjectName
    }
}

// MARK: - Modality Policy
/// Pure rules for what each `ExtractionCandidate.Modality` is allowed to do - kept as a
/// standalone enum (no state, no dependencies) so it's directly unit-testable, matching the
/// project's established convention for pulling pure decision logic into its own testable
/// type (e.g. ScrollFollowState).
enum ModalityPolicy {
    /// Questions, hypotheticals, and bare inference are never persisted as a standalone fact,
    /// full stop - regardless of whatever confidence the LLM assigned them.
    static func isEverPersistable(_ modality: ExtractionCandidate.Modality) -> Bool {
        switch modality {
        case .question, .hypothetical, .inference:
            return false
        default:
            return true
        }
    }

    /// Suggestions/speculation/uncertain statements are capped at low confidence regardless
    /// of what the LLM assigned - a structural guarantee, not just a prompting hope.
    static func effectiveConfidence(rawConfidence: Float, modality: ExtractionCandidate.Modality) -> Float {
        switch modality {
        case .suggestion, .speculation, .uncertain:
            return min(rawConfidence, 0.3)
        default:
            return rawConfidence
        }
    }

    /// Suggestions/speculation must never automatically become an active Decision.
    static func allowsActiveDecision(_ modality: ExtractionCandidate.Modality) -> Bool {
        switch modality {
        case .suggestion, .speculation, .uncertain:
            return false
        default:
            return true
        }
    }

    /// Suggestions/speculation must never automatically report a ProjectItem as
    /// completed/achieved/resolved.
    static func allowsCompletedStatus(_ modality: ExtractionCandidate.Modality) -> Bool {
        switch modality {
        case .suggestion, .speculation, .uncertain:
            return false
        default:
            return true
        }
    }
}
