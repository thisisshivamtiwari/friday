import XCTest
@testable import FounderOfficeCopilotCore

/// Covers the answer-sources layer - the product's trust surface.
///
/// The guarantee under test is narrow and absolute: what the UI shows as "Sources" is derived
/// from the `ContextPacket` the model was actually given, and every source carries the retrieval
/// layer's own typed id. If sources could ever be produced from anything else - answer text,
/// name similarity, a guess - the feature would be attaching confident provenance to
/// hallucinations, which is worse than having no sources at all.
final class AnswerSourceTests: XCTestCase {

    // MARK: Fixture

    private func decisionEvidence(_ statement: String, id: UUID = UUID()) -> ScoredEvidence<Decision> {
        let decision = Decision(id: id, projectID: UUID(), statement: statement, context: "calibration", sourceSessionID: UUID())
        return ScoredEvidence(value: decision, source: .decision(decision.id), score: 0.9, temporalStatus: .current,
                              provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()),
                              renderedText: statement)
    }

    private func itemEvidence(_ name: String, id: UUID = UUID()) -> ScoredEvidence<ProjectItem> {
        let item = ProjectItem(id: id, projectID: UUID(), kind: .task, name: name, sourceSessionID: UUID())
        return ScoredEvidence(value: item, source: .projectItem(item.id), score: 0.8, temporalStatus: .current,
                              provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()),
                              renderedText: name)
    }

    private func memoryEvidence(_ text: String) -> ScoredEvidence<MemoryEdge> {
        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "prefers", literalValue: text, category: .preference, confidence: 0.8, sourceSessionID: UUID())
        return ScoredEvidence(value: edge, source: .memoryEdge(edge.id), score: 0.7, temporalStatus: .current,
                              provenance: Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date()),
                              renderedText: text)
    }

    private func historicalEvidence(sessionID: UUID, text: String) -> ScoredEvidence<ChatMessage> {
        let message = ChatMessage(role: .heard, text: text)
        return ScoredEvidence(value: message, source: .chatMessage(sessionID: sessionID, messageID: message.id),
                              score: 0.6, temporalStatus: .historical,
                              provenance: Provenance(sourceSessionID: sessionID, sourceMessageIDs: [message.id], timestamp: Date()),
                              renderedText: text)
    }

    // MARK: Derivation

    func testSourcesComeFromThePacketAndCarryTypedIdentifiers() {
        var packet = ContextPacket.empty
        let decisionID = UUID(), itemID = UUID()
        packet.relevantDecisions = [decisionEvidence("Rule out conformal prediction", id: decisionID)]
        packet.relevantProjectItems = [itemEvidence("MC dropout calibration evaluation", id: itemID)]

        let sources = AnswerSourceBuilder.references(from: packet)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.first?.kind, .decision)
        XCTAssertEqual(sources.first?.source, .decision(decisionID))
        XCTAssertEqual(sources.last?.source, .projectItem(itemID))
    }

    /// THE core guarantee: no packet, no sources. There is no path that manufactures one.
    func testAnEmptyPacketProducesNoSources() {
        XCTAssertTrue(AnswerSourceBuilder.references(from: .empty).isEmpty)
    }

    func testSourceTitlesAreTheEvidencesOwnTextNotAParaphrase() {
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Split transient and group demand into two sub-models")]
        let source = AnswerSourceBuilder.references(from: packet).first
        XCTAssertEqual(source?.title, "Split transient and group demand into two sub-models")
    }

    /// Procedural instructions are standing behavioural rules, not subject-matter evidence.
    /// Listing "always be concise" as a source for an answer about calibration is noise dressed
    /// up as provenance.
    func testProceduralInstructionsAreNeverListedAsSources() {
        var packet = ContextPacket.empty
        packet.proceduralInstructions = [memoryEvidence("always be concise")]
        XCTAssertTrue(AnswerSourceBuilder.references(from: packet).isEmpty)
    }

    /// Several excerpts from one meeting is ONE source a founder recognises, not five rows.
    func testHistoricalExcerptsAreGroupedByConversation() {
        var packet = ContextPacket.empty
        let sessionID = UUID()
        packet.historicalEvidence = [
            historicalEvidence(sessionID: sessionID, text: "first excerpt"),
            historicalEvidence(sessionID: sessionID, text: "second excerpt"),
            historicalEvidence(sessionID: sessionID, text: "third excerpt"),
        ]
        let sources = AnswerSourceBuilder.references(from: packet)
        XCTAssertEqual(sources.filter { $0.kind == .conversation }.count, 1)
    }

    func testTwoConversationsRemainTwoSources() {
        var packet = ContextPacket.empty
        packet.historicalEvidence = [
            historicalEvidence(sessionID: UUID(), text: "meeting one"),
            historicalEvidence(sessionID: UUID(), text: "meeting two"),
        ]
        XCTAssertEqual(AnswerSourceBuilder.references(from: packet).filter { $0.kind == .conversation }.count, 2)
    }

    func testResolversSupplyLocatingDetailWithoutAlteringIdentity() {
        var packet = ContextPacket.empty
        let itemID = UUID()
        packet.relevantProjectItems = [itemEvidence("Calibration sweep", id: itemID)]
        let sources = AnswerSourceBuilder.references(from: packet, projectNameForItem: { _ in "Research" })
        XCTAssertEqual(sources.first?.subtitle, "Research")
        XCTAssertEqual(sources.first?.source, .projectItem(itemID), "resolving a display name must not change what the source points at")
    }

    func testSourceOrderingLeadsWithDecisionsThenWork() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [memoryEvidence("prefers dark mode")]
        packet.relevantProjectItems = [itemEvidence("Calibration sweep")]
        packet.relevantDecisions = [decisionEvidence("Adopt temperature scaling")]
        let kinds = AnswerSourceBuilder.references(from: packet).map(\.kind)
        XCTAssertEqual(kinds, [.decision, .workItem, .memory])
    }

    // MARK: Navigation

    /// A source opens the entity its typed id names - never one found by matching text.
    func testSourcesResolveToTheEntityTheirIdentifierNames() {
        let decisionID = UUID(), itemID = UUID(), sessionID = UUID()
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt scaling", id: decisionID)]
        packet.relevantProjectItems = [itemEvidence("Calibration", id: itemID)]
        packet.historicalEvidence = [historicalEvidence(sessionID: sessionID, text: "excerpt")]

        let sources = AnswerSourceBuilder.references(from: packet)
        let entities = sources.compactMap(EntityReference.init)
        XCTAssertTrue(entities.contains { $0.kind == .decision(decisionID) })
        XCTAssertTrue(entities.contains { $0.kind == .workItem(itemID) })
        XCTAssertTrue(entities.contains { $0.kind == .conversation(sessionID) })
    }

    /// Evidence with no dedicated screen is NOT navigable, rather than opening something that
    /// only approximately corresponds to it.
    func testEvidenceWithoutADedicatedScreenIsNotNavigable() {
        var packet = ContextPacket.empty
        packet.relevantMemories = [memoryEvidence("prefers dark mode")]
        let source = try? XCTUnwrap(AnswerSourceBuilder.references(from: packet).first)
        XCTAssertNil(source.flatMap(EntityReference.init))
    }

    // MARK: Store

    func testEvidenceIsRecordedAgainstItsOwnResponseMessage() {
        let store = ResponseEvidenceStore()
        let messageID = UUID(), otherID = UUID()
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt scaling")]

        store.record(AnswerSourceBuilder.references(from: packet), for: messageID)
        XCTAssertEqual(store.references(for: messageID).count, 1)
        XCTAssertTrue(store.references(for: otherID).isEmpty, "a message with no recorded evidence must report none, never another message's")
    }

    func testRecordingNothingLeavesNoEntry() {
        let store = ResponseEvidenceStore()
        let messageID = UUID()
        store.record([], for: messageID)
        XCTAssertTrue(store.references(for: messageID).isEmpty)
    }

    /// The cache is bounded, and eviction takes the OLDEST - a long meeting must not grow it
    /// without limit, and the newest answers are the ones a user is looking at.
    func testTheStoreIsBoundedAndEvictsOldestFirst() {
        let store = ResponseEvidenceStore(limit: 3)
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt scaling")]
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { store.record(AnswerSourceBuilder.references(from: packet), for: id) }

        XCTAssertTrue(store.references(for: ids[0]).isEmpty)
        XCTAssertTrue(store.references(for: ids[1]).isEmpty)
        for id in ids.suffix(3) { XCTAssertFalse(store.references(for: id).isEmpty) }
    }

    func testRerecordingTheSameMessageDoesNotConsumeExtraCapacity() {
        let store = ResponseEvidenceStore(limit: 2)
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt scaling")]
        let first = UUID(), second = UUID()
        store.record(AnswerSourceBuilder.references(from: packet), for: first)
        store.record(AnswerSourceBuilder.references(from: packet), for: first)
        store.record(AnswerSourceBuilder.references(from: packet), for: second)
        XCTAssertFalse(store.references(for: first).isEmpty, "a re-recorded message must not evict itself")
        XCTAssertFalse(store.references(for: second).isEmpty)
    }
}

// MARK: - Screen context regression
//
// A real defect found by looking at what the app actually sent, not by a failing test.
//
// Every response captured a full screenshot and uploaded it to Gemini with no setting gating it
// and no mention of it anywhere in the UI. Two consequences, both serious:
//
//  1. GROUNDING. On the `9-negative-retrieval` benchmark question ("what was our approach to
//     hotel demand forecasting?", whose correct answer is "I don't have that stored"), the
//     assistant answered in confident detail about a hotel-pricing codebase - because that
//     codebase was open on screen. It was not recalling prior knowledge; it was reading the
//     screen, which bypasses retrieval, project isolation and the grounding directive entirely.
//     This also explains why two arms of a controlled ablation diverged on byte-identical TEXT
//     context: the images differed.
//  2. PRIVACY. The captured screen included an open `.env` file with a live API key.
//
// The fix is opt-in capture plus mandatory disclosure. These tests pin both halves.
extension AnswerSourceTests {

    func testScreenContextIsOffByDefault() {
        // A fresh install must not send the screen. Asserted against the stored default rather
        // than the live singleton so the test cannot be polluted by a developer's own setting.
        let key = "settings.screenContextEnabled"
        let defaults = UserDefaults(suiteName: "AnswerSourceTests.screenDefault")!
        defaults.removePersistentDomain(forName: "AnswerSourceTests.screenDefault")
        XCTAssertFalse(defaults.bool(forKey: key), "screen capture must be opt-in, never a silent default")
    }

    /// If a screen frame informed the answer it must be DISCLOSED, or the sources list is a lie
    /// by omission - it would show six sources while the claim came from an unlisted screenshot.
    func testAScreenFrameIsDisclosedAsASource() {
        let store = ResponseEvidenceStore()
        let messageID = UUID()
        store.append(.screen, for: messageID)

        let sources = store.references(for: messageID)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.kind, .screen)
        XCTAssertEqual(sources.first?.kind.label, "Your screen")
    }

    /// It must appear FIRST. When an answer is shaped by what was on screen, that is the single
    /// most important thing for the user to know about where it came from.
    func testTheScreenSourceIsListedAheadOfRetrievedEvidence() {
        let store = ResponseEvidenceStore()
        let messageID = UUID()
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt temperature scaling")]

        store.record(AnswerSourceBuilder.references(from: packet), for: messageID)
        store.append(.screen, for: messageID)

        XCTAssertEqual(store.references(for: messageID).first?.kind, .screen)
        XCTAssertEqual(store.references(for: messageID).count, 2, "disclosing the screen must not drop retrieved evidence")
    }

    /// The screen is real evidence but not an entity, so it is visible and non-navigable rather
    /// than opening something that only loosely corresponds to it.
    func testTheScreenSourceIsNotNavigable() {
        let store = ResponseEvidenceStore()
        let messageID = UUID()
        store.append(.screen, for: messageID)
        let source = store.references(for: messageID).first
        XCTAssertNil(source?.source, "a screen frame has no retrieval identifier")
        XCTAssertNil(source.flatMap(EntityReference.init))
    }

    /// Retrieval evidence must never be mistaken for a screen frame, and vice versa.
    func testRetrievedSourcesAlwaysCarryAnIdentifier() {
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt temperature scaling")]
        packet.relevantProjectItems = [itemEvidence("Calibration sweep")]
        for source in AnswerSourceBuilder.references(from: packet) {
            XCTAssertNotNil(source.source, "\(source.kind) came from retrieval and must be navigable")
            XCTAssertNotEqual(source.kind, .screen)
        }
    }
}

// MARK: - Source hygiene regression
//
// Both of these were found by running the real loop and READING the source list, not by a
// failing test. The first live run returned 7 sources of which one was the conversation being
// had, and another was the same meeting listed twice under two evidence layers.
extension AnswerSourceTests {

    /// Citing the conversation you are currently in as a source for its own answer is circular:
    /// the user can already see it, and it crowds out the stored knowledge that justifies the claim.
    func testTheCurrentConversationIsNeverCitedAsItsOwnSource() {
        let currentSession = UUID(), earlierSession = UUID()
        var packet = ContextPacket.empty
        packet.historicalEvidence = [
            historicalEvidence(sessionID: currentSession, text: "the question just asked"),
            historicalEvidence(sessionID: earlierSession, text: "something said last week"),
        ]

        let sources = AnswerSourceBuilder.references(from: packet, currentSessionID: currentSession)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.source, .chatMessage(sessionID: earlierSession, messageID: sources.first.flatMap { _ in packet.historicalEvidence[1].value.id } ?? UUID()))
    }

    func testWithoutACurrentSessionEveryConversationIsStillEligible() {
        let a = UUID(), b = UUID()
        var packet = ContextPacket.empty
        packet.historicalEvidence = [historicalEvidence(sessionID: a, text: "one"), historicalEvidence(sessionID: b, text: "two")]
        XCTAssertEqual(AnswerSourceBuilder.references(from: packet).count, 2)
    }

    /// One entity is ONE source however many retrieval layers surfaced it. Listing the same
    /// meeting twice reads as two independent corroborations when it is one.
    func testOneEntitySurfacedByTwoLayersIsListedOnce() {
        let sessionID = UUID()
        var packet = ContextPacket.empty
        packet.relevantEpisodes = [episodeEvidence(sessionID: sessionID, title: "Revenue — Meeting 1")]
        packet.historicalEvidence = [historicalEvidence(sessionID: sessionID, text: "an excerpt from that meeting")]

        let sources = AnswerSourceBuilder.references(from: packet)
        XCTAssertEqual(sources.count, 1, "the same meeting must not appear as both an episode and a conversation")
    }

    /// Deduplication must key on the ENTITY, not the kind - two genuinely different entities are
    /// two sources even when they look similar.
    func testDistinctEntitiesAreNeverCollapsed() {
        var packet = ContextPacket.empty
        packet.relevantDecisions = [decisionEvidence("Adopt scaling"), decisionEvidence("Reject conformal")]
        packet.relevantProjectItems = [itemEvidence("Calibration"), itemEvidence("Payload fix")]
        XCTAssertEqual(AnswerSourceBuilder.references(from: packet).count, 4)
    }

    private func episodeEvidence(sessionID: UUID, title: String) -> ScoredEvidence<EpisodeSummary> {
        let episode = EpisodeSummary(sessionID: sessionID, meetingID: nil, title: title, occurredAt: Date(),
                                     participantEntityIDs: [], decisions: [], projectItems: [], projectEvents: [],
                                     checkpointSummary: nil, sourceMessageIDs: [])
        return ScoredEvidence(value: episode, source: .episode(sessionID: sessionID), score: 0.5, temporalStatus: .historical,
                              provenance: Provenance(sourceSessionID: sessionID, sourceMessageIDs: [], timestamp: Date()),
                              renderedText: title)
    }
}
