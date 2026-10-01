import XCTest
@testable import FounderOfficeCopilotCore

/// Covers Stage 7 - the ContextEngine -> AIEngineController -> existing GeminiResponseGenerator
/// wiring. Every test drives real, in-memory-backed managers and reads
/// `AIEngineController.retrievedContextText(forCurrentTurn:)`/`buildSystemInstruction(...)`
/// directly - both made `internal` specifically so these tests can inspect exactly what would
/// be appended to the system instruction WITHOUT ever constructing a `GeminiResponseGenerator`
/// or making a network call (matching the same discipline `AIEngineControllerTests.swift`
/// already applies everywhere else in this file).
final class AIEngineControllerContextIntegrationTests: XCTestCase {
    private struct Managers {
        let chatSessionManager: ChatSessionManager
        let memoryManager: MemoryManager
        let projectManager: ProjectManager
        let engine: AIEngineController
    }

    private func makeManagers(extractionCoordinator: ExtractionCoordinator? = nil) -> Managers {
        let chatSessionManager = ChatSessionManager(store: ChatSessionStore(inMemory: true))
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let coordinator = extractionCoordinator ?? {
            let c = ExtractionCoordinator(memoryManager: memoryManager, projectManager: projectManager)
            c.apiKeyProvider = { nil }
            return c
        }()
        let engine = AIEngineController(
            chatSessionManager: chatSessionManager,
            memoryManager: memoryManager,
            projectManager: projectManager,
            extractionCoordinator: coordinator
        )
        engine.apiKeyProvider = { nil }
        return Managers(chatSessionManager: chatSessionManager, memoryManager: memoryManager, projectManager: projectManager, engine: engine)
    }

    private func heard(_ text: String) -> ChatMessage {
        ChatMessage(role: .heard, text: text)
    }

    // MARK: 1 - response generation works with no memory

    func testNoMemoryProducesTheExplicitNothingFoundNote() {
        let m = makeManagers()
        m.engine.start()

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what's the weather like")])
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.lowercased().contains("no stored memory"))
    }

    // MARK: 2 - relevant memory is injected

    func testRelevantMemoryIsInjected() {
        let m = makeManagers()
        m.engine.start()
        let subject = m.memoryManager.createEntity(MemoryEntity(kind: .self, name: "Shivam"))
        _ = m.memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "prefers", literalValue: "dark mode", category: .preference, confidence: 0.9, sourceSessionID: UUID()))

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what theme do I prefer, dark mode or something else")])
        XCTAssertTrue(text?.contains("dark mode") ?? false)
    }

    // MARK: 3 - relevant project state is injected

    func testRelevantProjectStateIsInjected() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let project = m.projectManager.createProject(Project(name: "Friday"))
        m.projectManager.assignSession(sessionID, to: project.id)
        _ = m.projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Ship the retrieval stage", sourceSessionID: sessionID))

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what's the status of the retrieval stage")])
        XCTAssertTrue(text?.contains("Ship the retrieval stage") ?? false)
    }

    // MARK: 4 - relevant decision is injected

    func testRelevantDecisionIsInjected() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let project = m.projectManager.createProject(Project(name: "Friday"))
        m.projectManager.assignSession(sessionID, to: project.id)
        _ = m.projectManager.createDecision(Decision(projectID: project.id, statement: "Use PostgreSQL going forward", context: "database", sourceSessionID: sessionID))

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what database do we currently use")])
        XCTAssertTrue(text?.contains("Use PostgreSQL going forward") ?? false)
    }

    // MARK: 5 - historical vs current clearly distinguished

    func testHistoricalEvidenceIsClearlyDistinguishedFromCurrent() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let subject = m.memoryManager.createEntity(MemoryEntity(kind: .project, name: "Friday"))
        _ = m.memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "database", literalValue: "MongoDB", category: .fact, confidence: 0.9, status: .superseded, sourceSessionID: sessionID))
        _ = m.memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "database", literalValue: "PostgreSQL", category: .fact, confidence: 0.9, sourceSessionID: sessionID))

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what database did we use before")])!
        XCTAssertTrue(text.contains("HISTORICAL / PRIOR CONTEXT"))
        XCTAssertTrue(text.contains("MongoDB"))
    }

    // MARK: 6 - superseded evidence is not presented as current truth

    func testSupersededEvidenceNeverAppearsUnderCurrentKnowledge() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let subject = m.memoryManager.createEntity(MemoryEntity(kind: .project, name: "Friday"))
        let old = m.memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "database", literalValue: "MongoDB", category: .fact, confidence: 0.9, sourceSessionID: sessionID))
        let new = MemoryEdge(subjectEntityID: subject.id, predicate: "database", literalValue: "PostgreSQL", category: .fact, confidence: 0.9, sourceSessionID: sessionID, supersedes: old.id)
        var oldUpdated = old
        oldUpdated.status = .superseded
        oldUpdated.supersededBy = new.id
        m.memoryManager.updateEdge(oldUpdated)
        _ = m.memoryManager.createEdge(new)

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what database do we currently use")])!
        if let currentRange = text.range(of: "CURRENT KNOWLEDGE") {
            let historicalRange = text.range(of: "HISTORICAL / PRIOR CONTEXT")
            let currentSectionEnd = historicalRange?.lowerBound ?? text.endIndex
            let currentSectionText = text[currentRange.upperBound..<currentSectionEnd]
            XCTAssertFalse(currentSectionText.contains("MongoDB"), "superseded evidence must never appear inside the CURRENT KNOWLEDGE section")
        }
    }

    // MARK: 7 - project isolation through the actual response path

    func testProjectIsolationThroughTheResponsePath() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let projectA = m.projectManager.createProject(Project(name: "Project A"))
        let projectB = m.projectManager.createProject(Project(name: "Project B"))
        m.projectManager.assignSession(sessionID, to: projectA.id)
        _ = m.projectManager.createProjectItem(ProjectItem(projectID: projectA.id, kind: .task, name: "Task A only", sourceSessionID: sessionID))
        _ = m.projectManager.createProjectItem(ProjectItem(projectID: projectB.id, kind: .task, name: "Task B only", sourceSessionID: UUID()))

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what's the status of task a only")])!
        XCTAssertTrue(text.contains("Task A only"))
        XCTAssertFalse(text.contains("Task B only"), "a session linked to Project A must never see Project B's state")
    }

    // MARK: 8 - procedural instructions are included

    func testProceduralInstructionsAreIncludedRegardlessOfTopic() {
        let m = makeManagers()
        m.engine.start()
        let subject = m.memoryManager.createEntity(MemoryEntity(kind: .self, name: "Shivam"))
        _ = m.memoryManager.createEdge(MemoryEdge(subjectEntityID: subject.id, predicate: "always", literalValue: "reply concisely", category: .preference, confidence: 0.9, sourceSessionID: UUID(), isPinned: true))

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("completely unrelated question about lunch")])!
        XCTAssertTrue(text.contains("PROCEDURAL INSTRUCTIONS"))
        XCTAssertTrue(text.contains("reply concisely"))
    }

    // MARK: 9 - context budget is respected

    func testContextBudgetIsRespectedThroughTheResponsePath() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let project = m.projectManager.createProject(Project(name: "Friday"))
        m.projectManager.assignSession(sessionID, to: project.id)
        for i in 0..<20 {
            _ = m.projectManager.createProjectItem(ProjectItem(
                projectID: project.id, kind: .task, name: "Task retrieval stage \(i)",
                description: String(repeating: "detail ", count: 200), sourceSessionID: sessionID
            ))
        }

        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what's the status of the retrieval stage tasks")])!
        // 6000 default character budget for the competitive evidence pool + a bounded header/
        // section overhead - this must stay well short of naively dumping all 20 large items.
        XCTAssertLessThan(text.count, 8000, "the context budget must keep the injected text bounded, not proportional to how much matching evidence exists")
    }

    // MARK: 10 - context retrieval failure falls back to existing response behavior

    func testNoRecordingSessionFallsBackToNilAdditionalContext() {
        let m = makeManagers()
        // Never called start() - no recording session exists.
        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("anything")])
        XCTAssertNil(text, "with no recording session, retrieval must cleanly return nil rather than fail")
    }

    func testEmptyCurrentTurnFallsBackToNilAdditionalContext() {
        let m = makeManagers()
        m.engine.start()
        let text = m.engine.retrievedContextText(forCurrentTurn: [])
        XCTAssertNil(text)
    }

    func testBuildSystemInstructionWithNilAdditionalContextMatchesPreStage7Behavior() {
        let settings = SettingsStore.shared
        let withNil = AIEngineController.buildSystemInstruction(settings: settings, additionalContext: nil)
        let withoutParam = AIEngineController.buildSystemInstruction(settings: settings)
        XCTAssertEqual(withNil, withoutParam, "omitting additionalContext must produce byte-identical output to the pre-Stage-7 system instruction")
    }

    func testBuildSystemInstructionWithEmptyStringAdditionalContextIsANoOp() {
        let settings = SettingsStore.shared
        let withEmpty = AIEngineController.buildSystemInstruction(settings: settings, additionalContext: "")
        let withoutParam = AIEngineController.buildSystemInstruction(settings: settings)
        XCTAssertEqual(withEmpty, withoutParam)
    }

    // MARK: 11 - current conversation remains intact

    func testCurrentConversationOrderedMessagesAreUnaffectedByContextInjection() {
        let m = makeManagers()
        m.engine.start()
        m.engine.handleLiveEvent(.inputTranscript("hello there"))

        let context = m.chatSessionManager.responseContext()
        XCTAssertEqual(context.orderedMessages.map(\.text), ["hello there"])
        // retrievedContextText only ever affects systemInstruction, never orderedMessages -
        // calling it must not mutate chatSessionManager state at all.
        _ = m.engine.retrievedContextText(forCurrentTurn: context.currentTurn)
        XCTAssertEqual(m.chatSessionManager.responseContext().orderedMessages.map(\.text), ["hello there"])
    }

    // MARK: 12 - GeminiResponseGenerator remains architecturally decoupled

    func testGeminiResponseGeneratorHasNoMemoryOrContextEngineDependency() {
        let generator = GeminiResponseGenerator(apiKey: "unused", model: "unused")
        let mirror = Mirror(reflecting: generator)
        let allowedTypePrefixes = ["Swift.String", "Foundation.URLSession", "__C.NSURLSession"]
        for child in mirror.children {
            let typeName = String(describing: type(of: child.value))
            let isAllowed = allowedTypePrefixes.contains { typeName.hasPrefix($0) } || typeName == "String" || typeName.contains("URLSession")
            XCTAssertTrue(isAllowed, "GeminiResponseGenerator gained an unexpected stored property of type \(typeName) - it must stay decoupled from Memory/Project/ContextEngine/RetrievalProvider/Core Data")
            XCTAssertFalse(typeName.contains("Memory"))
            XCTAssertFalse(typeName.contains("Project"))
            XCTAssertFalse(typeName.contains("ContextEngine"))
            XCTAssertFalse(typeName.contains("RetrievalProvider"))
            XCTAssertFalse(typeName.contains("NSManagedObject"))
            XCTAssertFalse(typeName.contains("NSPersistentContainer"))
        }
    }

    // MARK: 13 - recordingSessionID remains the source session for context

    func testRecordingSessionIDIsTheSourceForContextNotSomeOtherSession() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let project = m.projectManager.createProject(Project(name: "Friday"))
        m.projectManager.assignSession(sessionID, to: project.id)
        _ = m.projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Recording session task", sourceSessionID: sessionID))

        XCTAssertEqual(m.chatSessionManager.recordingSessionID, sessionID)
        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what's the task status")])!
        XCTAssertTrue(text.contains("Recording session task"))
    }

    // MARK: 14 - viewingSessionID does not accidentally change response context

    func testSwitchingViewingSessionDoesNotChangeRetrievedContext() {
        let m = makeManagers()
        let sessionID = m.engine.startAndReturnRecordingSessionID()
        let project = m.projectManager.createProject(Project(name: "Friday"))
        m.projectManager.assignSession(sessionID, to: project.id)
        _ = m.projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .task, name: "Recording-linked task", sourceSessionID: sessionID))

        let otherSessionID = m.chatSessionManager.createSession(title: "Somewhere else")
        let otherProject = m.projectManager.createProject(Project(name: "Other Project"))
        m.projectManager.assignSession(otherSessionID, to: otherProject.id)
        _ = m.projectManager.createProjectItem(ProjectItem(projectID: otherProject.id, kind: .task, name: "Other session task", sourceSessionID: otherSessionID))
        m.chatSessionManager.switchViewing(to: otherSessionID)

        XCTAssertEqual(m.chatSessionManager.recordingSessionID, sessionID, "viewing must never change which session is recording")
        let text = m.engine.retrievedContextText(forCurrentTurn: [heard("what's the task status")])!
        XCTAssertTrue(text.contains("Recording-linked task"))
        XCTAssertFalse(text.contains("Other session task"), "browsing a different session's sidebar entry must never leak into the recording session's context")
    }

    // MARK: 15 - long-chat responseContext remains bounded

    func testResponseContextStaysBoundedWithManyPriorMessages() {
        let m = makeManagers()
        m.engine.start()
        for i in 0..<100 {
            m.engine.handleLiveEvent(.inputTranscript("message \(i)"))
            _ = m.chatSessionManager.beginResponse()
            m.chatSessionManager.completeResponse(messageID: m.chatSessionManager.recordingSession!.messages.last!.id, errorText: nil)
        }
        let context = m.chatSessionManager.responseContext()
        XCTAssertLessThanOrEqual(context.recentContext.count, ChatSessionManager.defaultRecentContextLimit, "Stage 7 must not have changed responseContext's existing bound")
    }
}

private extension AIEngineController {
    /// Test-only convenience: `start()` begins the Live session too (which requires a real
    /// API key to do anything, and these tests always run with `apiKeyProvider = { nil }`),
    /// so `start()` alone is enough to create a recording session without ever touching the
    /// network - this just also hands back the resulting session id for readability at call
    /// sites that immediately need it.
    @discardableResult
    func startAndReturnRecordingSessionID() -> UUID {
        start()
        return chatSessionManager.recordingSessionID!
    }
}
