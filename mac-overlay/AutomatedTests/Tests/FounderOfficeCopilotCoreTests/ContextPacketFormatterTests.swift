import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `ContextPacketFormatter` - the deterministic `ContextPacket -> model-context text`
/// layer. Every test constructs a `ContextPacket`/`ScoredEvidence` directly, so formatting is
/// verified in complete isolation from retrieval/scoring/conflict-resolution. `questionText`
/// is passed explicitly to every call, matching the real signature - most tests use a question
/// that deliberately shares a keyword with the evidence under test, since the formatter now
/// gates on that (see `ContextPacketFormatter.isRelevant`).
final class ContextPacketFormatterTests: XCTestCase {
    private func makeMemoryEvidence(renderedText: String, score: Double = 0.9, temporalStatus: TemporalStatus = .current) -> ScoredEvidence<MemoryEdge> {
        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "fact", literalValue: renderedText, category: .fact, confidence: 0.9, sourceSessionID: UUID())
        return ScoredEvidence(value: edge, source: .memoryEdge(edge.id), score: score, temporalStatus: temporalStatus, provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: renderedText)
    }

    private func makeDecisionEvidence(renderedText: String, score: Double = 0.9, temporalStatus: TemporalStatus = .current) -> ScoredEvidence<Decision> {
        let decision = Decision(projectID: UUID(), statement: renderedText, sourceSessionID: UUID())
        return ScoredEvidence(value: decision, source: .decision(decision.id), score: score, temporalStatus: temporalStatus, provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: renderedText)
    }

    // MARK: No-memory case

    func testEmptyPacketExplicitlySaysNothingWasFound() {
        let text = ContextPacketFormatter.format(.empty, questionText: "anything")
        XCTAssertTrue(text.lowercased().contains("no stored memory"), "the model must be explicitly told nothing was found, not left to infer it from an absent section")
        XCTAssertTrue(text.lowercased().contains("don't have that stored") || text.lowercased().contains("do not guess"))
    }

    func testEmptyPacketNeverMentionsFabricatedCategoryHeadings() {
        let text = ContextPacketFormatter.format(.empty, questionText: "anything")
        XCTAssertFalse(text.contains("CURRENT KNOWLEDGE"))
        XCTAssertFalse(text.contains("HISTORICAL"))
    }

    // MARK: Category distinction

    func testMemoryProjectDecisionAndEpisodeGetDistinctHeadings() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "prefers dark mode")]
        packet.relevantProjectItems = [ScoredEvidence(
            value: ProjectItem(projectID: UUID(), kind: .task, name: "Ship retrieval", sourceSessionID: UUID()),
            source: .projectItem(UUID()), score: 0.9, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: "Ship retrieval"
        )]
        packet.relevantDecisions = [makeDecisionEvidence(renderedText: "Use PostgreSQL")]
        packet.relevantEpisodes = [ScoredEvidence(
            value: EpisodeSummary(sessionID: UUID(), meetingID: nil, title: "Sync", occurredAt: Date(), participantEntityIDs: [], decisions: [], projectItems: [], projectEvents: [], checkpointSummary: nil, sourceMessageIDs: []),
            source: .episode(sessionID: UUID()), score: 0.9, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: "Sync meeting"
        )]

        // One question that shares a keyword with every category above.
        let text = ContextPacketFormatter.format(packet, questionText: "dark mode retrieval PostgreSQL sync meeting")
        XCTAssertTrue(text.contains("From stored memory:"))
        XCTAssertTrue(text.contains("From project state:"))
        XCTAssertTrue(text.contains("From decisions:"))
        XCTAssertTrue(text.contains("RELATED PAST EPISODES"))
        XCTAssertTrue(text.contains("prefers dark mode"))
        XCTAssertTrue(text.contains("Ship retrieval"))
        XCTAssertTrue(text.contains("Use PostgreSQL"))
        XCTAssertTrue(text.contains("Sync meeting"))
    }

    // MARK: Current vs historical distinction

    func testCurrentAndHistoricalGoUnderSeparateHeadings() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [
            makeMemoryEvidence(renderedText: "database PostgreSQL", temporalStatus: .current),
            makeMemoryEvidence(renderedText: "database MongoDB", temporalStatus: .superseded),
        ]

        let text = ContextPacketFormatter.format(packet, questionText: "what database do we use")
        let currentRange = text.range(of: "CURRENT KNOWLEDGE")
        let historicalRange = text.range(of: "HISTORICAL / PRIOR CONTEXT")
        let postgresRange = text.range(of: "database PostgreSQL")
        let mongoRange = text.range(of: "database MongoDB")

        XCTAssertNotNil(currentRange)
        XCTAssertNotNil(historicalRange)
        XCTAssertNotNil(postgresRange)
        XCTAssertNotNil(mongoRange)
        // PostgreSQL (current) must appear before the HISTORICAL heading; MongoDB (superseded)
        // must appear after it - proving they landed in different sections, not just that both
        // strings are present somewhere.
        XCTAssertTrue(postgresRange!.lowerBound < historicalRange!.lowerBound)
        XCTAssertTrue(mongoRange!.lowerBound > historicalRange!.lowerBound)
    }

    func testSupersededEvidenceIsNeverPresentedAsCurrentTruth() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "database MongoDB", temporalStatus: .superseded)]

        let text = ContextPacketFormatter.format(packet, questionText: "what database do we use")
        XCTAssertFalse(text.contains("CURRENT KNOWLEDGE"), "with only superseded evidence, no CURRENT section should exist at all")
        XCTAssertTrue(text.contains("[superseded - no longer current]"))
    }

    func testInvalidatedEvidenceIsTaggedDistinctlyFromSuperseded() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "old retracted fact", temporalStatus: .invalidated)]

        let text = ContextPacketFormatter.format(packet, questionText: "tell me about the retracted fact")
        XCTAssertTrue(text.contains("[previously stated, later retracted]"))
    }

    func testCurrentEvidenceHasNoUncertaintyTag() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "database PostgreSQL", temporalStatus: .current)]

        let text = ContextPacketFormatter.format(packet, questionText: "what database do we use")
        XCTAssertTrue(text.contains("database PostgreSQL"))
        XCTAssertFalse(text.contains("["), "current-only evidence must carry no bracketed uncertainty tag anywhere")
    }

    // MARK: Procedural instructions

    func testProceduralInstructionsGetTheirOwnAlwaysRelevantHeadingRegardlessOfTopicOrScore() {
        var packet = ContextPacket.empty
        packet.proceduralInstructions = [makeMemoryEvidence(renderedText: "always be concise", score: 0.01)]

        // Question shares zero keywords with "always be concise" and the evidence has a
        // near-zero score - procedural instructions must still appear, exempt from both the
        // topic gate and any score consideration.
        let text = ContextPacketFormatter.format(packet, questionText: "what's the weather like today")
        XCTAssertTrue(text.contains("PROCEDURAL INSTRUCTIONS"))
        XCTAssertTrue(text.contains("always be concise"))
    }

    // MARK: Topic gate (don't dump the whole packet blindly / don't leak unrelated evidence)

    func testEvidenceSharingNoKeywordWithTheQuestionIsExcludedAsNoise() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "database PostgreSQL", score: 0.9)]

        let text = ContextPacketFormatter.format(packet, questionText: "what's the weather like today")
        XCTAssertFalse(text.contains("database PostgreSQL"), "evidence with zero textual connection to the question must not be injected, regardless of its own score")
        XCTAssertTrue(text.lowercased().contains("no stored memory"), "with everything filtered out, this must fall back to the explicit nothing-found message")
    }

    func testHighScoreAloneDoesNotBypassTheTopicGate() {
        // Explicitly proves the fix the audit's realistic scenario surfaced: a high blended
        // score (e.g. from project-match/recency/confidence alone) must NOT be sufficient by
        // itself - the evidence still has to share a real word with the question.
        var packet = ContextPacket.empty
        packet.relevantProjectItems = [ScoredEvidence(
            value: ProjectItem(projectID: UUID(), kind: .task, name: "Temperature scaling", sourceSessionID: UUID()),
            source: .projectItem(UUID()), score: 0.95, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: "Temperature scaling"
        )]

        let text = ContextPacketFormatter.format(packet, questionText: "what's the weather like today")
        XCTAssertFalse(text.contains("Temperature scaling"))
    }

    func testEvidenceSharingAKeywordWithTheQuestionIsIncluded() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "clearly relevant calibration fact")]

        let text = ContextPacketFormatter.format(packet, questionText: "what's the status of calibration")
        XCTAssertTrue(text.contains("clearly relevant calibration fact"))
    }

    // MARK: Historical evidence (verbatim excerpts) - exempt from the topic gate

    func testHistoricalEvidenceIsRenderedAsQuotedVerbatimExcerpts() {
        var packet = ContextPacket.empty
        let message = ChatMessage(role: .heard, text: "the professor suggested Bayesian calibration")
        packet.historicalEvidence = [ScoredEvidence(
            value: message, source: .chatMessage(sessionID: UUID(), messageID: message.id), score: 1.0, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: message.text
        )]

        // Deliberately unrelated question text - historical evidence is exempt from the topic
        // gate since it only ever appears via an already-relevant item's own provenance.
        let text = ContextPacketFormatter.format(packet, questionText: "totally unrelated words")
        XCTAssertTrue(text.contains("RELEVANT PAST MESSAGES"))
        XCTAssertTrue(text.contains("\"the professor suggested Bayesian calibration\""))
    }

    // MARK: Evidence sufficiency / negative retrieval
    //
    // Regression coverage for a verified live failure: asked "What was our approach to hotel
    // demand forecasting?" inside a project that had never discussed hotels, retrieval correctly
    // returned ONLY that project's own (multi-agent AI) material - and the assistant answered
    // with a confident, entirely invented hotel revenue-management writeup. Retrieval and
    // project isolation were fine; the prompt simply never told the model that the stored
    // context didn't cover the question, because the grounding directive was reachable only when
    // EVERY section was empty.
    //
    // These prove the PROMPT now carries the directive. Whether the model then complies is a
    // live-model property no offline test can assert.

    /// The NEW directive, which applies when evidence survived the topic gate but doesn't cover
    /// the question.
    private func isSufficiencyDirectivePresent(_ text: String) -> Bool {
        text.contains("EVIDENCE CHECK")
    }

    /// Either form of grounding guidance: the new sufficiency directive, or the pre-existing
    /// empty-packet wording. Which one applies depends on whether any evidence survived the
    /// item-level topic gate - both tell the model not to invent an answer, which is the
    /// behaviour that actually matters.
    private func hasGroundingGuidance(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return isSufficiencyDirectivePresent(text)
            || (lowered.contains("don't have that stored") && lowered.contains("do not guess"))
    }

    /// A: a distinctive question token appears in the gated evidence - evidence is rendered and
    /// the directive stays out of the way.
    func testDistinctiveCoverageRendersEvidenceAndEmitsNoSufficiencyDirective() {
        var packet = ContextPacket.empty
        packet.relevantDecisions = [makeDecisionEvidence(renderedText: "Adopted MC dropout for uncertainty calibration in the gridworld")]

        let text = ContextPacketFormatter.format(packet, questionText: "What was our approach to uncertainty calibration?")

        XCTAssertTrue(text.contains("Adopted MC dropout for uncertainty calibration in the gridworld"))
        XCTAssertFalse(isSufficiencyDirectivePresent(text), "evidence genuinely covers the question - the model must be free to answer normally")
    }

    /// B: evidence exists but shares nothing distinctive with the question.
    func testCompletelyUnrelatedEvidenceEmitsTheSufficiencyDirective() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "prefers dark mode in the editor")]

        let text = ContextPacketFormatter.format(packet, questionText: "What was our quarterly revenue forecast?")

        // Nothing shares even a generic token here, so the item-level gate drops it and the
        // pre-existing empty-packet grounding applies - either way the model is told.
        XCTAssertTrue(hasGroundingGuidance(text), "nothing here covers the question - the model must be told so")
        XCTAssertFalse(text.contains("prefers dark mode"), "off-topic evidence is gated out, as before this change")
    }

    /// C: THE EXACT observed mechanism - the only overlap is the generic word "approach", which
    /// must not count as the question being covered.
    func testGenericTokenOverlapAloneIsNotSufficientEvidence() {
        var packet = ContextPacket.empty
        packet.relevantDecisions = [makeDecisionEvidence(
            renderedText: "Rejected Conformal Prediction Uncertainty quantification approach in 5-agent gridworld simulation"
        )]

        let text = ContextPacketFormatter.format(packet, questionText: "What was our approach to hotel demand forecasting?")

        // The item still passes the existing topic gate on "approach" and is still rendered -
        // retrieval behavior is unchanged.
        XCTAssertTrue(text.contains("Rejected Conformal Prediction"))
        // ...but the question is NOT covered, so the directive fires.
        XCTAssertTrue(isSufficiencyDirectivePresent(text), "a generic-word match must not pass as topical coverage - this is the exact failure being fixed")
    }

    /// D: historical past messages may stay in the context, but cannot by themselves make a
    /// packet look sufficient - the other half of the observed failure.
    func testHistoricalEvidenceAloneCannotSatisfyTheSufficiencyCheck() {
        var packet = ContextPacket.empty
        let message = ChatMessage(role: .heard, text: "Prof. Aris Thorne: how did those calibration plots turn out from the gridworld runs?")
        packet.historicalEvidence = [ScoredEvidence(
            value: message, source: .chatMessage(sessionID: UUID(), messageID: message.id), score: 0.9, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: message.text
        )]

        let text = ContextPacketFormatter.format(packet, questionText: "What was our approach to hotel demand forecasting?")

        XCTAssertTrue(text.contains("RELEVANT PAST MESSAGES"), "historical evidence is still shown - this fix does not remove it")
        XCTAssertTrue(isSufficiencyDirectivePresent(text), "ungated past messages must not vouch for coverage they never established")
    }

    /// E: evidence belongs to the ACTIVE project but is topically unrelated. The directive fires,
    /// and nothing pulls in another project's material to satisfy the question.
    func testOffTopicActiveProjectEvidenceEmitsTheDirectiveAndLeaksNoOtherProject() {
        let activeProjectID = UUID()
        var packet = ContextPacket.empty
        packet.activeProjectID = activeProjectID
        // Phrased so it shares the generic word "approach" with the question - i.e. it SURVIVES
        // the topic gate, exactly as the real off-topic evidence did, and therefore exercises
        // the new sufficiency path rather than the empty-packet branch.
        packet.relevantProjectItems = [ScoredEvidence(
            value: ProjectItem(projectID: activeProjectID, kind: .task, name: "Approach for the gridworld search-and-rescue environment", sourceSessionID: UUID()),
            source: .projectItem(UUID()), score: 0.9, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()),
            renderedText: "Approach for the gridworld search-and-rescue environment"
        )]

        let text = ContextPacketFormatter.format(packet, questionText: "What was our approach to hotel demand forecasting?")

        XCTAssertTrue(isSufficiencyDirectivePresent(text))
        XCTAssertTrue(text.contains("Never answer from another project's information."))
        // The formatter renders only what it was given - it can never introduce another
        // project's evidence, which is what keeps isolation intact.
        for leaked in ["hotel", "revenue", "booking", "seasonality", "ADR", "occupancy"] {
            XCTAssertFalse(text.lowercased().contains(leaked.lowercased()) && !text.contains("hotel demand forecasting"),
                           "no other project's material may appear: found \(leaked)")
        }
    }

    /// A pure follow-up carries its subject in the conversation, not in its own words - demanding
    /// topical coverage there would nag about perfectly answerable questions.
    func testFollowUpWithNoDistinctiveTokensDoesNotEmitTheDirective() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "prefers dark mode in the editor")]

        let text = ContextPacketFormatter.format(packet, questionText: "what was that?")

        XCTAssertFalse(isSufficiencyDirectivePresent(text))
    }

    /// The directive is scoped to STORED CONTEXT - it must never read as a blanket ban on the
    /// assistant's general knowledge.
    func testTheDirectiveIsScopedToStoredContextAndNotAGlobalKnowledgeBan() {
        var packet = ContextPacket.empty
        // Shares only the generic word "approach", so the sufficiency directive is what fires.
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "the team's approach to editor theming")]

        let text = ContextPacketFormatter.format(packet, questionText: "What was our approach to quarterly revenue forecasting?")

        XCTAssertTrue(isSufficiencyDirectivePresent(text))

        XCTAssertTrue(text.contains("stored for this project"))
        XCTAssertTrue(text.contains("If part of the question IS covered above, answer that part"))
        for banned in ["never use general knowledge", "do not use your own knowledge", "only answer from stored context"] {
            XCTAssertFalse(text.lowercased().contains(banned))
        }
    }

    // MARK: Header framing

    func testHeaderExplainsContextIsNotFromTheCurrentConversation() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "some relevant fact")]
        let text = ContextPacketFormatter.format(packet, questionText: "tell me about the relevant fact")
        XCTAssertTrue(text.contains("STORED CONTEXT FROM FRIDAY'S MEMORY AND PROJECT HISTORY"))
        XCTAssertTrue(text.lowercased().contains("not from the current conversation"))
    }

    // MARK: Phase 4.5 - ProjectItem lifecycle status visibility
    //
    // `ProjectItem.status` was extracted, persisted and used for temporal admissibility, but was
    // never rendered: a planned task, a blocked one and a completed one reached the model as
    // identical bullets, so "what's still open?" could not be answered from the context. This
    // annotation is ADDITIONAL to the existing TemporalStatus tag, never a replacement.

    private func makeProjectItemEvidence(
        name: String,
        status: ProjectItem.Status,
        temporalStatus: TemporalStatus = .current,
        projectID: UUID = UUID()
    ) -> ScoredEvidence<ProjectItem> {
        let item = ProjectItem(projectID: projectID, kind: .task, name: name, status: status, sourceSessionID: UUID())
        return ScoredEvidence(
            value: item, source: .projectItem(item.id), score: 0.9, temporalStatus: temporalStatus,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: name
        )
    }

    private func formatted(_ items: [ScoredEvidence<ProjectItem>], question: String) -> String {
        var packet = ContextPacket.empty
        packet.relevantProjectItems = items
        return ContextPacketFormatter.format(packet, questionText: question)
    }

    /// 1-4: each lifecycle state renders, using the app's own enum vocabulary.
    func testPlannedInProgressBlockedAndCompletedEachRenderTheirStatus() {
        let cases: [(ProjectItem.Status, String)] = [
            (.planned, "[planned]"), (.inProgress, "[in progress]"), (.blocked, "[blocked]"), (.completed, "[completed]"),
        ]
        for (status, expected) in cases {
            let text = formatted([makeProjectItemEvidence(name: "Generate calibration curves", status: status)],
                                 question: "what about the calibration curves?")
            XCTAssertTrue(text.contains("- Generate calibration curves \(expected)"), "expected \(expected) in:\n\(text)")
        }
    }

    /// Every remaining status also renders - no ProjectItem.Status case is silently unlabelled.
    func testEveryProjectItemStatusRendersSomeAnnotation() {
        for status in ProjectItem.Status.allCases {
            let text = formatted([makeProjectItemEvidence(name: "Calibration work", status: status)],
                                 question: "tell me about the calibration work")
            XCTAssertTrue(text.contains("- Calibration work ["), "status \(status.rawValue) produced no annotation")
        }
    }

    /// 5: two otherwise identical items are distinguishable purely by status.
    func testTwoIdenticalItemsWithDifferentStatusesAreDistinguishable() {
        let text = formatted(
            [makeProjectItemEvidence(name: "Calibration sweep", status: .blocked),
             makeProjectItemEvidence(name: "Calibration sweep", status: .completed)],
            question: "how is the calibration sweep going?"
        )
        XCTAssertTrue(text.contains("- Calibration sweep [blocked]"))
        XCTAssertTrue(text.contains("- Calibration sweep [completed]"))
    }

    /// 6: `ProjectItem.status` is non-optional and defaults to `.proposed`; that default renders.
    func testDefaultStatusRendersRatherThanBeingOmitted() {
        let item = ProjectItem(projectID: UUID(), kind: .task, name: "Draft the paper", sourceSessionID: UUID())
        XCTAssertEqual(item.status, .proposed, "the model's own default")
        let evidence = ScoredEvidence(value: item, source: .projectItem(item.id), score: 0.9, temporalStatus: .current,
                                      provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: item.name)
        XCTAssertTrue(formatted([evidence], question: "what about the paper draft?").contains("- Draft the paper [proposed]"))
    }

    /// 7: a historical item keeps its TemporalStatus annotation AND gains the lifecycle one.
    func testHistoricalItemKeepsTemporalAnnotationAlongsideLifecycleStatus() {
        let text = formatted(
            [makeProjectItemEvidence(name: "Conformal prediction sweep", status: .abandoned, temporalStatus: .superseded)],
            question: "what happened to the conformal prediction sweep?"
        )
        XCTAssertTrue(text.contains("HISTORICAL"), "still grouped as historical")
        XCTAssertTrue(text.contains("- Conformal prediction sweep [abandoned] [superseded - no longer current]"),
                      "lifecycle first, then the unchanged temporal tag:\n\(text)")
    }

    /// 8 + 9: decisions and memories render EXACTLY as before - no lifecycle annotation leaks.
    func testDecisionAndMemoryRenderingAreUnchanged() {
        var packet = ContextPacket.empty
        packet.relevantDecisions = [makeDecisionEvidence(renderedText: "Use PostgreSQL")]
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "prefers PostgreSQL")]
        let text = ContextPacketFormatter.format(packet, questionText: "what did we choose, PostgreSQL?")

        XCTAssertTrue(text.contains("- Use PostgreSQL\n") || text.hasSuffix("- Use PostgreSQL"))
        XCTAssertTrue(text.contains("- prefers PostgreSQL"))
        XCTAssertFalse(text.contains("Use PostgreSQL ["), "a decision must not gain a lifecycle tag")
        XCTAssertFalse(text.contains("prefers PostgreSQL ["), "a memory must not gain a lifecycle tag")
    }

    /// 10: the Phase 4.2 grounding directive is byte-for-byte unchanged.
    func testEvidenceSufficiencyDirectiveIsUnchanged() {
        let text = formatted([makeProjectItemEvidence(name: "Approach for the gridworld environment", status: .planned)],
                             question: "What was our approach to hotel demand forecasting?")
        XCTAssertTrue(text.contains("""
        EVIDENCE CHECK - the stored context above does not appear to cover what the newest message \
        is actually asking about. If the answer isn't there, say plainly that you don't have it \
        stored for this project, and stop - do not fill the gap from general knowledge, and do not \
        describe how this kind of work is usually done as if it were what the user actually did. \
        If part of the question IS covered above, answer that part from the stored context and say \
        what you don't have. Never answer from another project's information.
        """))
    }

    /// 11: the admission gate is unchanged - a status annotation must never admit an item that
    /// the lexical gate would have dropped, and must not affect the gate's own decision.
    func testAdmissionGateBehaviourIsUnchanged() {
        let offTopic = formatted([makeProjectItemEvidence(name: "Gridworld environment setup", status: .blocked)],
                                 question: "what is our quarterly revenue forecast?")
        XCTAssertFalse(offTopic.contains("Gridworld environment setup"), "gated-out items stay gated out")
        XCTAssertFalse(offTopic.contains("[blocked]"), "no annotation may leak for a dropped item")

        let onTopic = formatted([makeProjectItemEvidence(name: "Gridworld environment setup", status: .blocked)],
                                question: "how is the gridworld environment setup going?")
        XCTAssertTrue(onTopic.contains("- Gridworld environment setup [blocked]"))
    }

    /// 12: annotations are bounded and cannot be used to bypass the evidence budget - the budget
    /// is applied upstream in ContextEngine, and the annotation adds a small fixed suffix only.
    func testStatusAnnotationAddsOnlyABoundedSuffix() {
        let name = "Calibration sweep"
        let withStatus = formatted([makeProjectItemEvidence(name: name, status: .inProgress)], question: "calibration sweep status?")
        let plainLine = "- \(name)"
        guard let range = withStatus.range(of: plainLine) else { return XCTFail("item not rendered") }
        let line = String(withStatus[range.lowerBound...]).components(separatedBy: "\n")[0]
        XCTAssertEqual(line, "- Calibration sweep [in progress]")
        XCTAssertLessThanOrEqual(line.count - plainLine.count, 20, "the annotation must stay a short fixed suffix")
    }

    /// 13: the formatter renders only what it is given - a status annotation cannot pull in or
    /// reveal another project's item.
    func testStatusAnnotationDoesNotAlterProjectScoping() {
        let projectA = UUID(), projectB = UUID()
        let mine = makeProjectItemEvidence(name: "Calibration sweep", status: .blocked, projectID: projectA)
        let text = formatted([mine], question: "how is the calibration sweep going?")

        XCTAssertTrue(text.contains("- Calibration sweep [blocked]"))
        XCTAssertFalse(text.contains(projectB.uuidString))
        XCTAssertEqual(mine.value.projectID, projectA)
    }

    /// 14: cross-layer dedup is untouched - a decision-linked item is still suppressed BEFORE
    /// formatting, so it never reaches the annotation path at all.
    func testCrossLayerDedupStillSuppressesLinkedItemsBeforeFormatting() {
        let projectID = UUID()
        let item = ProjectItem(projectID: projectID, kind: .component, name: "Conformal Prediction approach", status: .abandoned, sourceSessionID: UUID())
        let decision = Decision(projectID: projectID, statement: "Reject conformal prediction", relatedItemID: item.id, sourceSessionID: UUID())
        let provenance = Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date())
        let itemEvidence = ScoredEvidence(value: item, source: .projectItem(item.id), score: 0.8, temporalStatus: .current, provenance: provenance, renderedText: item.name)
        let decisionEvidence = ScoredEvidence(value: decision, source: .decision(decision.id), score: 0.9, temporalStatus: .current, provenance: provenance, renderedText: decision.statement)

        let resolved = CrossLayerConflictResolver.resolve(memories: [], projectItems: [itemEvidence], decisions: [decisionEvidence], intent: .current)
        XCTAssertTrue(resolved.projectItems.isEmpty, "dedup unchanged")

        var packet = ContextPacket.empty
        packet.relevantProjectItems = resolved.projectItems
        packet.relevantDecisions = [decisionEvidence]
        let text = ContextPacketFormatter.format(packet, questionText: "what did we decide about conformal prediction?")
        XCTAssertFalse(text.contains("[abandoned]"), "a suppressed item contributes no annotation")
    }


    // MARK: - Work-state admission fallback
    //
    // The gate deleted 57 of 139 retrieved evidence items across the Phase 4.2 benchmark. Against
    // the real CleanFixture text, "What did we eventually decide to use instead?" admits 0 of 6
    // project items and 0 of 3 decisions - the Decision layer contributes NOTHING to the question
    // literally asking what was decided. These use that exact question and the fixture's real item
    // and decision strings, so they fail if the defect ever returns.

    private static let subjectlessQuestion = "What did we eventually decide to use instead?"

    /// The real Project-A work state, verbatim from the CleanFixture snapshot.
    private func realWorkStatePacket() -> ContextPacket {
        var packet = ContextPacket.empty
        packet.relevantProjectItems = [
            makeProjectItemEvidence(name: "Conformal prediction calibration gridworld runs", status: .completed),
            makeProjectItemEvidence(name: "MC dropout calibration evaluation", status: .completed),
            makeProjectItemEvidence(name: "Fix message payload normalization layer", status: .completed),
            makeProjectItemEvidence(name: "Test temperature scaling versus MC dropout", status: .planned),
        ]
        packet.relevantDecisions = [
            makeDecisionEvidence(renderedText: "Rule out conformal prediction for message payload bounds"),
            makeDecisionEvidence(renderedText: "Reject decentralized Bayesian optimization for updating agent confidence"),
        ]
        return packet
    }

    /// THE DEFECT: a question with no subject-bearing tokens used to render no work state at all.
    func testSubjectlessQuestionStillSeesWorkStateInsteadOfNothing() {
        let text = ContextPacketFormatter.format(realWorkStatePacket(), questionText: Self.subjectlessQuestion)
        XCTAssertTrue(text.contains("From decisions:"), "the Decision layer must not be empty for a question asking what was decided")
        XCTAssertTrue(text.contains("From project state:"))
        XCTAssertTrue(text.contains("Rule out conformal prediction for message payload bounds"))
    }

    /// THE SAFETY PROPERTY. An off-topic question NAMES a subject, so it is not a follow-up and
    /// must be judged exactly as before: no work state, no memories, and the grounding directive
    /// firing. This is the Phase 4.2 negative-retrieval / cross-project-trap behaviour, and a
    /// first version of this fallback (keyed on "the gate deleted everything") broke it.
    func testOffTopicQuestionGetsNoWorkStateAndStillGetsTheDirective() {
        var packet = realWorkStatePacket()
        packet.relevantMemories = [makeMemoryEvidence(renderedText: "lives in Manchester")]
        let text = ContextPacketFormatter.format(packet, questionText: "What is the weather forecast tomorrow?")
        // Everything is gated out, so this takes the empty-packet branch - which carries the same
        // grounding guarantee in its own words rather than the EVIDENCE CHECK block.
        XCTAssertTrue(text.lowercased().contains("don't have that stored"), "a question that names an uncovered subject must still be told the context does not cover it")
        XCTAssertFalse(text.contains("From project state:"), "an off-topic question must never have project content injected")
        XCTAssertFalse(text.contains("From decisions:"))
        XCTAssertFalse(text.contains("lives in Manchester"))
    }

    /// The discriminator itself, asserted directly: a subjectless follow-up renders work state, a
    /// subject-bearing question with the SAME packet does not.
    func testOnlySubjectlessQuestionsTriggerTheFallback() {
        let packet = realWorkStatePacket()
        XCTAssertTrue(ContextPacketFormatter.format(packet, questionText: "So what did we finally pick?").contains("From decisions:"))
        XCTAssertFalse(ContextPacketFormatter.format(packet, questionText: "What did the quarterly revenue forecast say?").contains("From decisions:"))
    }

    /// The fallback is for total deletion only. A PARTIALLY admitted layer must be left exactly as
    /// the gate left it, so ordinary on-topic questions are completely unaffected.
    func testPartiallyAdmittedLayersAreLeftUntouched() {
        let text = ContextPacketFormatter.format(realWorkStatePacket(), questionText: "What is the status of the message payload normalization layer?")
        XCTAssertTrue(text.contains("Fix message payload normalization layer"))
        XCTAssertFalse(text.contains("Test temperature scaling versus MC dropout"), "an item the gate correctly excluded must not be re-admitted when the gate did its job")
    }

    /// The fallback is capped, and picks by the score retrieval already computed - not by order.
    func testFallbackAdmitsOnlyTheTopScoredItemsUpToTheCap() {
        var packet = ContextPacket.empty
        packet.relevantProjectItems = [
            evidenceScored("alpha component", 0.1), evidenceScored("beta component", 0.9),
            evidenceScored("gamma component", 0.8), evidenceScored("delta component", 0.7),
            evidenceScored("epsilon component", 0.6),
        ]
        let text = ContextPacketFormatter.format(packet, questionText: Self.subjectlessQuestion)
        for expected in ["beta component", "gamma component", "delta component"] {
            XCTAssertTrue(text.contains(expected), "expected top-scored \(expected)")
        }
        XCTAssertFalse(text.contains("alpha component"), "lowest-scored must be dropped by the cap")
        XCTAssertFalse(text.contains("epsilon component"))
    }

    /// Nothing retrieved still means nothing rendered - the fallback can never invent evidence.
    func testFallbackCannotInventEvidenceWhenNothingWasRetrieved() {
        let text = ContextPacketFormatter.format(.empty, questionText: Self.subjectlessQuestion)
        XCTAssertTrue(text.lowercased().contains("no stored memory"))
        XCTAssertFalse(text.contains("From project state:"))
        XCTAssertFalse(text.contains("From decisions:"))
    }

    /// Lifecycle annotations (Phase 4.5) still render on fallback-admitted items - the two features
    /// compose rather than one silently disabling the other.
    func testFallbackAdmittedItemsStillCarryLifecycleAnnotations() {
        let text = ContextPacketFormatter.format(realWorkStatePacket(), questionText: Self.subjectlessQuestion)
        XCTAssertTrue(text.contains("[completed]"))
    }

    private func evidenceScored(_ name: String, _ score: Double) -> ScoredEvidence<ProjectItem> {
        let item = ProjectItem(projectID: UUID(), kind: .component, name: name, sourceSessionID: UUID())
        return ScoredEvidence(
            value: item, source: .projectItem(item.id), score: score, temporalStatus: .current,
            provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()), renderedText: name
        )
    }
}
