import Foundation

// MARK: - Context Packet Formatter
/// Stage 7's deterministic `ContextPacket -> model-context text` layer - the ONLY place a
/// `ContextPacket` gets turned into prose Gemini can read. `GeminiResponseGenerator` never
/// sees a `ContextPacket`; `AIEngineController` calls `format(_:)` and appends the result to
/// the existing `systemInstruction` string, which is the only integration surface
/// `GeminiResponseGenerator.generate(systemInstruction:context:...)` already exposes - its
/// signature, streaming behavior, and multi-turn `contents` construction are all completely
/// unchanged.
///
/// Pure and deterministic - no network, no randomness, entirely a function of the packet's
/// already-computed fields (`renderedText`, `temporalStatus`, per-type dates/status). Every
/// evidence array is rendered under an explicit heading so the model can tell USER MEMORY,
/// PROJECT STATE, DECISIONS, and PAST EPISODES apart, and every item is placed under CURRENT
/// or HISTORICAL based on its OWN `temporalStatus` - never inferred, never guessed.
enum ContextPacketFormatter {
    /// Always returns a non-empty string - when nothing relevant was retrieved at all, this
    /// explicitly says so (see the empty-packet branch below) rather than silently omitting
    /// the block. That's deliberate: "the model should be able to distinguish 'I don't have
    /// stored context for this' from having some" only works if the model is actually TOLD
    /// when retrieval found nothing, not left to guess from an absent section.
    ///
    /// `questionText` is the newest heard content the response is being generated for - needed
    /// here, not just at retrieval time, because a topic GATE (see `isRelevant`) has to be
    /// reapplied at formatting time: `RetrievalProvider` implementations return whatever ranks
    /// in the top `limit` even when nothing genuinely matched (see
    /// `KeywordGraphRetrievalProvider`'s own doc comments), and Tier 1 project resolution is
    /// deliberately unconditional on the question's content (see `ProjectResolution`) - so a
    /// completely unrelated question ("what's the weather") asked inside a session linked to
    /// an active project would otherwise still retrieve that project's items purely from
    /// project-match/recency/confidence, none of which say anything about whether the item is
    /// actually about what's being asked. A blended relevance SCORE can't gate this reliably
    /// (project-match alone contributes a flat amount regardless of topic), so this reruns the
    /// same keyword-overlap check retrieval already uses internally, this time directly
    /// against the question.
    /// Work-item lifecycle is always annotated and the work-state fallback below is always
    /// active. Both were once switchable so a controlled ON/OFF ablation could measure them;
    /// both measured VALID with no harm, so the switches are gone and this renders one way in
    /// Debug and Release alike. (Neither ablation demonstrated a measurable answer-level gain -
    /// see PHASES.md - but both mechanisms are sound and cost nothing when they do not apply.)
    static func format(_ packet: ContextPacket, questionText: String) -> String {
        var sections: [String] = []

        if !packet.proceduralInstructions.isEmpty {
            sections.append(
                "PROCEDURAL INSTRUCTIONS (always follow these, regardless of what the newest message is about):\n"
                    + bulletList(packet.proceduralInstructions)
            )
        }

        // The STRICT gate result. These four arrays are what the grounding directive is computed
        // from, below, and the work-state fallback deliberately does not touch them - see
        // `workStateWasEntirelyDeleted`.
        let relevantMemories = packet.relevantMemories.filter { isRelevant($0, to: questionText) }
        let strictProjectItems = packet.relevantProjectItems.filter { isRelevant($0, to: questionText) }
        let strictDecisions = packet.relevantDecisions.filter { isRelevant($0, to: questionText) }

        // WORK-STATE FALLBACK FOR SUBJECTLESS FOLLOW-UPS.
        //
        // Measured defect, reproduced against the real fixture: for a question carrying no subject
        // of its own, the lexical gate deletes EVERYTHING. "What did we eventually decide to use
        // instead?" admits 0 of 6 project items and 0 of 3 decisions - the Decision layer
        // contributes nothing to the question literally asking what was decided. It passed Phase
        // 4.2 only because ungated raw transcript excerpts happened to carry the answer.
        //
        // The hard part is that the SAME gate is what makes the negative-retrieval and
        // cross-project-trap questions pass, and that behaviour is pinned by
        // `MultiMeetingScenarioIntegrationTests.testUnrelatedWeatherQuestionDoesNotInjectProject\
        // Context`: an unrelated question must get NO project content, even in a session linked to
        // an active project. A first attempt at this fallback keyed on "the gate deleted every
        // layer", which is true of the weather question too, and duly broke that test. That
        // failure is what identified the correct discriminator.
        //
        // The discriminator is whether the question has a SUBJECT AT ALL, which is exactly what
        // `distinctiveTokens` already computes for the grounding directive:
        //
        //   "What did we eventually decide to use instead?" -> {} (every token is scaffolding)
        //   "What is the weather forecast tomorrow?"        -> {weather, forecast, tomorrow}
        //
        // A question with no distinctive tokens is a pure FOLLOW-UP - it carries its subject in the
        // conversation, not in its own words - so there is nothing for a lexical gate to match on
        // and deleting the whole layer is not a judgment, it is an artefact. A question that DOES
        // name a subject is judged exactly as before: if its subject is absent from the evidence it
        // stays off-topic and gets nothing. So no question that previously rendered work state
        // changes, and no off-topic question starts rendering any.
        //
        // This is also why the fallback and the grounding directive never interact: the directive
        // is suppressed precisely when `distinctiveTokens` is empty (see `hasDistinctiveCoverage`),
        // which is precisely when this fires. They are two consequences of the same condition, not
        // two mechanisms racing.
        //
        // Scoped as narrowly as the evidence justifies:
        // - only PROJECT ITEMS and DECISIONS, the two work-state layers measured as lost. Memories
        //   (personal facts) and episodes stay strictly gated in every case.
        // - only when the gate emptied BOTH of those layers. A partially-admitted layer is
        //   untouched.
        // - only the top `workStateFallbackLimit` by the score retrieval already computed - no new
        //   scoring mechanism and no second notion of relevance.
        //
        // LIVE-VALIDATED by a controlled ON/OFF ablation over the 12-question benchmark: it was
        // sensitive on exactly the one subjectless question, restored 3 relevant items and 3
        // relevant decisions there, and was completely inert everywhere else - including both
        // uncovered-subject traps, which admitted nothing in either arm. See PHASES.md.
        let questionHasNoSubjectOfItsOwn = distinctiveTokens(in: questionText).isEmpty
        let workStateWasEntirelyDeleted = strictProjectItems.isEmpty && strictDecisions.isEmpty
            && !(packet.relevantProjectItems.isEmpty && packet.relevantDecisions.isEmpty)
        let useFallback = questionHasNoSubjectOfItsOwn && workStateWasEntirelyDeleted

        let relevantProjectItems = useFallback
            ? topScored(packet.relevantProjectItems, limit: workStateFallbackLimit)
            : strictProjectItems
        let relevantDecisions = useFallback
            ? topScored(packet.relevantDecisions, limit: workStateFallbackLimit)
            : strictDecisions

        let currentSection = renderTemporalGroup(
            title: "CURRENT KNOWLEDGE (reflects the latest known state - use this when asked what is true NOW)",
            memories: relevantMemories.filter(isCurrent),
            projectItems: relevantProjectItems.filter(isCurrent),
            decisions: relevantDecisions.filter(isCurrent),
        )
        if let currentSection { sections.append(currentSection) }

        let historicalSection = renderTemporalGroup(
            title: "HISTORICAL / PRIOR CONTEXT (describes something that used to be true, or has since "
                + "changed - NEVER state this as current fact; only use it for \"before\"/\"why did we "
                + "change\"/\"when was this decided\"-type questions)",
            memories: relevantMemories.filter { !isCurrent($0) },
            projectItems: relevantProjectItems.filter { !isCurrent($0) },
            decisions: relevantDecisions.filter { !isCurrent($0) },
            statusTag: true,
        )
        if let historicalSection { sections.append(historicalSection) }

        // What counts toward the question actually being COVERED: the topic-gated evidence only.
        //
        // `historicalEvidence` is deliberately excluded (it is exempt from the topic gate above,
        // so it would let ungated past messages vouch for coverage they never established), and
        // so are `proceduralInstructions` (always-on behavioral rules, never subject matter).
        // They both still appear in the rendered context - this governs the directive only.
        // STRICT arrays on purpose - never the fallback-widened ones. Coverage is a claim about
        // whether the question is actually ANSWERED by stored context, and an item admitted only
        // because the gate would otherwise have deleted everything is precisely an item that did
        // not earn that claim. Reading `relevantProjectItems`/`relevantDecisions` here instead
        // would let the fallback suppress the grounding directive on exactly the off-topic
        // questions it exists to catch, which is the Phase 4.2 regression risk this avoids.
        var topicalEvidenceTexts = relevantMemories.map(\.renderedText)
            + strictProjectItems.map(\.renderedText)
            + strictDecisions.map(\.renderedText)

        let relevantEpisodes = packet.relevantEpisodes.filter { isRelevant($0, to: questionText) }
        topicalEvidenceTexts += relevantEpisodes.map(\.renderedText)
        if !relevantEpisodes.isEmpty {
            sections.append(
                "RELATED PAST EPISODES (summaries of earlier, related conversations - background only):\n"
                    + bulletList(relevantEpisodes)
            )
        }

        // Historical evidence is exempt from the topic gate: it only ever exists in the packet
        // because it was resolved from an ALREADY-relevant item's own provenance (see
        // ContextEngine.collectReferences) - it doesn't need to independently re-prove
        // relevance to the question the same way retrieval's own top-`limit` results do.
        let relevantHistoricalEvidence = packet.historicalEvidence
        if !relevantHistoricalEvidence.isEmpty {
            let lines = relevantHistoricalEvidence.map { "- \"\($0.renderedText)\"" }.joined(separator: "\n")
            sections.append("RELEVANT PAST MESSAGES (verbatim excerpts from an earlier conversation):\n" + lines)
        }

        let header = """
        STORED CONTEXT FROM FRIDAY'S MEMORY AND PROJECT HISTORY
        Everything below was retrieved from previously stored memory, project state, decisions, \
        and past conversations - NOT from the current conversation above. Use it only if it is \
        actually relevant to the newest message. Do not repeat or list it unprompted.
        """

        guard !sections.isEmpty else {
            return header + "\n\nNo stored memory, project, or decision context was found to be "
                + "relevant to the newest message. If asked about something from a prior "
                + "conversation or earlier project history that isn't shown here, say plainly "
                + "that you don't have that stored - do not guess or invent one."
        }

        // A non-empty block is NOT the same as a block that actually answers the question. The
        // grounding directive above used to be reachable only when EVERY section was empty,
        // which is why an off-topic question could still get a confident, entirely invented
        // answer: a single item matching on a generic word, plus ungated past messages, made the
        // packet look substantive while containing nothing on the actual subject.
        if !hasDistinctiveCoverage(questionText: questionText, evidenceTexts: topicalEvidenceTexts) {
            sections.append(insufficientEvidenceDirective)
        }

        return header + "\n\n" + sections.joined(separator: "\n\n")
    }

    /// Deliberately CONDITIONAL rather than a hard refusal order, and deliberately scoped to the
    /// stored-context block rather than the assistant's behavior in general: a question the
    /// stored context genuinely covers must still be answered normally, and ordinary
    /// general-knowledge questions (weather, code, definitions) are none of this block's
    /// business. It only forbids answering about the USER'S OWN work from outside knowledge.
    private static let insufficientEvidenceDirective = """
    EVIDENCE CHECK - the stored context above does not appear to cover what the newest message \
    is actually asking about. If the answer isn't there, say plainly that you don't have it \
    stored for this project, and stop - do not fill the gap from general knowledge, and do not \
    describe how this kind of work is usually done as if it were what the user actually did. \
    If part of the question IS covered above, answer that part from the stored context and say \
    what you don't have. Never answer from another project's information.
    """

    /// True when at least one DISTINCTIVE token from the question appears somewhere in the
    /// topic-gated evidence.
    ///
    /// "Distinctive" excludes the generic conversational/project vocabulary that carries no
    /// subject matter - the exact loophole behind the observed failure, where
    /// "What was our approach to X?" matched a completely unrelated decision purely on the word
    /// "approach". Matching itself reuses `RelevanceScoring.keywordOverlap` rather than a second
    /// scoring mechanism, so a token counts as present here on precisely the same terms
    /// retrieval already uses.
    ///
    /// Returns TRUE when the question has no distinctive tokens at all (e.g. "what was that
    /// again?"): a pure follow-up carries its subject in the conversation, not in its own words,
    /// so demanding topical coverage there would nag about perfectly answerable questions.
    private static func hasDistinctiveCoverage(questionText: String, evidenceTexts: [String]) -> Bool {
        let tokens = distinctiveTokens(in: questionText)
        guard !tokens.isEmpty else { return true }
        let haystack = evidenceTexts.joined(separator: "\n")
        guard !haystack.isEmpty else { return false }
        return tokens.contains { RelevanceScoring.keywordOverlap(query: $0, text: haystack) > 0 }
    }

    /// Whether a question names a SUBJECT of its own, as opposed to being a pure follow-up that
    /// carries its subject in the conversation. This is the exact condition the Phase 4.4
    /// work-state fallback keys on, exposed (rather than duplicated) so the experiment harness
    /// classifies questions by the same rule the mechanism uses - a second, drifting copy of
    /// this predicate would let the analysis disagree with the behaviour it is measuring.
    static func hasDistinctiveSubject(_ questionText: String) -> Bool {
        !distinctiveTokens(in: questionText).isEmpty
    }

    /// Same tokenization rule `RelevanceScoring.tokenize` applies (lowercased, split on
    /// non-alphanumerics, tokens longer than 2 characters), minus `genericTokens`. Reimplemented
    /// here only because that helper is private to `RelevanceScoring`, which is out of scope to
    /// modify; the rule is identical so the two cannot disagree about what a token is.
    private static func distinctiveTokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        ).subtracting(genericTokens)
    }

    /// Words that survive tokenization (longer than 2 characters) but say nothing about SUBJECT
    /// MATTER - ordinary question scaffolding plus the generic project/work vocabulary that
    /// appears in nearly every stored item. Kept deliberately small and subject-neutral: it
    /// contains no domain terms, so it can never encode which topics are answerable.
    private static let genericTokens: Set<String> = [
        // Generic project/work vocabulary.
        "approach", "approaches", "project", "projects", "work", "working", "thing", "things",
        "use", "used", "using", "stuff", "item", "items", "team",
        // Phase 4.4 - the vocabulary of REFERRING to a choice, as opposed to naming its subject.
        // "What did we eventually decide to use instead?" is built entirely from these plus
        // scaffolding, which is what makes it recognisable as a subjectless follow-up rather than
        // an off-topic question. Every word here describes the ACT of choosing; none of them can
        // name a topic, so this cannot make a genuinely off-topic question look subjectless.
        "decide", "decides", "decided", "deciding", "decision", "decisions", "instead",
        "eventually", "finally", "choose", "chose", "chosen", "choice", "pick", "picked",
        "settled", "opted", "conclusion", "concluded",
        // Question scaffolding and common function words over 2 characters.
        "what", "was", "were", "our", "ours", "the", "and", "for", "with", "about", "that",
        "this", "these", "those", "did", "does", "done", "how", "why", "when", "where", "who",
        "you", "your", "yours", "are", "its", "from", "into", "than", "then", "there", "here",
        "they", "them", "their", "have", "has", "had", "been", "being", "just", "like", "some",
        "any", "all", "can", "could", "would", "should", "will", "want", "need", "tell", "say",
        "said", "get", "got", "make", "made", "give", "gave", "put", "let", "now", "not", "but",
        "out", "off", "over", "under", "more", "most", "much", "many", "one", "two", "own",
    ]

    /// How many items per work-state layer the Phase 4.4 fallback may admit when the strict gate
    /// deleted the layer outright. Deliberately small: the point is to stop the layer being
    /// EMPTY, not to bypass the gate. Rendered Phase 4.2 contexts ran 2712-6107 characters against
    /// a 6000-character evidence budget, so a handful of extra bullets fits the existing headroom
    /// (`ContextEngine` still applies that budget after this, unchanged).
    private static let workStateFallbackLimit = 3

    /// Highest-scored first, using the score `RelevanceScoring` already computed at retrieval -
    /// no second ranking system. Ties keep the packet's own order (`enumerated()` makes the sort
    /// stable without relying on `sorted(by:)`'s unspecified equal-element behaviour), so the
    /// output is fully deterministic for a given packet.
    private static func topScored<T>(_ evidence: [ScoredEvidence<T>], limit: Int) -> [ScoredEvidence<T>] {
        evidence.enumerated()
            .sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }
            .prefix(limit)
            .map(\.element)
    }

    private static func isCurrent<T>(_ evidence: ScoredEvidence<T>) -> Bool {
        evidence.temporalStatus == .current || evidence.temporalStatus == .unknown
    }

    /// True if the evidence shares at least one real word with the question - the same
    /// tokenization `RelevanceScoring.keywordOverlap` already uses (case-insensitive, tokens
    /// longer than 2 characters), reused rather than reimplemented. An item already in the
    /// packet purely because of recency/confidence/project-match, with zero actual textual
    /// connection to what's being asked, is exactly the "off-topic project noise" this gate
    /// exists to keep out of the prompt.
    private static func isRelevant<T>(_ evidence: ScoredEvidence<T>, to questionText: String) -> Bool {
        RelevanceScoring.keywordOverlap(query: questionText, text: evidence.renderedText) > 0
    }

    private static func renderTemporalGroup(
        title: String,
        memories: [ScoredEvidence<MemoryEdge>],
        projectItems: [ScoredEvidence<ProjectItem>],
        decisions: [ScoredEvidence<Decision>],
        statusTag: Bool = false
    ) -> String? {
        var lines: [String] = []
        if !memories.isEmpty {
            lines.append("From stored memory:\n" + bulletList(memories, statusTag: statusTag))
        }
        if !projectItems.isEmpty {
            // Phase 4.5: project items additionally carry their LIFECYCLE state. This reuses the
            // one existing bullet-rendering path rather than introducing a second status
            // representation - `lifecycleAnnotation` is simply a second, type-specific
            // annotation appended after the (unchanged) TemporalStatus one.
            lines.append("From project state:\n" + bulletList(
                projectItems,
                statusTag: statusTag,
                lifecycleAnnotation: { lifecycleSuffix($0.value.status) }
            ))
        }
        if !decisions.isEmpty {
            lines.append("From decisions:\n" + bulletList(decisions, statusTag: statusTag))
        }
        guard !lines.isEmpty else { return nil }
        return title + ":\n" + lines.joined(separator: "\n")
    }

    /// `lifecycleAnnotation` defaults to contributing nothing, so memories and decisions render
    /// EXACTLY as they did before Phase 4.5 - only project items pass a non-empty closure.
    private static func bulletList<T>(
        _ items: [ScoredEvidence<T>],
        statusTag: Bool = false,
        lifecycleAnnotation: (ScoredEvidence<T>) -> String = { _ in "" }
    ) -> String {
        items.map { "- \($0.renderedText)\(lifecycleAnnotation($0))\(statusTag ? statusSuffix($0.temporalStatus) : "")" }
            .joined(separator: "\n")
    }

    /// Phase 4.5 - a `ProjectItem`'s own lifecycle state, which was previously stored, extracted
    /// and used for temporal admissibility but NEVER shown to the model: a planned task, a
    /// blocked one and a completed one all rendered as identical bullets, so "what's still open?"
    /// was unanswerable from the assembled context.
    ///
    /// DISTINCT FROM `statusSuffix(_:)`, which renders `TemporalStatus` (is this evidence current
    /// or superseded?). Both can appear on the same bullet - lifecycle first, then temporal - and
    /// neither replaces the other. Every case is spelled from the existing `ProjectItem.Status`
    /// enum; no status is invented, and `inProgress` is the only one that needs re-spacing to
    /// read naturally.
    private static func lifecycleSuffix(_ status: ProjectItem.Status) -> String {
        switch status {
        case .proposed: return " [proposed]"
        case .planned: return " [planned]"
        case .active: return " [active]"
        case .inProgress: return " [in progress]"
        case .blocked: return " [blocked]"
        case .completed: return " [completed]"
        case .achieved: return " [achieved]"
        case .resolved: return " [resolved]"
        case .abandoned: return " [abandoned]"
        }
    }

    /// Uncertainty labeling, per item - the only place `TemporalStatus` gets translated into
    /// prose. Superseded/invalidated evidence is always tagged explicitly so it can never be
    /// mistaken for current truth even if a caller changed the section grouping above.
    private static func statusSuffix(_ status: TemporalStatus) -> String {
        switch status {
        case .current: return ""
        case .historical: return " [historical]"
        case .superseded: return " [superseded - no longer current]"
        case .invalidated: return " [previously stated, later retracted]"
        case .unknown: return " [uncertain]"
        }
    }
}
