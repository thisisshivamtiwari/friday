import Foundation

// MARK: - Extraction Coordinator
/// The central orchestration component for turning finalized conversation content into
/// structured Memory and Project state - see the Phase 3.3 design notes for the full
/// architecture. Owns the extraction queue/debounce timer and the full pipeline:
///
///   turn finalized -> cheap local pre-filter -> batch/debounce -> LLM extraction ->
///   SensitiveContentGate -> validation -> active-project resolution -> deduplication ->
///   conflict/contradiction detection -> MemoryManager/ProjectManager persistence
///
/// This is the one component that legitimately depends on BOTH `MemoryManager` and
/// `ProjectManager` - unlike those two, which correctly stay independent of each other and of
/// AIEngineController. `ExtractionCoordinator` itself has NO reference to GeminiLiveClient,
/// AudioCaptureManager, AudioMixer, or SystemAudioCaptureManager, and no reference to
/// GeminiResponseGenerator - the response generator remains completely unaware this exists.
///
/// Threading: `turnFinalized(...)` returns immediately - queueing/debounce bookkeeping runs
/// on a private background queue, the LLM call is genuinely async/network, and only the FINAL
/// candidate-processing step (which reads/writes MemoryManager/ProjectManager) is dispatched
/// to the main thread, matching how every other mutation of those ObservableObjects in this
/// app already happens on main.
final class ExtractionCoordinator {
    // MARK: Configurable constants - internal, not hard-coded architecture. No settings UI
    // exists for these; they're `var` specifically so tests (and any future tuning pass) can
    // override them without touching the pipeline's structure.

    /// How long to wait after the last queued turn before flushing a batch, if
    /// `maxQueuedTurns` isn't reached first. Approved V1 starting point: 45s.
    var debounceInterval: TimeInterval = 45
    /// Flush immediately once this many turns are queued for one session, without waiting for
    /// the debounce interval. Approved V1 starting point: 8.
    var maxQueuedTurns: Int = 8
    /// Bounded retry count for a failed extraction call - after this many retries, the batch
    /// is dropped (not retried indefinitely). The underlying conversation is never lost either
    /// way; it remains in ChatSessionStore regardless of extraction outcome.
    var maxRetryCount: Int = 2
    /// Below this, a candidate is discarded entirely rather than persisted at low confidence -
    /// a near-zero-confidence edge sitting in the graph forever is noise, not a useful "maybe".
    var minimumConfidenceThreshold: Float = 0.3
    /// Base for exponential retry backoff (seconds) - real production delay; tests override
    /// this to a tiny value so retry behavior can be verified without waiting through real
    /// multi-second delays.
    var retryBackoffBase: TimeInterval = 2.0

    private let memoryManager: MemoryManager
    private let projectManager: ProjectManager
    private let llmClient: ExtractionLLMClientProtocol
    /// Lazily consulted at flush-time, not cached at init - same pattern as
    /// AIEngineController.apiKeyProvider, so a key entered after launch is picked up
    /// immediately without reconstructing this coordinator.
    var apiKeyProvider: () -> String?
    /// Which model extraction calls use - defaults to reusing SettingsStore's existing
    /// response model rather than introducing a new setting (SettingsStore.swift is a
    /// protected foundation file in this phase; this only READS its existing public API).
    var model: () -> String

    private let queue = DispatchQueue(label: "com.founderoffice.copilot.extraction")

    private struct QueuedTurn {
        let messageID: UUID
        let text: String
    }

    /// Keyed by recording session - batches are NEVER mixed across sessions, so switching
    /// which session is being recorded into can never corrupt an in-flight batch.
    private var pendingTurnsBySession: [UUID: [QueuedTurn]] = [:]
    private var debounceWorkItemsBySession: [UUID: DispatchWorkItem] = [:]

    /// The ephemeral, per-session "what did I most recently extract" pointer used for user
    /// corrections ("no, that's wrong") - deliberately NOT persisted anywhere, it only needs
    /// to survive as long as the app is running. Touched only on the main thread (see
    /// `handleCorrection`/`recordLastExtraction`), same as MemoryManager/ProjectManager
    /// themselves.
    private struct LastExtraction {
        enum Target: Equatable {
            case memoryEdge(UUID)
            case projectItem(UUID)
            case decision(UUID)
        }
        let target: Target
    }
    private var lastExtractionBySession: [UUID: LastExtraction] = [:]

    // MARK: Decision-link diagnostics (ephemeral, in-memory, never persisted)

    /// Which source produced (or failed to produce) a decision's ProjectItem link. Exists purely
    /// so offline tests can distinguish "the model never emitted relatedItemName" from "it emitted
    /// one that matched nothing" - a distinction that was invisible during live validation and
    /// left us unable to explain a 0-link run. Records only item labels and an outcome: no API
    /// keys, no conversation text, no transcript content.
    struct DecisionLinkDiagnostics: Equatable {
        enum Source: String, Equatable { case relatedItemName, statement, context }
        /// Exactly what the candidate carried: nil means the model emitted none at all.
        let relatedItemName: String?
        /// The source that produced the link, or nil when nothing linked.
        let matchedSource: Source?
        /// Set when a source matched SEVERAL items and therefore stopped the search.
        let ambiguousSource: Source?
        let resolvedItemID: UUID?
    }

    /// The most recent decision candidate's link outcome. Deliberately NOT persisted - a
    /// debugging/testing window, nothing more.
    private(set) var lastDecisionLinkDiagnostics: DecisionLinkDiagnostics?

    /// A bounded, in-memory history of recent decision-link outcomes, newest last. Exists because
    /// a single "last" value cannot explain a whole population run - the live 0-link runs left us
    /// unable to say whether the model emitted `relatedItemName` at all. Capped so it can never
    /// grow without bound, never persisted, and holds no transcript text or credentials.
    private(set) var recentDecisionLinkDiagnostics: [DecisionLinkDiagnostics] = []
    private let maxRetainedDiagnostics = 50

    private func record(_ diagnostics: DecisionLinkDiagnostics) {
        lastDecisionLinkDiagnostics = diagnostics
        recentDecisionLinkDiagnostics.append(diagnostics)
        if recentDecisionLinkDiagnostics.count > maxRetainedDiagnostics {
            recentDecisionLinkDiagnostics.removeFirst(recentDecisionLinkDiagnostics.count - maxRetainedDiagnostics)
        }
    }

    /// `memoryManager`/`projectManager` default to real, on-disk-backed instances; tests
    /// inject ones built on `inMemory: true` stores. `llmClient` defaults to the real
    /// Gemini-backed client; tests inject a stub - see this type's own doc comment on why
    /// XCTest must never exercise the real network client.
    init(
        memoryManager: MemoryManager = MemoryManager(),
        projectManager: ProjectManager = ProjectManager(),
        llmClient: ExtractionLLMClientProtocol = ExtractionLLMClient(),
        apiKeyProvider: @escaping () -> String? = { SettingsStore.shared.geminiAPIKey },
        model: @escaping () -> String = { SettingsStore.shared.responseModel }
    ) {
        self.memoryManager = memoryManager
        self.projectManager = projectManager
        self.llmClient = llmClient
        self.apiKeyProvider = apiKeyProvider
        self.model = model
    }

    // MARK: Public entry point - fire and forget from AIEngineController

    /// Returns immediately - all queueing work happens asynchronously on this coordinator's
    /// own background queue. AIEngineController never waits on this call, and nothing it does
    /// can affect transcription, response generation, or UI rendering.
    func turnFinalized(sessionID: UUID, messageID: UUID, text: String) {
        queue.async { [weak self] in
            self?.enqueue(sessionID: sessionID, messageID: messageID, text: text)
        }
    }

    // MARK: Queueing / batching (background queue)

    private func enqueue(sessionID: UUID, messageID: UUID, text: String) {
        guard ExtractionHeuristics.isWorthExtracting(text) else { return }

        if ExtractionHeuristics.looksLikeCorrection(text) {
            DispatchQueue.main.async { [weak self] in
                self?.handleCorrection(sessionID: sessionID)
            }
        }

        var turns = pendingTurnsBySession[sessionID] ?? []
        turns.append(QueuedTurn(messageID: messageID, text: text))
        pendingTurnsBySession[sessionID] = turns

        if turns.count >= maxQueuedTurns {
            debounceWorkItemsBySession[sessionID]?.cancel()
            debounceWorkItemsBySession[sessionID] = nil
            flush(sessionID: sessionID)
        } else {
            scheduleDebounce(sessionID: sessionID)
        }
    }

    private func scheduleDebounce(sessionID: UUID) {
        debounceWorkItemsBySession[sessionID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flush(sessionID: sessionID)
        }
        debounceWorkItemsBySession[sessionID] = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func flush(sessionID: UUID) {
        debounceWorkItemsBySession[sessionID] = nil
        guard let turns = pendingTurnsBySession[sessionID], !turns.isEmpty else { return }
        pendingTurnsBySession[sessionID] = nil
        attemptExtraction(sessionID: sessionID, turns: turns, retriesRemaining: maxRetryCount)
    }

    /// Test-only hook: forces an immediate flush of whatever is currently queued for
    /// `sessionID`, bypassing the debounce timer - lets tests exercise the pipeline
    /// deterministically without sleeping for real seconds.
    func flushNowForTesting(sessionID: UUID) {
        queue.sync {
            debounceWorkItemsBySession[sessionID]?.cancel()
            flush(sessionID: sessionID)
        }
    }

    // MARK: LLM call + retry (background queue schedules, network is genuinely async)

    private func attemptExtraction(sessionID: UUID, turns: [QueuedTurn], retriesRemaining: Int) {
        guard apiKeyProvider()?.isEmpty == false else { return }
        // The canonical item names must be read from ProjectManager, which is a main-thread
        // ObservableObject - so this hops to main to collect them and issues the request from
        // there. The request itself is async network either way; nothing blocks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let names = self.canonicalProjectItemNames(forSession: sessionID)
            self.performExtraction(sessionID: sessionID, turns: turns, existingProjectItemNames: names, retriesRemaining: retriesRemaining)
        }
    }

    /// Canonical `ProjectItem.name` values for the ACTIVE project of `sessionID` - names only,
    /// never whole objects. Project isolation is structural: the session resolves to exactly one
    /// project via the explicit session->project link, and `items(forProject:)` is the only
    /// source, so another project's items can never enter the prompt. Returns [] when the session
    /// isn't linked to a project (then no list section is emitted at all).
    ///
    /// Items created by the CURRENT batch don't exist yet at this point and are deliberately not
    /// anticipated - the resolver's project-scoped token containment remains the final gate for
    /// those, backed by the existing project-items-before-decisions ordering.
    private func canonicalProjectItemNames(forSession sessionID: UUID) -> [String] {
        guard let projectID = projectManager.project(forSession: sessionID) else { return [] }
        return projectManager.items(forProject: projectID).map(\.name)
    }

    private func performExtraction(sessionID: UUID, turns: [QueuedTurn], existingProjectItemNames: [String], retriesRemaining: Int) {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return }
        let combinedText = turns.map(\.text).joined(separator: "\n")
        let messageIDs = turns.map(\.messageID)

        llmClient.extract(conversationText: combinedText, apiKey: apiKey, model: model(), existingProjectItemNames: existingProjectItemNames) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let candidates):
                DispatchQueue.main.async {
                    self.process(candidates: candidates, sessionID: sessionID, messageIDs: messageIDs)
                }
            case .failure:
                if retriesRemaining > 0 {
                    let attemptNumber = self.maxRetryCount - retriesRemaining + 1
                    let backoff = self.retryBackoffBase * pow(2.0, Double(attemptNumber - 1))
                    self.queue.asyncAfter(deadline: .now() + backoff) {
                        self.performExtraction(sessionID: sessionID, turns: turns, existingProjectItemNames: existingProjectItemNames, retriesRemaining: retriesRemaining - 1)
                    }
                }
                // Retries exhausted: the batch is silently dropped. The conversation itself
                // remains permanently available in ChatSessionStore regardless - only the
                // DERIVED extraction insight is lost, never the source of truth.
            }
        }
    }

    // MARK: Candidate processing (main thread - the only place MemoryManager/ProjectManager are touched)

    private func process(candidates: [ExtractionCandidate], sessionID: UUID, messageIDs: [UUID]) {
        // Project items are processed first so a decision in the SAME batch can link to an item
        // that batch is creating. A decision resolves `relatedItemID` against items that already
        // exist (`ProjectManager.items(forProject:)`), so in the model's own emission order a
        // decision listed before its component would find nothing and silently stay unlinked.
        //
        // Deliberately a STABLE partition on one type, not a general reordering: project items
        // are hoisted, and everything else (memory edges, decisions) keeps its original relative
        // order, so no other processing sequence changes. `enumerated()` keeps the sort stable
        // without depending on `sorted(by:)`'s unspecified equal-element behavior.
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            let lhsRank = lhs.element.type == .projectItem ? 0 : 1
            let rhsRank = rhs.element.type == .projectItem ? 0 : 1
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)

        for candidate in ordered {
            processOne(candidate, sessionID: sessionID, messageIDs: messageIDs)
        }
    }

    private func processOne(_ candidate: ExtractionCandidate, sessionID: UUID, messageIDs: [UUID]) {
        guard ModalityPolicy.isEverPersistable(candidate.modality) else { return }
        guard !SensitiveContentGate.isSensitive(candidate) else { return }

        let effectiveConfidence = ModalityPolicy.effectiveConfidence(rawConfidence: candidate.confidence, modality: candidate.modality)
        guard effectiveConfidence >= minimumConfidenceThreshold else { return }

        switch candidate.type {
        case .memoryEdge:
            processMemoryCandidate(candidate, effectiveConfidence: effectiveConfidence, sessionID: sessionID, messageIDs: messageIDs)

        case .projectItem:
            guard let projectID = resolveActiveProject(sessionID: sessionID, candidate: candidate) else { return }
            processProjectItemCandidate(candidate, effectiveConfidence: effectiveConfidence, projectID: projectID, sessionID: sessionID, messageIDs: messageIDs)

        case .decision:
            guard let projectID = resolveActiveProject(sessionID: sessionID, candidate: candidate) else { return }
            processDecisionCandidate(candidate, effectiveConfidence: effectiveConfidence, projectID: projectID, sessionID: sessionID, messageIDs: messageIDs)
        }
    }

    // MARK: Memory extraction

    private func processMemoryCandidate(_ candidate: ExtractionCandidate, effectiveConfidence: Float, sessionID: UUID, messageIDs: [UUID]) {
        guard let subjectName = candidate.subjectName, !subjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let category = candidate.memoryCategory,
              let predicate = candidate.predicate, !predicate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let subject = resolveEntity(named: subjectName, kindHint: candidate.subjectKind)
        let normalizedPredicate = predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existing = memoryManager.edges.first {
            $0.subjectEntityID == subject.id
                && $0.predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedPredicate
                && $0.category == category
                && $0.status == .active
        }

        let hasNewValue = candidate.objectName != nil || candidate.literalValue != nil

        // Pure retraction: contradiction modality with no new value asserted - invalidate the
        // existing edge, create nothing new.
        if candidate.modality == .contradiction, !hasNewValue {
            guard let existing else { return }
            invalidateMemoryEdge(existing)
            return
        }

        guard hasNewValue else { return }
        let object = candidate.objectName.map { resolveEntity(named: $0, kindHint: candidate.objectKind) }

        if let existing {
            let sameValue = existing.objectEntityID == object?.id && existing.literalValue == candidate.literalValue
            if sameValue {
                corroborateMemoryEdge(existing, sessionID: sessionID, messageIDs: messageIDs)
            } else {
                supersedeMemoryEdge(
                    existing,
                    subjectID: subject.id,
                    predicate: predicate,
                    category: category,
                    objectID: object?.id,
                    literalValue: candidate.literalValue,
                    confidence: effectiveConfidence,
                    isExplicit: candidate.isExplicit,
                    sessionID: sessionID,
                    messageIDs: messageIDs
                )
            }
        } else {
            let newEdge = MemoryEdge(
                subjectEntityID: subject.id,
                predicate: predicate,
                objectEntityID: object?.id,
                literalValue: candidate.literalValue,
                category: category,
                confidence: effectiveConfidence,
                sourceSessionID: sessionID,
                sourceMessageIDs: messageIDs,
                isExplicit: candidate.isExplicit
            )
            memoryManager.createEdge(newEdge)
            recordLastExtraction(.memoryEdge(newEdge.id), sessionID: sessionID)
        }
    }

    private func corroborateMemoryEdge(_ existing: MemoryEdge, sessionID: UUID, messageIDs: [UUID]) {
        var updated = existing
        updated.confirmationCount += 1
        updated.lastConfirmedAt = Date()
        updated.sourceMessageIDs += messageIDs
        updated.confidence = Self.corroboratedConfidence(current: existing.confidence)
        memoryManager.updateEdge(updated)
        recordLastExtraction(.memoryEdge(updated.id), sessionID: sessionID)
    }

    /// Diminishing returns: each corroboration nudges confidence toward a ceiling with a
    /// shrinking increment - matches the Phase 3 design notes ("1=low/medium, 2=medium,
    /// 3+=high, plateaus after ~3-4 confirmations") without needing to track/branch on the
    /// exact confirmation count.
    private static func corroboratedConfidence(current: Float) -> Float {
        let ceiling: Float = 0.95
        return min(ceiling, current + (ceiling - current) * 0.4)
    }

    private func supersedeMemoryEdge(
        _ existing: MemoryEdge,
        subjectID: UUID,
        predicate: String,
        category: MemoryEdge.Category,
        objectID: UUID?,
        literalValue: String?,
        confidence: Float,
        isExplicit: Bool,
        sessionID: UUID,
        messageIDs: [UUID]
    ) {
        let newEdge = MemoryEdge(
            subjectEntityID: subjectID,
            predicate: predicate,
            objectEntityID: objectID,
            literalValue: literalValue,
            category: category,
            confidence: confidence,
            sourceSessionID: sessionID,
            sourceMessageIDs: messageIDs,
            supersedes: existing.id,
            isExplicit: isExplicit
        )
        var old = existing
        old.status = .superseded
        old.supersededBy = newEdge.id
        memoryManager.updateEdge(old)
        memoryManager.createEdge(newEdge)
        recordLastExtraction(.memoryEdge(newEdge.id), sessionID: sessionID)
    }

    private func invalidateMemoryEdge(_ existing: MemoryEdge) {
        guard existing.status == .active else { return }
        var updated = existing
        updated.status = .invalidated
        memoryManager.updateEdge(updated)
    }

    /// "self"/"I"/"me"/"user" resolves to the singleton self MemoryEntity, created if it
    /// doesn't exist yet; any other name resolves via MemoryManager.entity(named:) (existing
    /// case-insensitive/alias-aware lookup), created as a new entity if not found.
    private func resolveEntity(named name: String, kindHint: MemoryEntity.Kind?) -> MemoryEntity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let selfAliases: Set<String> = ["self", "i", "me", "myself", "user"]
        if selfAliases.contains(trimmed.lowercased()) {
            if let existing = memoryManager.entities.first(where: { $0.kind == .self }) {
                return existing
            }
            return memoryManager.createEntity(MemoryEntity(kind: .self, name: "Me"))
        }
        if let existing = memoryManager.entity(named: trimmed) {
            return existing
        }
        return memoryManager.createEntity(MemoryEntity(kind: kindHint ?? .other, name: trimmed))
    }

    // MARK: Project extraction

    private func processProjectItemCandidate(_ candidate: ExtractionCandidate, effectiveConfidence: Float, projectID: UUID, sessionID: UUID, messageIDs: [UUID]) {
        guard let kind = candidate.projectItemKind,
              let name = candidate.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var status = candidate.projectItemStatus ?? .proposed
        let completedLike: Set<ProjectItem.Status> = [.completed, .achieved, .resolved]
        if completedLike.contains(status), !ModalityPolicy.allowsCompletedStatus(candidate.modality) {
            status = .proposed
        }

        if let existing = findSimilarProjectItem(name: name, kind: kind, projectID: projectID) {
            var updated = existing
            updated.status = status
            updated.lastUpdatedAt = Date()
            updated.sourceMessageIDs += messageIDs
            if updated.description == nil {
                updated.description = candidate.itemDescription
            }
            projectManager.updateProjectItem(updated)
            recordLastExtraction(.projectItem(updated.id), sessionID: sessionID)
        } else {
            let relatedItemID = candidate.relatedItemName.flatMap { findSimilarProjectItem(name: $0, kind: nil, projectID: projectID)?.id }
            let newItem = ProjectItem(
                projectID: projectID,
                kind: kind,
                name: name,
                description: candidate.itemDescription,
                status: status,
                relatedItemID: relatedItemID,
                sourceSessionID: sessionID,
                sourceMessageIDs: messageIDs,
                confidence: effectiveConfidence,
                isExplicit: candidate.isExplicit
            )
            projectManager.createProjectItem(newItem)
            // ProjectEvent is emitted here directly via ProjectManager's existing public
            // createProjectEvent(...) method - there is no "automatic" item-creation event
            // mechanism built into ProjectManager itself (unlike supersedeDecision/
            // assignSession, which already auto-emit their own events), so the coordinator
            // constructs this one using ProjectManager's existing API rather than adding new
            // automatic-emission logic to a protected foundation file.
            projectManager.createProjectEvent(ProjectEvent(
                projectID: projectID,
                relatedItemID: newItem.id,
                eventType: .itemCreated,
                description: name,
                sourceSessionID: sessionID,
                sourceMessageIDs: messageIDs
            ))
            recordLastExtraction(.projectItem(newItem.id), sessionID: sessionID)
        }
    }

    /// Substring-based name matching, scoped to one project and (optionally) one kind - no
    /// embeddings, same documented limitation as Memory's dedup matching: a genuine paraphrase
    /// of an existing item's name may not be caught.
    private func findSimilarProjectItem(name: String, kind: ProjectItem.Kind?, projectID: UUID) -> ProjectItem? {
        projectManager.items(forProject: projectID).first { Self.matches($0, name: name, kind: kind) }
    }

    /// The existing similarity rule, factored out unchanged so the "first match" lookup above and
    /// the "unambiguous match" lookup below can never disagree about what similar means. This is
    /// the SAME comparison as before - no new matching system, no scoring.
    private static func matches(_ item: ProjectItem, name: String, kind: ProjectItem.Kind?) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if let kind, item.kind != kind { return false }
        let itemName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !itemName.isEmpty else { return false }
        return itemName == normalized || itemName.contains(normalized) || normalized.contains(itemName)
    }

    /// Three-way outcome, because "nothing matched" and "several things matched" must lead to
    /// DIFFERENT decisions: the first means "try a weaker source", the second means "stop". A
    /// wrong `Decision.relatedItemID` actively suppresses a legitimate ProjectItem from retrieved
    /// context (see `CrossLayerConflictResolver`'s decision-vs-item branch), so an ambiguous
    /// higher-priority source must never be silently overridden by a weaker one.
    private enum ItemMatchOutcome {
        case none
        case unique(UUID)
        case ambiguous
    }

    /// Project-scoped token containment: an item is a candidate when EVERY significant token of
    /// its name appears somewhere in `source`. `items(forProject:)` is the only candidate source,
    /// so this cannot reach another project's items, and it never creates anything.
    private func matchOutcome(for source: String?, projectID: UUID) -> ItemMatchOutcome {
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        let candidates = projectManager.items(forProject: projectID)

        let sourceTokens = Self.significantTokens(source)
        guard !sourceTokens.isEmpty else { return .none }
        let matches = candidates.filter {
            Self.tokensContained(itemName: $0.name, inSourceTokens: sourceTokens)
        }
        switch matches.count {
        case 0: return .none
        case 1: return .unique(matches[0].id)
        default: return Self.resolveByExactNameSpecificity(source: source, tiedMatches: matches)
        }
    }

    /// Last-resort disambiguation for a source that token containment finds AMBIGUOUS. Returns
    /// `.ambiguous` unchanged unless one very specific, evidence-driven shape holds.
    ///
    /// The hole this closes only became reachable once the model started reliably emitting exact
    /// names (see `ExtractionLLMClient`'s payload notes - measured 9/9 emitted names were verbatim
    /// copies, 0 paraphrased, 0 invented). Whenever one item's name is a STRICT token-subset of
    /// another's, naming the longer one matches both, so the more specific item could never be
    /// linked. Live-observed pair: "Split transient and group demand models" is a strict subset of
    /// "Split transient and group demand sub-models in ADR prediction pipeline".
    ///
    /// Two conditions must BOTH hold, and together they are what keep this from trading precision
    /// for recall:
    /// 1. exactly ONE tied item's name equals the source verbatim (modulo case/surrounding space),
    ///    and
    /// 2. every OTHER tied item is a strictly LESS SPECIFIC version of that same name - its
    ///    significant tokens are a strict subset of the exactly-named item's.
    ///
    /// Condition 2 is the load-bearing one. Rivals of EQUAL specificity keep blocking the link, so
    /// a genuinely undecidable pair like "Monte Carlo Dropout" vs "Monte Carlo Dropout approach"
    /// (token-identical once `approach` is dropped as generic) still resolves to `.ambiguous` and
    /// still refuses to guess - which is the behaviour `testAmbiguousReferenceMatchingTwoSimilar\
    /// ItemsLeavesRelatedItemIDNil` pins. Nothing here can invent a match token containment
    /// rejected: it only ever picks a winner from among items containment ALREADY matched.
    private static func resolveByExactNameSpecificity(source: String, tiedMatches: [ProjectItem]) -> ItemMatchOutcome {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let normalizedSource = normalized(source)
        let exact = tiedMatches.filter { normalized($0.name) == normalizedSource }
        guard exact.count == 1, let winner = exact.first else { return .ambiguous }

        let winnerTokens = significantTokens(winner.name)
        let othersAreStrictlyLessSpecific = tiedMatches
            .filter { $0.id != winner.id }
            .allSatisfy { significantTokens($0.name).isStrictSubset(of: winnerTokens) }

        return othersAreStrictlyLessSpecific ? .unique(winner.id) : .ambiguous
    }

    /// Deterministic set containment - no scoring, no ranking, no partial credit, no embeddings.
    /// Every significant token of the ITEM name must be present in the source; extra words in the
    /// source are ignored, which is precisely what a plain substring test could not tolerate.
    ///
    /// Live cases this exists for: item "Testing temperature scaling versus MC dropout" vs
    /// statement "Pivot to testing ONLINE temperature scaling versus MC dropout", and item
    /// "Split transient and group demand sub-models" vs statement "Split transient and group
    /// demand INTO TWO SEPARATE sub-models". One inserted word defeated substring matching in
    /// both, while every meaningful word was in fact present.
    ///
    /// Direction matters: item-tokens ⊆ source-tokens, never the reverse. "Let's discuss
    /// temperature scaling" does NOT match "Online temperature scaling layer", because `online`
    /// and `layer` are absent - a partially-named item is not the item.
    private static func tokensContained(itemName: String, inSourceTokens sourceTokens: Set<String>) -> Bool {
        let itemTokens = significantTokens(itemName)
        // An item whose name is entirely generic ("The approach") carries no identifying content;
        // matching it against anything would link everything to it.
        guard !itemTokens.isEmpty else { return false }
        return itemTokens.isSubset(of: sourceTokens)
    }

    /// `RelevanceScoring`'s tokenization convention - lowercased, split on non-alphanumerics,
    /// tokens longer than 2 characters - minus tokens that carry no identifying content. Written
    /// here rather than shared because `RelevanceScoring.tokenize` is private to that type and
    /// out of scope to modify; the rule is deliberately identical.
    private static func significantTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        ).subtracting(genericLinkTokens)
    }

    /// Words that survive tokenization but must never, on their own, establish that a decision is
    /// about a tracked item. Generic project/work vocabulary plus ordinary function words - no
    /// domain terms, so this can never encode which subjects are linkable. Without `approach`
    /// here, the item "Conformal Prediction approach" would match any sentence containing the
    /// word "approach" whose other tokens happened to align.
    private static let genericLinkTokens: Set<String> = [
        "approach", "approaches", "project", "projects", "work", "working", "thing", "things",
        "use", "used", "using", "stuff", "item", "items", "task", "tasks",
        "the", "and", "for", "with", "about", "that", "this", "these", "those", "our", "ours",
        "was", "were", "are", "its", "from", "into", "than", "then", "there", "here", "they",
        "them", "their", "have", "has", "had", "been", "being", "just", "like", "some", "any",
        "all", "can", "could", "would", "should", "will", "not", "but", "out", "off", "over",
        "under", "more", "most", "much", "many", "one", "two", "own", "new",
    ]

    /// Resolves which tracked ProjectItem a decision is about, scoped to `projectID` - the same
    /// project the decision itself is being created in, so a link can never cross projects
    /// (`ProjectManager.items(forProject:)` is the only source of candidates).
    ///
    /// Sources are tried strongest-first: `relatedItemName` (what the model was explicitly asked
    /// for), then `statement`, then `context`.
    ///
    /// `statement` earns its place from live evidence, not theory: in a real populated run the
    /// model returned no `relatedItemName` at all and only prose `context` values, yet two
    /// decisions named their item almost verbatim in the STATEMENT - "Pivot to testing online
    /// temperature scaling versus MC dropout" alongside the tracked item "Testing temperature
    /// scaling versus MC dropout", and "Split transient and group demand into two separate
    /// sub-models" alongside "Split transient and group demand sub-models". Both went unlinked
    /// purely because the statement was never consulted.
    ///
    /// A source that matches NOTHING falls through to the next one; a source that matches
    /// SEVERAL items stops the search and yields nil. That asymmetry is deliberate - if the
    /// strongest available signal is genuinely ambiguous, a weaker one agreeing with one of the
    /// candidates is not new evidence, it's a coin flip. Every source uses the same existing
    /// project-scoped matcher; nothing here creates a ProjectItem or looks outside `projectID`.
    private func resolveRelatedProjectItemID(for candidate: ExtractionCandidate, projectID: UUID) -> UUID? {
        let sources: [(DecisionLinkDiagnostics.Source, String?)] = [
            (.relatedItemName, candidate.relatedItemName),
            (.statement, candidate.statement),
            (.context, candidate.context),
        ]
        for (label, source) in sources {
            switch matchOutcome(for: source, projectID: projectID) {
            case .unique(let id):
                record(DecisionLinkDiagnostics(
                    relatedItemName: candidate.relatedItemName, matchedSource: label,
                    ambiguousSource: nil, resolvedItemID: id
                ))
                return id
            case .ambiguous:
                record(DecisionLinkDiagnostics(
                    relatedItemName: candidate.relatedItemName, matchedSource: nil,
                    ambiguousSource: label, resolvedItemID: nil
                ))
                return nil
            case .none:
                continue
            }
        }
        record(DecisionLinkDiagnostics(
            relatedItemName: candidate.relatedItemName, matchedSource: nil,
            ambiguousSource: nil, resolvedItemID: nil
        ))
        return nil
    }

    // MARK: Decision extraction

    private func processDecisionCandidate(_ candidate: ExtractionCandidate, effectiveConfidence: Float, projectID: UUID, sessionID: UUID, messageIDs: [UUID]) {
        guard let statement = candidate.statement, !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard ModalityPolicy.allowsActiveDecision(candidate.modality) else { return }

        let madeByIDs = (candidate.madeByNames ?? []).map { resolveEntity(named: $0, kindHint: .person).id }
        let normalizedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The structural Decision -> ProjectItem link. `Decision.relatedItemID` has existed (and
        // been persisted/reloaded correctly) since the type was introduced, but nothing ever
        // populated it on this path, so it was nil for every decision ever extracted and
        // `CrossLayerConflictResolver`'s decision-vs-item branch never once ran.
        let relatedItemID = resolveRelatedProjectItemID(for: candidate, projectID: projectID)

        if let existingSameContext = findActiveDecision(context: candidate.context, projectID: projectID) {
            let sameStatement = existingSameContext.statement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedStatement
            if sameStatement {
                var updated = existingSameContext
                updated.sourceMessageIDs += messageIDs
                projectManager.updateDecision(updated)
                recordLastExtraction(.decision(updated.id), sessionID: sessionID)
            } else {
                let newDecision = Decision(
                    projectID: projectID,
                    statement: statement,
                    context: candidate.context,
                    relatedItemID: relatedItemID,
                    madeBy: madeByIDs,
                    reason: candidate.reason,
                    sourceSessionID: sessionID,
                    sourceMessageIDs: messageIDs
                )
                // supersedeDecision already auto-emits its own ProjectEvent - "through
                // ProjectManager's existing automatic event mechanism", exactly as specified.
                if let created = projectManager.supersedeDecision(existingSameContext.id, with: newDecision) {
                    recordLastExtraction(.decision(created.id), sessionID: sessionID)
                }
            }
        } else {
            let newDecision = Decision(
                projectID: projectID,
                statement: statement,
                context: candidate.context,
                relatedItemID: relatedItemID,
                madeBy: madeByIDs,
                reason: candidate.reason,
                sourceSessionID: sessionID,
                sourceMessageIDs: messageIDs
            )
            projectManager.createDecision(newDecision)
            projectManager.createProjectEvent(ProjectEvent(
                projectID: projectID,
                relatedItemID: newDecision.id,
                eventType: .decisionMade,
                description: statement,
                sourceSessionID: sessionID,
                sourceMessageIDs: messageIDs
            ))
            recordLastExtraction(.decision(newDecision.id), sessionID: sessionID)
        }
    }

    /// Matches on `context` (e.g. a component name) - a new decision naming the SAME context
    /// as an existing active decision is treated as either a restatement (same statement) or
    /// a contradiction (different statement); a decision with no context, or a context that
    /// doesn't match any existing active decision, is treated as independent, not a conflict.
    private func findActiveDecision(context: String?, projectID: UUID) -> Decision? {
        guard let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = context.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projectManager.decisions(forProject: projectID).first {
            $0.status == .active && $0.context?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    // MARK: Active project resolution

    /// Exactly the approved priority order. CRITICAL: never creates or modifies a
    /// ProjectSessionLink - that association remains exclusively under the user's explicit
    /// control (ProjectManager.assignSession, called only from user-facing UI in a later
    /// phase). This method only ever answers "which project does THIS FACT belong to", a
    /// completely different question from "which project is THIS SESSION linked to".
    private func resolveActiveProject(sessionID: UUID, candidate: ExtractionCandidate) -> UUID? {
        // Tier 1: explicit session -> project association.
        if let linked = projectManager.project(forSession: sessionID) {
            return linked
        }

        // Tier 2: explicit project mention matching an existing project by name.
        if let mentioned = candidate.mentionedProjectName?.trimmingCharacters(in: .whitespacesAndNewlines), !mentioned.isEmpty {
            if let match = projectManager.projects.first(where: { $0.name.caseInsensitiveCompare(mentioned) == .orderedSame }) {
                return match.id
            }
        }

        // Tier 3: one strong, unambiguous contextual match - the candidate's own text names
        // something that matches an EXISTING item in exactly one project. If it matches
        // multiple projects, or none, this tier yields nothing - never guesses among several.
        let probes = [candidate.name, candidate.relatedItemName, candidate.statement, candidate.context]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !probes.isEmpty {
            var matchedProjectIDs = Set<UUID>()
            for project in projectManager.projects {
                let items = projectManager.items(forProject: project.id)
                let matches = items.contains { item in
                    let itemName = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !itemName.isEmpty else { return false }
                    return probes.contains { probe in
                        let normalizedProbe = probe.lowercased()
                        return normalizedProbe.contains(itemName) || itemName.contains(normalizedProbe)
                    }
                }
                if matches { matchedProjectIDs.insert(project.id) }
            }
            if matchedProjectIDs.count == 1 {
                return matchedProjectIDs.first
            }
        }

        // Tier 4: do not assign. Conversation-only; ProjectStore is never mutated for this
        // candidate.
        return nil
    }

    // MARK: User correction

    private func recordLastExtraction(_ target: LastExtraction.Target, sessionID: UUID) {
        lastExtractionBySession[sessionID] = LastExtraction(target: target)
    }

    /// "No, that's wrong" (detected locally by ExtractionHeuristics.looksLikeCorrection,
    /// before this turn even reaches the LLM batch) invalidates whatever was most recently
    /// extracted for this session. If the SAME turn also states a replacement ("I prefer
    /// Vue"), that replacement is picked up completely separately by normal candidate
    /// processing later in the same batch - since the old edge is already invalidated by the
    /// time that runs, the replacement creates a genuinely new active edge rather than
    /// corroborating the (now invalid) old one. The old row is NEVER deleted - only its
    /// status changes, so provenance is fully preserved.
    private func handleCorrection(sessionID: UUID) {
        guard let last = lastExtractionBySession[sessionID] else { return }
        switch last.target {
        case .memoryEdge(let id):
            if let edge = memoryManager.edge(id: id) {
                invalidateMemoryEdge(edge)
            }
        case .projectItem(let id):
            // ProjectItem.Status has no "invalidated" case - `.abandoned` is the closest
            // existing status meaning "no longer treated as current/valid", used here as a
            // deliberate, honest approximation rather than adding a new enum case to a
            // protected foundation file. Flagged as a known limitation in the final report.
            if var item = projectManager.projectItem(id: id) {
                item.status = .abandoned
                item.lastUpdatedAt = Date()
                projectManager.updateProjectItem(item)
            }
        case .decision(let id):
            // Decision.Status has only active/superseded (no "invalidated") - marking it
            // superseded with no supersededBy honestly represents "retracted, no specific
            // replacement" using the existing vocabulary, same reasoning as ProjectItem above.
            if var decision = projectManager.decision(id: id), decision.status == .active {
                decision.status = .superseded
                projectManager.updateDecision(decision)
            }
        }
        lastExtractionBySession[sessionID] = nil
    }
}
