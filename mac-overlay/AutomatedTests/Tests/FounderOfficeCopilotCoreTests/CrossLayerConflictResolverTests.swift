import XCTest
@testable import FounderOfficeCopilotCore

/// Covers `CrossLayerConflictResolver` - the pipeline stage the Stage 1-6 architecture audit
/// found missing: deterministic, explainable conflict resolution ACROSS evidence types
/// (Memory/ProjectItem/Decision), as opposed to the WITHIN-type supersession already covered
/// by `TemporalStatus`/`KeywordGraphRetrievalProviderTests`. Every test constructs
/// `ScoredEvidence` directly rather than going through a real `RetrievalProvider`, so the
/// resolver's own logic is verified in isolation from retrieval/scoring.
final class CrossLayerConflictResolverTests: XCTestCase {
    private func makeMemory(id: UUID = UUID(), predicate: String, literalValue: String, lastConfirmedAt: Date = Date()) -> ScoredEvidence<MemoryEdge> {
        let edge = MemoryEdge(id: id, subjectEntityID: UUID(), predicate: predicate, literalValue: literalValue, category: .fact, confidence: 0.9, sourceSessionID: UUID(), lastConfirmedAt: lastConfirmedAt)
        return ScoredEvidence(value: edge, source: .memoryEdge(id), score: 0.5, temporalStatus: .current, provenance: Provenance(sourceSessionID: edge.sourceSessionID, sourceMessageIDs: [], timestamp: lastConfirmedAt), renderedText: "\(predicate) \(literalValue)")
    }

    private func makeProjectItem(id: UUID = UUID(), name: String, description: String? = nil, lastUpdatedAt: Date = Date()) -> ScoredEvidence<ProjectItem> {
        let item = ProjectItem(id: id, projectID: UUID(), kind: .component, name: name, description: description, sourceSessionID: UUID(), lastUpdatedAt: lastUpdatedAt)
        return ScoredEvidence(value: item, source: .projectItem(id), score: 0.5, temporalStatus: .current, provenance: Provenance(sourceSessionID: item.sourceSessionID, sourceMessageIDs: [], timestamp: lastUpdatedAt), renderedText: name)
    }

    private func makeDecision(id: UUID = UUID(), statement: String, context: String? = nil, relatedItemID: UUID? = nil, decidedAt: Date = Date()) -> ScoredEvidence<Decision> {
        let decision = Decision(id: id, projectID: UUID(), statement: statement, context: context, relatedItemID: relatedItemID, sourceSessionID: UUID(), decidedAt: decidedAt)
        return ScoredEvidence(value: decision, source: .decision(id), score: 0.5, temporalStatus: .current, provenance: Provenance(sourceSessionID: decision.sourceSessionID, sourceMessageIDs: [], timestamp: decidedAt), renderedText: statement)
    }

    // MARK: A - Memory vs Decision

    func testMemoryVsDecisionConflict_DecisionWinsForCurrentIntent() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [decision], intent: .current)
        XCTAssertTrue(resolution.memories.isEmpty, "the stale memory must be excluded once an explicit decision addresses the same topic")
    }

    func testMemoryVsDecisionConflict_DecisionWinsForUnspecifiedIntentToo() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [decision], intent: .unspecified)
        XCTAssertTrue(resolution.memories.isEmpty, "unspecified intent defaults to the same safe current-state behavior")
    }

    // MARK: D - historical intents preserve everything

    func testMemoryVsDecisionConflict_BothPreservedForHistoricalIntent() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [decision], intent: .historical)
        XCTAssertEqual(resolution.memories.map(\.value.id), [memory.value.id], "a 'what did we use before' question must still see the old memory")
    }

    func testMemoryVsDecisionConflict_BothPreservedForChangeReasonIntent() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [decision], intent: .changeReason)
        XCTAssertEqual(resolution.memories.map(\.value.id), [memory.value.id])
    }

    func testMemoryVsDecisionConflict_BothPreservedForWhenDecidedIntent() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [decision], intent: .whenDecided)
        XCTAssertEqual(resolution.memories.map(\.value.id), [memory.value.id])
    }

    // MARK: B - ProjectItem vs Decision (structural link only)

    func testProjectItemVsDecisionConflict_DecisionWinsViaRelatedItemID() {
        let item = makeProjectItem(name: "Database component", description: "Currently backed by MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", relatedItemID: item.value.id)

        let resolution = CrossLayerConflictResolver.resolve(memories: [], projectItems: [item], decisions: [decision], intent: .current)
        XCTAssertTrue(resolution.projectItems.isEmpty, "a ProjectItem structurally linked to a Decision via relatedItemID must be excluded in favor of the Decision")
    }

    func testProjectItemVsDecisionConflict_NoLinkMeansNoExclusion() {
        let item = makeProjectItem(name: "Database component", description: "Currently backed by MongoDB")
        // A decision that happens to mention similar words but has NO structural relatedItemID
        // link must NOT be treated as referring to the same item - lexical guessing between
        // ProjectItem and Decision is deliberately not trusted.
        let decision = makeDecision(statement: "Use PostgreSQL for the database component going forward", relatedItemID: nil)

        let resolution = CrossLayerConflictResolver.resolve(memories: [], projectItems: [item], decisions: [decision], intent: .current)
        XCTAssertEqual(resolution.projectItems.map(\.value.id), [item.value.id])
    }

    // MARK: C - Memory vs ProjectItem (no Decision involved)

    func testMemoryVsProjectItemConflict_NewerWins() {
        let older = Date().addingTimeInterval(-1000)
        let newer = Date()
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB", lastConfirmedAt: older)
        let item = makeProjectItem(name: "Migrate database to PostgreSQL", lastUpdatedAt: newer)

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [item], decisions: [], intent: .current)
        XCTAssertTrue(resolution.memories.isEmpty, "the older memory must lose to the newer, same-topic project item")
        XCTAssertEqual(resolution.projectItems.map(\.value.id), [item.value.id])
    }

    func testMemoryVsProjectItemConflict_OlderItemLosesToNewerMemory() {
        let older = Date().addingTimeInterval(-1000)
        let newer = Date()
        let memory = makeMemory(predicate: "database", literalValue: "PostgreSQL", lastConfirmedAt: newer)
        let item = makeProjectItem(name: "Migrate database to MongoDB", lastUpdatedAt: older)

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [item], decisions: [], intent: .current)
        XCTAssertTrue(resolution.projectItems.isEmpty)
        XCTAssertEqual(resolution.memories.map(\.value.id), [memory.value.id])
    }

    func testMemoryVsProjectItemConflict_ExactTieKeepsBoth() {
        let sameInstant = Date()
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB", lastConfirmedAt: sameInstant)
        let item = makeProjectItem(name: "Migrate database to PostgreSQL", lastUpdatedAt: sameInstant)

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [item], decisions: [], intent: .current)
        XCTAssertEqual(resolution.memories.count, 1, "an exact timestamp tie can't be confidently resolved, so both must be kept")
        XCTAssertEqual(resolution.projectItems.count, 1)
    }

    // MARK: E - unrelated evidence must never be flagged as conflicting

    func testUnrelatedEvidenceIsNeverExcluded() {
        let memory = makeMemory(predicate: "coffee-preference", literalValue: "oat milk latte")
        let item = makeProjectItem(name: "Ship the retrieval stage", description: "Finish Stage 6")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [item], decisions: [decision], intent: .current)
        XCTAssertEqual(resolution.memories.map(\.value.id), [memory.value.id], "no shared topic or structural link exists - nothing should be excluded")
        XCTAssertEqual(resolution.projectItems.map(\.value.id), [item.value.id])
    }

    func testNoStructuralLinkAndNoTopicOverlapLeavesProjectItemsAndDecisionsIndependent() {
        let item = makeProjectItem(name: "Unrelated task", description: "Nothing to do with any decision")
        let decision = makeDecision(statement: "A completely different decision", relatedItemID: nil)

        let resolution = CrossLayerConflictResolver.resolve(memories: [], projectItems: [item], decisions: [decision], intent: .current)
        XCTAssertEqual(resolution.projectItems.map(\.value.id), [item.value.id])
    }

    // MARK: F - explicit Decision wins over weaker evidence generally

    func testExplicitDecisionWinsOverBothWeakerTypesSimultaneously() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let item = makeProjectItem(name: "Database component", description: "Still MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database", relatedItemID: item.value.id)

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [item], decisions: [decision], intent: .current)
        XCTAssertTrue(resolution.memories.isEmpty)
        XCTAssertTrue(resolution.projectItems.isEmpty)
    }

    func testDecisionsArrayIsNeverFilteredByTheResolver() {
        let memory = makeMemory(predicate: "database", literalValue: "MongoDB")
        let decision = makeDecision(statement: "Use PostgreSQL going forward", context: "database")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [decision], intent: .current)
        // Resolution intentionally has no `decisions` field - decisions always pass through
        // the caller unchanged. This test documents that guarantee via the memory side effect.
        XCTAssertTrue(resolution.memories.isEmpty)
    }

    // MARK: H - surviving evidence keeps its original provenance untouched

    func testSurvivingEvidencePreservesOriginalProvenanceExactly() {
        let sessionID = UUID()
        let messageID = UUID()
        let timestamp = Date()
        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "coffee-preference", literalValue: "oat milk latte", category: .preference, confidence: 0.9, sourceSessionID: sessionID, sourceMessageIDs: [messageID])
        let provenance = Provenance(sourceSessionID: sessionID, sourceMessageIDs: [messageID], timestamp: timestamp)
        let memory = ScoredEvidence(value: edge, source: .memoryEdge(edge.id), score: 0.42, temporalStatus: .current, provenance: provenance, renderedText: "coffee-preference oat milk latte")

        let resolution = CrossLayerConflictResolver.resolve(memories: [memory], projectItems: [], decisions: [], intent: .current)
        XCTAssertEqual(resolution.memories.first?.provenance, provenance)
        XCTAssertEqual(resolution.memories.first?.score, 0.42)
        XCTAssertEqual(resolution.memories.first?.renderedText, "coffee-preference oat milk latte")
    }
}
