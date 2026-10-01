import XCTest
@testable import FounderOfficeCopilotCore

/// The realistic, deterministic long-running-project scenario Stage 7 requires: five sessions
/// spread over a project's life (professor suggestion -> implementation -> poor result ->
/// decision to change -> better result), verified through the REAL `ContextEngine` +
/// `KeywordGraphRetrievalProvider` + `CrossLayerConflictResolver` + `ContextPacketFormatter`
/// pipeline. No real Gemini API call is made anywhere in this file - see
/// `api-protocol-scripts/test_context_integration_quality.py` for the manual, real-model
/// counterpart to this scenario.
final class MultiMeetingScenarioIntegrationTests: XCTestCase {
    private struct Scenario {
        let chatSessionManager: ChatSessionManager
        let projectManager: ProjectManager
        let engine: ContextEngine
        let project: Project
        let bayesianItem: ProjectItem
        let temperatureItem: ProjectItem
        let decision: Decision
        /// The session the questions below are asked from - the vantage point at the end of
        /// the whole scenario, same as a user asking Friday something "right now" after all
        /// five meetings have already happened.
        let latestSessionID: UUID
    }

    private func buildScenario() -> Scenario {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let provider = KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager)
        let engine = ContextEngine(retrievalProvider: provider, chatSessionManager: chatSessionManager, projectManager: projectManager)

        let project = projectManager.createProject(Project(name: "MSc Research"))
        let now = Date()
        let t1 = now.addingTimeInterval(-5 * 86400)
        let t2 = now.addingTimeInterval(-4 * 86400)
        let t3 = now.addingTimeInterval(-3 * 86400)
        let t4 = now.addingTimeInterval(-2 * 86400)
        let t5 = now.addingTimeInterval(-1 * 86400)

        // Session/Meeting 1: "Professor suggested Bayesian calibration."
        let session1 = chatSessionManager.createSession(title: "Meeting 1")
        projectManager.assignSession(session1, to: project.id)
        var bayesianItem = projectManager.createProjectItem(ProjectItem(
            projectID: project.id, kind: .task, name: "Bayesian calibration",
            description: "Professor suggested Bayesian calibration for the model.",
            status: .proposed, sourceSessionID: session1, lastUpdatedAt: t1
        ))

        // Session/Meeting 2: "I implemented Bayesian calibration."
        let session2 = chatSessionManager.createSession(title: "Meeting 2")
        projectManager.assignSession(session2, to: project.id)
        bayesianItem.status = .inProgress
        bayesianItem.description = "Implemented Bayesian calibration for the model."
        bayesianItem.lastUpdatedAt = t2
        projectManager.updateProjectItem(bayesianItem)

        // Session/Meeting 3: "Bayesian calibration performed poorly."
        let session3 = chatSessionManager.createSession(title: "Meeting 3")
        projectManager.assignSession(session3, to: project.id)
        _ = projectManager.createProjectEvent(ProjectEvent(
            projectID: project.id, relatedItemID: bayesianItem.id, eventType: .statusChanged,
            description: "Bayesian calibration performed poorly.", occurredAt: t3, sourceSessionID: session3
        ))

        // Session/Meeting 4: "We decided to use temperature scaling."
        let session4 = chatSessionManager.createSession(title: "Meeting 4")
        projectManager.assignSession(session4, to: project.id)
        let decision = projectManager.createDecision(Decision(
            projectID: project.id, statement: "Use temperature scaling for calibration going forward",
            context: "calibration", relatedItemID: bayesianItem.id, reason: "Bayesian calibration performed poorly",
            sourceSessionID: session4, decidedAt: t4
        ))

        // Session/Meeting 5: "Temperature scaling performed better."
        let session5 = chatSessionManager.createSession(title: "Meeting 5")
        projectManager.assignSession(session5, to: project.id)
        let temperatureItem = projectManager.createProjectItem(ProjectItem(
            projectID: project.id, kind: .result, name: "Temperature scaling",
            description: "Temperature scaling calibration approach performed better than Bayesian calibration.",
            status: .completed, relatedItemID: decision.id, sourceSessionID: session5, lastUpdatedAt: t5
        ))

        return Scenario(
            chatSessionManager: chatSessionManager, projectManager: projectManager, engine: engine,
            project: project, bayesianItem: bayesianItem, temperatureItem: temperatureItem, decision: decision,
            latestSessionID: session5
        )
    }

    // MARK: Q1 - current state

    func testCurrentCalibrationQuestionContainsTheCurrentState() {
        let s = buildScenario()
        let packet = s.engine.buildContextPacket(forQuestion: "What are we currently using for calibration?", sessionID: s.latestSessionID)

        XCTAssertEqual(packet.activeProjectID, s.project.id)
        XCTAssertTrue(packet.relevantDecisions.map(\.value.id).contains(s.decision.id), "the current decision must be present")
        XCTAssertFalse(
            packet.relevantProjectItems.map(\.value.id).contains(s.bayesianItem.id),
            "the superseded Bayesian item is structurally linked to the newer Decision (relatedItemID) - cross-layer conflict resolution must exclude it from a current-state answer"
        )
    }

    // MARK: Q2 - historical

    func testWhatDidWeTryBeforeContainsBayesianCalibration() {
        let s = buildScenario()
        let packet = s.engine.buildContextPacket(forQuestion: "What did we try before temperature scaling?", sessionID: s.latestSessionID)

        let allText = (packet.relevantProjectItems.map(\.renderedText) + packet.relevantDecisions.map(\.renderedText)).joined(separator: " ")
        XCTAssertTrue(allText.contains("Bayesian"), "a 'what did we use before' question must surface the earlier Bayesian calibration attempt")
    }

    // MARK: Q3 - why did we change

    func testWhyDidWeMoveAwayContainsReasonAndTemporalRelationship() {
        let s = buildScenario()
        let packet = s.engine.buildContextPacket(forQuestion: "Why did we move away from Bayesian calibration?", sessionID: s.latestSessionID)

        XCTAssertTrue(packet.relevantDecisions.map(\.value.id).contains(s.decision.id))
        let decisionEvidence = packet.relevantDecisions.first { $0.value.id == s.decision.id }
        XCTAssertTrue(decisionEvidence?.renderedText.contains("Bayesian") ?? false, "must include the Bayesian evidence")
        XCTAssertTrue(decisionEvidence?.renderedText.contains("poorly") ?? false, "must include WHY it changed (the poor result)")
        XCTAssertEqual(decisionEvidence?.value.relatedItemID, s.bayesianItem.id, "must preserve the structural link back to what changed - the temporal relationship")
    }

    // MARK: Q4 - unrelated question

    func testUnrelatedWeatherQuestionDoesNotInjectProjectContext() {
        let s = buildScenario()
        let questionText = "What is the weather like today?"
        let packet = s.engine.buildContextPacket(forQuestion: questionText, sessionID: s.latestSessionID)
        let formatted = ContextPacketFormatter.format(packet, questionText: questionText)

        XCTAssertFalse(formatted.contains("Bayesian"), "an unrelated question must not have project content injected into the formatted context, even though the session remains linked to the project")
        XCTAssertFalse(formatted.contains("temperature scaling"))
        XCTAssertFalse(formatted.contains("calibration"))
        XCTAssertTrue(formatted.lowercased().contains("no stored memory"))
    }

    // MARK: Combined - the full formatted text for the current-state question reads correctly

    func testCurrentStateQuestionFormattedTextClearlyLabelsCurrentVsHistorical() {
        let s = buildScenario()
        let questionText = "What are we currently using for calibration?"
        let packet = s.engine.buildContextPacket(forQuestion: questionText, sessionID: s.latestSessionID)
        let formatted = ContextPacketFormatter.format(packet, questionText: questionText)

        XCTAssertTrue(formatted.contains("temperature scaling") || formatted.contains("Use temperature scaling"))
        XCTAssertTrue(formatted.contains("STORED CONTEXT FROM FRIDAY'S MEMORY AND PROJECT HISTORY"))
    }
}
