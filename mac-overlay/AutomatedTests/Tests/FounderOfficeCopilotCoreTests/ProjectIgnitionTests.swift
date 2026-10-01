import XCTest
@testable import FounderOfficeCopilotCore

/// Covers Phase 4.1 - "Project Ignition": the previously-missing production entry points
/// (`ProjectManager.createProject`/`assignSession`/`unassignSession`, now reachable from the
/// sidebar UI) actually activating the ALREADY-BUILT extraction/retrieval/isolation machinery
/// end to end. Every test here drives the same production APIs the UI calls - `ProjectManager`
/// directly for project/session actions, and the real `ExtractionCoordinator` (with only its
/// LLM client stubbed, via the shared `StubExtractionLLMClient`) for anything that needs a
/// genuinely-extracted `ProjectItem`/`Decision` - never a hand-inserted fixture standing in for
/// what extraction would have produced. This is what proves Phase 4.1 activated the existing
/// architecture rather than merely adding a UI that calls `ProjectManager` in isolation.
final class ProjectIgnitionTests: XCTestCase {
    private func pollUntil(timeout: TimeInterval = 3.0, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func makeCoordinator(memoryManager: MemoryManager, projectManager: ProjectManager, stub: StubExtractionLLMClient) -> ExtractionCoordinator {
        let coordinator = ExtractionCoordinator(
            memoryManager: memoryManager,
            projectManager: projectManager,
            llmClient: stub,
            apiKeyProvider: { "test-key-not-real" },
            model: { "test-model" }
        )
        coordinator.maxQueuedTurns = 1
        coordinator.retryBackoffBase = 0.01
        return coordinator
    }

    // MARK: H - extraction persists a ProjectItem once the session is assigned

    func testExtractionPersistsProjectItemOnceSessionIsAssigned() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.85, projectItemKind: .task, name: "Bayesian calibration implementation", itemDescription: "Implemented Bayesian calibration in the ensemble selection algorithm.")
        ]
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I implemented Bayesian calibration in the ensemble selection algorithm.")

        pollUntil { !projectManager.items.isEmpty }
        XCTAssertEqual(projectManager.items(forProject: project.id).map(\.name), ["Bayesian calibration implementation"])
    }

    // MARK: I - extraction persists a Decision once the session is assigned

    func testExtractionPersistsDecisionOnceSessionIsAssigned() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Use correlation-aware weighting", context: "confidence weighting", reason: "the previous confidence weighting approach performed poorly")
        ]
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "We decided to use correlation-aware weighting instead.")

        pollUntil { !projectManager.decisions.isEmpty }
        XCTAssertEqual(projectManager.decisions(forProject: project.id).map(\.statement), ["Use correlation-aware weighting"])
    }

    // MARK: J - without an assigned project, the same conversation creates nothing project-related

    func testNoProjectExtractionWhenSessionIsUnassigned() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        // Deliberately never call assignSession - and no Project exists at all, matching the
        // real shipped-app state Phase 3.5 found.
        let sessionID = UUID()

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.85, projectItemKind: .task, name: "Bayesian calibration implementation", itemDescription: "Implemented Bayesian calibration.")
        ]
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I implemented Bayesian calibration in the ensemble selection algorithm.")

        // There is no "success" signal to poll for here (nothing should ever appear) - give the
        // async pipeline a bounded window to (not) do anything, then assert nothing landed.
        pollUntil(timeout: 0.5) { false }
        XCTAssertTrue(projectManager.items.isEmpty, "resolveActiveProject must return nil with no assignment, discarding the candidate")
        XCTAssertTrue(projectManager.decisions.isEmpty)
    }

    // MARK: D - project assignment survives reload

    func testProjectAssignmentSurvivesReload() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("project-ignition-reload-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sessionID = UUID()
        var projectID: UUID!
        do {
            let store = ProjectStore(storeURL: tempURL)
            let manager = ProjectManager(store: store)
            let project = manager.createProject(Project(name: "Bayesian Multi-Agent Research"))
            projectID = project.id
            manager.assignSession(sessionID, to: project.id)
            pollUntil { store.loadAllProjectSessionLinks().contains { $0.sessionID == sessionID } }
        }

        // A completely fresh ProjectManager/ProjectStore pair pointed at the SAME file - proves
        // the assignment was actually persisted, not just held in the first instance's memory.
        let reloadedStore = ProjectStore(storeURL: tempURL)
        let reloadedManager = ProjectManager(store: reloadedStore)
        XCTAssertEqual(reloadedManager.project(forSession: sessionID), projectID)
    }

    // MARK: E/F - reassignment moves the session's active-project resolution

    func testReassignmentMovesSessionOutOfTheOldProjectsActiveContext() {
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let projectA = projectManager.createProject(Project(name: "Project A"))
        let projectB = projectManager.createProject(Project(name: "Project B"))
        let sessionID = UUID()

        projectManager.assignSession(sessionID, to: projectA.id)
        XCTAssertEqual(ProjectResolution.resolve(sessionID: sessionID, mentionedProjectName: nil, probeTexts: [], projectManager: projectManager), projectA.id)
        XCTAssertTrue(projectManager.sessions(forProject: projectA.id).contains(sessionID))

        projectManager.assignSession(sessionID, to: projectB.id)

        XCTAssertEqual(ProjectResolution.resolve(sessionID: sessionID, mentionedProjectName: nil, probeTexts: [], projectManager: projectManager), projectB.id, "resolution must now point at the NEW project")
        XCTAssertFalse(projectManager.sessions(forProject: projectA.id).contains(sessionID), "the OLD project must no longer see this session as one of its own")
        XCTAssertTrue(projectManager.sessions(forProject: projectB.id).contains(sessionID))
    }

    // MARK: K,L,M,N,O - multi-session retrieval within the same project

    func testCrossSessionRetrievalWithinTheSameProject() {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))

        // Session 1 - where the knowledge is added.
        let session1 = chatSessionManager.createSession(title: "Session 1")
        projectManager.assignSession(session1, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Use correlation-aware weighting", context: "confidence weighting", reason: "the previous confidence weighting approach performed poorly")
        ]
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)
        coordinator.turnFinalized(sessionID: session1, messageID: UUID(), text: "We decided to use correlation-aware weighting instead.")
        pollUntil { !projectManager.decisions.isEmpty }

        // Session 2 - a DIFFERENT session, same project, asking about it.
        let session2 = chatSessionManager.createSession(title: "Session 2")
        projectManager.assignSession(session2, to: project.id)

        let provider = KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager)
        let engine = ContextEngine(retrievalProvider: provider, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "What did we decide about the confidence weighting approach?", sessionID: session2)

        XCTAssertEqual(packet.activeProjectID, project.id, "session 2 must resolve to the same project via its OWN link, not session 1's")
        XCTAssertTrue(packet.relevantDecisions.map(\.value.statement).contains("Use correlation-aware weighting"), "session 2 must retrieve knowledge that was only ever added in session 1")
    }

    // MARK: P,Q,G - Project A / Project B isolation

    func testProjectAKnowledgeDoesNotLeakIntoProjectBContext() {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))

        let projectA = projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))
        let session1 = chatSessionManager.createSession(title: "Session 1")
        projectManager.assignSession(session1, to: projectA.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Use correlation-aware weighting", context: "confidence weighting", reason: "the previous confidence weighting approach performed poorly")
        ]
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)
        coordinator.turnFinalized(sessionID: session1, messageID: UUID(), text: "We decided to use correlation-aware weighting instead.")
        pollUntil { !projectManager.decisions.isEmpty }

        let projectB = projectManager.createProject(Project(name: "Completely Different Research"))
        let session3 = chatSessionManager.createSession(title: "Session 3")
        projectManager.assignSession(session3, to: projectB.id)

        let provider = KeywordGraphRetrievalProvider(memoryManager: memoryManager, projectManager: projectManager, chatSessionManager: chatSessionManager)
        let engine = ContextEngine(retrievalProvider: provider, chatSessionManager: chatSessionManager, projectManager: projectManager)
        let packet = engine.buildContextPacket(forQuestion: "What did we decide about the confidence weighting approach?", sessionID: session3)

        XCTAssertEqual(packet.activeProjectID, projectB.id)
        XCTAssertTrue(packet.relevantDecisions.isEmpty, "Project A's decision must never appear while resolving Project B's context")
        XCTAssertFalse(packet.relevantDecisions.map(\.value.statement).contains("Use correlation-aware weighting"))
    }

    // MARK: R - Memory extraction remains independent of project assignment

    func testMemoryExtractionIsUnaffectedByProjectAssignmentState() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        // No project created, no session assigned at all - Memory must not care.
        let sessionID = UUID()

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.9, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference)
        ]
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer dark mode.")

        pollUntil { !memoryManager.edges.isEmpty }
        XCTAssertEqual(memoryManager.edges.count, 1)
        XCTAssertTrue(projectManager.items.isEmpty)
        XCTAssertTrue(projectManager.decisions.isEmpty)
    }

    // MARK: S - recordingSessionID/viewingSessionID independence unaffected

    func testRecordingAndViewingSessionIndependenceIsUnaffectedByProjectAssignment() {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))

        let recordingID = chatSessionManager.beginRecording()
        projectManager.assignSession(recordingID, to: project.id)

        let otherID = chatSessionManager.createSession(title: "Somewhere else")
        chatSessionManager.switchViewing(to: otherID)

        XCTAssertEqual(chatSessionManager.recordingSessionID, recordingID, "viewing elsewhere must never change what's recording")
        XCTAssertEqual(chatSessionManager.viewingSessionID, otherID)
        XCTAssertEqual(projectManager.project(forSession: recordingID), project.id, "project assignment must survive viewing elsewhere")
        XCTAssertNil(projectManager.project(forSession: otherID), "browsing a different session must never assign IT to a project as a side effect")
    }

    // MARK: T - Record Here remains unaffected by project assignment

    func testRecordHereRemainsUnaffectedByProjectAssignment() {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))

        let targetID = chatSessionManager.createSession(title: "Target")
        projectManager.assignSession(targetID, to: project.id)

        chatSessionManager.recordHere(targetID)
        XCTAssertEqual(chatSessionManager.sidebarViewModel.pendingRecordingSessionID, targetID)

        let started = chatSessionManager.beginRecording()
        XCTAssertEqual(started, targetID, "Record Here's target-consumption behavior must be completely unaffected by that session having a project assigned")
        XCTAssertEqual(projectManager.project(forSession: targetID), project.id, "recording into the session must not touch its project link")
    }

    // MARK: Genuine end-to-end (the CRITICAL requirement) - real AIEngineController boundary

    /// The capstone test: proves this is not merely a UI feature. Drives the EXACT production
    /// path - AIEngineController.start()/handleLiveEvent()/stop() for transcription and
    /// extraction triggering, ChatSessionManager.recordHere()/createSession() for session
    /// management, ProjectManager.createProject()/assignSession() for the new UI actions, the
    /// real ExtractionCoordinator (only its LLM client stubbed), the real ContextEngine, and
    /// AIEngineController.retrievedContextText(forCurrentTurn:) - the exact method
    /// requestResponse() calls before ever reaching GeminiResponseGenerator. No ProjectItem/
    /// Decision/ProjectSessionLink is ever constructed and inserted directly.
    func testGenuineEndToEndFlowFromProjectCreationThroughExtractionToRetrieval() {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(memoryManager: memoryManager, projectManager: projectManager, stub: stub)

        let engine = AIEngineController(
            chatSessionManager: chatSessionManager,
            memoryManager: memoryManager,
            projectManager: projectManager,
            extractionCoordinator: coordinator
        )
        engine.apiKeyProvider = { nil } // never opens a real network connection

        // 1. Create Project (the new UI action) and assign the about-to-start session to it.
        let projectA = engine.projectManager.createProject(Project(name: "Bayesian Multi-Agent Research"))
        engine.start()
        let session1 = chatSessionManager.recordingSessionID!
        engine.projectManager.assignSession(session1, to: projectA.id)

        // 2. Conversation occurs, turn by turn - each turn goes through the REAL
        // start/handleLiveEvent/stop cycle, exactly like a real Start/Stop listening session.
        // stop() unconditionally calls extractFinalizedHeardTurnIfNeeded(), even with no API
        // key configured (transcription/extraction triggering never gates on the response key).
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.85, projectItemKind: .task, name: "Bayesian calibration implementation", itemDescription: "Implemented Bayesian calibration in the ensemble selection algorithm.")
        ]
        engine.handleLiveEvent(.inputTranscript("I implemented Bayesian calibration in the ensemble selection algorithm."))
        engine.stop()
        pollUntil { !projectManager.items.isEmpty }

        chatSessionManager.recordHere(session1)
        engine.start()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.8, projectItemKind: .experiment, name: "confidence weighting approach", itemDescription: "The previous confidence weighting approach performed poorly.")
        ]
        engine.handleLiveEvent(.inputTranscript("The previous confidence weighting approach performed poorly."))
        engine.stop()
        pollUntil { projectManager.items(forProject: projectA.id).count >= 2 }

        chatSessionManager.recordHere(session1)
        engine.start()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Use correlation-aware weighting", context: "confidence weighting", reason: "the previous confidence weighting approach performed poorly")
        ]
        engine.handleLiveEvent(.inputTranscript("We decided to use correlation-aware weighting instead."))
        engine.stop()
        pollUntil { !projectManager.decisions.isEmpty }

        // 3. Project A now genuinely contains real, extracted structure.
        XCTAssertEqual(projectManager.items(forProject: projectA.id).count, 2)
        XCTAssertEqual(projectManager.decisions(forProject: projectA.id).map(\.statement), ["Use correlation-aware weighting"])

        // 4. A second, real ChatSession, assigned to the SAME project.
        let session2 = chatSessionManager.createSession(title: "Session 2")
        engine.projectManager.assignSession(session2, to: projectA.id)
        chatSessionManager.recordHere(session2)
        engine.start()
        XCTAssertEqual(chatSessionManager.recordingSessionID, session2)

        // 5. Ask about it from Session 2 - through the EXACT method requestResponse() calls
        // before reaching GeminiResponseGenerator.
        let question = "What did we decide about the confidence weighting approach?"
        let injectedContext = engine.retrievedContextText(forCurrentTurn: [ChatMessage(role: .heard, text: question)])
        XCTAssertNotNil(injectedContext)
        XCTAssertTrue(injectedContext!.contains("Use correlation-aware weighting"), "the decision made in Session 1 must be retrievable while answering in Session 2")
        XCTAssertTrue(injectedContext!.contains("confidence weighting"))

        // 6. The FULL system instruction Gemini would actually receive.
        let settings = SettingsStore.shared
        let systemInstruction = AIEngineController.buildSystemInstruction(settings: settings, additionalContext: injectedContext)
        XCTAssertTrue(systemInstruction.contains("Use correlation-aware weighting"), "the retrieved decision must genuinely reach the system instruction boundary")
        engine.stop()

        // 7. A second project, a third session - Project A's knowledge must not leak in.
        let projectB = projectManager.createProject(Project(name: "Completely Different Research"))
        let session3 = chatSessionManager.createSession(title: "Session 3")
        engine.projectManager.assignSession(session3, to: projectB.id)
        chatSessionManager.recordHere(session3)
        engine.start()

        let isolatedContext = engine.retrievedContextText(forCurrentTurn: [ChatMessage(role: .heard, text: question)])
        XCTAssertNotNil(isolatedContext)
        XCTAssertFalse(isolatedContext!.contains("correlation-aware weighting"), "Project A's decision must never appear while answering in Project B's session")
        XCTAssertTrue(isolatedContext!.lowercased().contains("no stored memory"), "Project B genuinely has nothing yet - the explicit nothing-found fallback must fire")
        engine.stop()
    }
}
