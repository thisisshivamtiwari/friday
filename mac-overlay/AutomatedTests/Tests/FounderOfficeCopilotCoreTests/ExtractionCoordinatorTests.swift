import XCTest
@testable import FounderOfficeCopilotCore

/// A deterministic stand-in for the real Gemini-backed ExtractionLLMClient - returns exactly
/// the candidates a test configures, never touches the network. Shared across this file and
/// AIEngineControllerTests.swift (same test module, no import needed) - "DO NOT use the real
/// Gemini API in XCTest" is enforced by construction: nothing in this test target ever
/// constructs a real `ExtractionLLMClient` with a real API key.
final class StubExtractionLLMClient: ExtractionLLMClientProtocol {
    var candidatesToReturn: [ExtractionCandidate] = []
    /// What the coordinator supplied as the active project's canonical item names, per call.
    private(set) var receivedProjectItemNames: [[String]] = []
    var alwaysFail = false
    /// The first N calls fail, then calls succeed - used to test bounded retry/backoff.
    var failuresBeforeSuccess = 0
    private(set) var callCount = 0
    private(set) var receivedTexts: [String] = []

    func extract(conversationText: String, apiKey: String, model: String, existingProjectItemNames: [String], completion: @escaping (Result<[ExtractionCandidate], Error>) -> Void) {
        callCount += 1
        receivedTexts.append(conversationText)
        receivedProjectItemNames.append(existingProjectItemNames)
        if alwaysFail || callCount <= failuresBeforeSuccess {
            completion(.failure(NSError(domain: "StubExtractionLLMClient", code: -1)))
        } else {
            completion(.success(candidatesToReturn))
        }
    }
}

/// Covers ExtractionCoordinator end to end - the full pipeline (pre-filter -> batch -> stubbed
/// LLM call -> SensitiveContentGate -> validation -> active-project resolution -> dedup ->
/// conflict detection -> MemoryManager/ProjectManager persistence) using a stubbed LLM client.
/// Every test uses in-memory stores; nothing here ever touches real saved data or the network.
final class ExtractionCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        stub: StubExtractionLLMClient,
        memoryManager: MemoryManager,
        projectManager: ProjectManager
    ) -> ExtractionCoordinator {
        let coordinator = ExtractionCoordinator(
            memoryManager: memoryManager,
            projectManager: projectManager,
            llmClient: stub,
            apiKeyProvider: { "test-key-not-real" },
            model: { "test-model" }
        )
        // Flush on the very first queued turn - no need to wait through a real debounce
        // window in tests.
        coordinator.maxQueuedTurns = 1
        coordinator.retryBackoffBase = 0.01
        return coordinator
    }

    private func pollUntil(timeout: TimeInterval = 3.0, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: Category 5/6 - explicit decision / explicit task

    func testExplicitDecisionCreatesAnActiveDecision() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Use Bayesian calibration", context: "XYZ algorithm")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)

        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Let's use Bayesian calibration for the XYZ algorithm.")

        pollUntil { !projectManager.decisions.isEmpty }
        XCTAssertEqual(projectManager.decisions.count, 1)
        XCTAssertEqual(projectManager.decisions.first?.status, .active)
        XCTAssertEqual(projectManager.decisions.first?.statement, "Use Bayesian calibration")
    }

    func testExplicitTaskCreatesAPlannedProjectItem() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .explicitTask, confidence: 0.8, projectItemKind: .task, name: "Compare Bayesian calibration with baseline", projectItemStatus: .planned)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)

        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Before next meeting, compare Bayesian calibration with the baseline.")

        pollUntil { !projectManager.items.isEmpty }
        XCTAssertEqual(projectManager.items.count, 1)
        XCTAssertEqual(projectManager.items.first?.kind, .task)
        XCTAssertEqual(projectManager.items.first?.status, .planned)
    }

    func testSuggestionModalityNeverCreatesAnActiveDecisionEvenIfLLMSuppliesHighConfidence() {
        // Structural enforcement, not just prompting hope - even if the LLM mis-assigns a high
        // confidence to a suggestion, ModalityPolicy.allowsActiveDecision still blocks it.
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .suggestion, confidence: 0.95, statement: "Maybe use Bayesian calibration", context: "XYZ algorithm")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Maybe we should try Bayesian calibration for the XYZ algorithm.")

        // Give the pipeline a moment to (not) act.
        pollUntil(timeout: 0.5) { false }
        XCTAssertTrue(projectManager.decisions.isEmpty, "a suggestion must never become an active Decision")
    }

    // MARK: Category 7 - confidence threshold

    func testBelowThresholdConfidenceIsDiscarded() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.1, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "I prefer dark mode, apparently.")

        pollUntil(timeout: 0.5) { false }
        XCTAssertTrue(memoryManager.edges.isEmpty, "below-threshold confidence must be discarded, never persisted")
    }

    func testAtThresholdConfidenceIsPersisted() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.5, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "I prefer dark mode.")

        pollUntil { !memoryManager.edges.isEmpty }
        XCTAssertEqual(memoryManager.edges.count, 1)
    }

    // MARK: Category 8 - sensitive-content gate (integration)

    func testSensitiveCandidateIsNeverPersisted() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.9, subjectName: "self", predicate: "password", literalValue: "hunter2AAAAAAAAAAAAAAAAAAAA", memoryCategory: .fact)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "my password is hunter2AAAAAAAAAAAAAAAAAAAA")

        pollUntil(timeout: 0.5) { false }
        XCTAssertTrue(memoryManager.edges.isEmpty, "a candidate matching the sensitive gate must never be persisted")
    }

    // MARK: Category 9/10 - memory deduplication / corroboration

    func testRepeatedIdenticalMemoryStatementCorroboratesRatherThanDuplicates() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.6, subjectName: "self", predicate: "prefers", literalValue: "Apple-style interfaces", memoryCategory: .preference)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        let sessionID = UUID()

        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer Apple-style interfaces.")
        pollUntil { memoryManager.edges.count == 1 }
        let firstConfidence = memoryManager.edges.first?.confidence ?? 0

        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer Apple-style interfaces.")
        pollUntil { (memoryManager.edges.first?.confirmationCount ?? 0) >= 2 }

        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer Apple-style interfaces.")
        pollUntil { (memoryManager.edges.first?.confirmationCount ?? 0) >= 3 }

        XCTAssertEqual(memoryManager.edges.count, 1, "must never create 20 (or even 3) duplicate edges for the same restated fact")
        XCTAssertEqual(memoryManager.edges.first?.confirmationCount, 3)
        XCTAssertGreaterThan(memoryManager.edges.first?.confidence ?? 0, firstConfidence, "corroboration must increase confidence")
        XCTAssertEqual(memoryManager.edges.first?.sourceMessageIDs.count, 3, "every corroborating message id must be preserved")
    }

    // MARK: Category 11/12 - memory contradiction / supersession

    func testConflictingMemoryValueSupersedesRatherThanCorroborates() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        let sessionID = UUID()

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "React", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I use React.")
        pollUntil { memoryManager.edges.count == 1 }
        let originalID = memoryManager.edges.first!.id

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "Vue", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I use Vue now.")
        pollUntil { memoryManager.edges.count == 2 }

        let old = memoryManager.edge(id: originalID)
        let new = memoryManager.edges.first { $0.id != originalID }
        XCTAssertEqual(old?.status, .superseded)
        XCTAssertEqual(old?.supersededBy, new?.id)
        XCTAssertEqual(new?.status, .active)
        XCTAssertEqual(new?.supersedes, originalID)
        XCTAssertEqual(new?.literalValue, "Vue")
        XCTAssertEqual(old?.literalValue, "React", "the superseded edge must never be mutated to reflect the new value")
    }

    // MARK: Category 13 - memory invalidation (pure retraction, no replacement)

    func testPureRetractionInvalidatesWithoutCreatingAReplacement() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        let sessionID = UUID()

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "React", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I use React.")
        pollUntil { memoryManager.edges.count == 1 }

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .contradiction, confidence: 0.6, subjectName: "self", predicate: "prefers", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I don't use React anymore.")
        pollUntil { memoryManager.edges.first?.status == .invalidated }

        XCTAssertEqual(memoryManager.edges.count, 1, "a pure retraction must not create a new edge")
        XCTAssertEqual(memoryManager.edges.first?.status, .invalidated)
    }

    // MARK: Category 14/15/16/17 - active project resolution priority

    func testSessionLinkedProjectResolutionTakesPriorityOverEverythingElse() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let linkedProject = projectManager.createProject(Project(name: "Trustworthy AI"))
        let otherProject = projectManager.createProject(Project(name: "Retvens"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: linkedProject.id)

        let stub = StubExtractionLLMClient()
        // Explicitly mentions the OTHER project - tier 1 (session link) must still win.
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.7, projectItemKind: .task, name: "Some task", mentionedProjectName: otherProject.name)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Some task needs doing.")

        pollUntil { !projectManager.items.isEmpty }
        XCTAssertEqual(projectManager.items.first?.projectID, linkedProject.id, "an explicit session link must always win over a mentioned project name")
    }

    func testExplicitProjectMentionResolvesWhenSessionIsUnlinked() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Retvens"))
        let sessionID = UUID() // deliberately never linked

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.7, projectItemKind: .task, name: "Some task", mentionedProjectName: "Retvens")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "For Retvens, some task needs doing.")

        pollUntil { !projectManager.items.isEmpty }
        XCTAssertEqual(projectManager.items.first?.projectID, project.id)
    }

    func testStrongContextualMatchResolvesWhenNoLinkOrMention() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        _ = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .component, name: "XYZ Algorithm", sourceSessionID: UUID()))
        let sessionID = UUID() // unlinked

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.8, statement: "Use Bayesian calibration", context: "XYZ Algorithm")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "For the XYZ Algorithm, use Bayesian calibration.")

        pollUntil { !projectManager.decisions.isEmpty }
        XCTAssertEqual(projectManager.decisions.first?.projectID, project.id, "a unique contextual match against an existing item name must resolve the project")
    }

    func testAmbiguousOrNoMatchIsNeverGuessedAndProjectStoreIsNeverMutated() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        _ = projectManager.createProject(Project(name: "Trustworthy AI")) // exists, but never linked/mentioned/matched
        let sessionID = UUID()

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.8, projectItemKind: .task, name: "Some completely unrelated task")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Some completely unrelated task needs doing.")

        pollUntil(timeout: 0.5) { false }
        XCTAssertTrue(projectManager.items.isEmpty, "with no session link, no mention, and no contextual match, the candidate must be dropped, never guessed")
    }

    // MARK: Category 18/19 - ProjectItem deduplication / updates

    func testRepeatedProjectItemMentionUpdatesRatherThanDuplicates() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.6, projectItemKind: .experiment, name: "Experiment 4", projectItemStatus: .inProgress)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Experiment 4 is running.")
        pollUntil { !projectManager.items.isEmpty }
        let firstID = projectManager.items.first!.id

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.7, projectItemKind: .experiment, name: "Experiment 4", projectItemStatus: .completed)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I finished Experiment 4.")
        pollUntil { projectManager.projectItem(id: firstID)?.status == .completed }

        XCTAssertEqual(projectManager.items.count, 1, "must update the existing item, never create a duplicate")
        XCTAssertEqual(projectManager.items.first?.id, firstID)
    }

    func testSuggestionModalityNeverMarksAProjectItemCompleted() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .speculation, confidence: 0.9, projectItemKind: .task, name: "Finish the writeup", projectItemStatus: .completed)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I think I'll finish the writeup tomorrow.")

        pollUntil { !projectManager.items.isEmpty }
        XCTAssertNotEqual(projectManager.items.first?.status, .completed, "speculation must never report a task as completed, even if the LLM proposed that status")
    }

    // MARK: Category 20 - Decision supersession (dedicated, via the coordinator)

    func testConflictingDecisionInTheSameContextSupersedesThePrevious() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.8, statement: "Use method B", context: "XYZ algorithm")
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Let's use method B.")
        pollUntil { !projectManager.decisions.isEmpty }
        let originalID = projectManager.decisions.first!.id

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.85, statement: "Use Bayesian calibration instead", context: "XYZ algorithm")
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "Actually, let's use Bayesian calibration instead.")
        pollUntil { projectManager.decisions.count == 2 }

        let old = projectManager.decision(id: originalID)
        let new = projectManager.decisions.first { $0.id != originalID }
        XCTAssertEqual(old?.status, .superseded)
        XCTAssertEqual(old?.supersededBy, new?.id)
        XCTAssertEqual(new?.supersedes, originalID)
        XCTAssertTrue(projectManager.events(forProject: project.id).contains { $0.eventType == .decisionSuperseded }, "supersedeDecision's automatic event mechanism must fire")
    }

    // MARK: Category 21 - multiple candidates from one turn

    func testOneTurnCanProduceMultipleCandidatesOfDifferentTypes() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.6, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference),
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.6, projectItemKind: .result, name: "Calibration improved by 12%"),
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.8, statement: "Use Bayesian calibration", context: "XYZ algorithm")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer dark mode. Calibration improved by 12%. Let's use Bayesian calibration.")

        pollUntil { !memoryManager.edges.isEmpty && !projectManager.items.isEmpty && !projectManager.decisions.isEmpty }
        XCTAssertEqual(memoryManager.edges.count, 1)
        XCTAssertEqual(projectManager.items.count, 1)
        XCTAssertEqual(projectManager.decisions.count, 1)
    }

    // MARK: Category 22 - user correction

    func testUserCorrectionInvalidatesLastExtractionAndReplacementBecomesActive() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        let sessionID = UUID()

        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "React", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer React.")
        pollUntil { memoryManager.edges.count == 1 }
        let reactEdgeID = memoryManager.edges.first!.id

        // The correction is detected locally BEFORE the LLM batch runs (invalidating React
        // immediately), and the LLM's own response for this same turn separately proposes the
        // replacement (Vue) - exactly like a real turn containing both signals at once.
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "Vue", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "No, that's wrong. I prefer Vue.")
        pollUntil { memoryManager.edges.count == 2 }

        XCTAssertEqual(memoryManager.edge(id: reactEdgeID)?.status, .invalidated, "the corrected memory must be invalidated")
        XCTAssertNotNil(memoryManager.edges.first { $0.literalValue == "Vue" && $0.status == .active }, "the replacement must become active")
        XCTAssertEqual(memoryManager.edge(id: reactEdgeID)?.literalValue, "React", "provenance of the original (now invalidated) memory must be preserved, never deleted")
    }

    // MARK: Category 23 - retry behavior

    func testTransientFailureRetriesAndEventuallySucceeds() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.failuresBeforeSuccess = 1
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.maxRetryCount = 2

        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "I prefer dark mode.")

        pollUntil { !memoryManager.edges.isEmpty }
        XCTAssertEqual(stub.callCount, 2, "the first call failed, the retry succeeded")
        XCTAssertEqual(memoryManager.edges.count, 1)
    }

    func testRetryIsBoundedAndBatchIsDroppedAfterExhaustion() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.alwaysFail = true
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.maxRetryCount = 2

        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "I prefer dark mode.")

        // Wait long enough for all retries to exhaust (backoff is tiny in tests).
        pollUntil(timeout: 2.0) { stub.callCount >= 3 }
        XCTAssertEqual(stub.callCount, 3, "1 initial attempt + 2 retries, then drop - never retried indefinitely")
        XCTAssertTrue(memoryManager.edges.isEmpty)
    }

    // MARK: Category 24 - extraction failure isolation

    func testExtractionFailureNeverThrowsOrLeavesPartialState() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.alwaysFail = true
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.maxRetryCount = 1

        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "I prefer dark mode.")
        pollUntil(timeout: 1.0) { stub.callCount >= 2 }

        // The mere fact this test completes without crashing/throwing IS the primary proof.
        XCTAssertTrue(memoryManager.edges.isEmpty)
        XCTAssertTrue(memoryManager.entities.isEmpty, "no partial entity creation from a failed batch")
        XCTAssertTrue(projectManager.items.isEmpty)
    }

    // MARK: Category 25 - no blocking

    func testTurnFinalizedReturnsImmediately() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)

        let start = Date()
        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "I prefer dark mode, this is long enough to be worth extracting.")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.05, "turnFinalized must return near-instantly - all real work happens asynchronously off the caller's thread")
    }

    // MARK: Category 26 - candidate remains ephemeral

    func testProcessingResultsInExactlyTheExpectedPersistedRowsNoCandidateResidue() {
        let memoryStore = MemoryStore(inMemory: true)
        let projectStore = ProjectStore(inMemory: true)
        let memoryManager = MemoryManager(store: memoryStore)
        let projectManager = ProjectManager(store: projectStore)
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.6, subjectName: "self", predicate: "prefers", literalValue: "dark mode", memoryCategory: .preference),
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.6, projectItemKind: .task, name: "Some task")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "I prefer dark mode. Some task needs doing.")

        pollUntil { !memoryManager.edges.isEmpty && !projectManager.items.isEmpty }

        // Re-read directly from the stores (not the in-memory manager arrays) - proves the
        // ONLY thing that landed in persistent storage is the expected final rows. There is
        // no ExtractionCandidate store/entity anywhere for a stray candidate to have leaked
        // into - ExtractionCandidate is Codable/Equatable only, never given a Core Data
        // record type, and this store's model (verified in MemoryStoreTests/ProjectStoreTests)
        // contains exactly the entities each store was built with, nothing extra.
        XCTAssertEqual(memoryStore.loadAllEdges().count, 1)
        XCTAssertEqual(projectStore.loadAllProjectItems().count, 1)
    }

    // MARK: Category 27 - no ProjectSessionLink mutation

    func testExtractionNeverCreatesOrMutatesAProjectSessionLink() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID() // deliberately never linked via assignSession

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .directStatement, confidence: 0.7, projectItemKind: .task, name: "Some task", mentionedProjectName: project.name)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "For Trustworthy AI, some task needs doing.")

        pollUntil { !projectManager.items.isEmpty }
        XCTAssertEqual(projectManager.items.first?.projectID, project.id, "sanity: tier 2 resolution DID find the project")
        XCTAssertTrue(projectManager.sessionLinks.isEmpty, "resolving a project for a fact must NEVER create a ProjectSessionLink - only explicit user action (assignSession) may do that")
        XCTAssertNil(projectManager.project(forSession: sessionID), "the session itself must remain completely unlinked")
    }

    // MARK: Category 28 - provenance preservation

    func testProvenanceIsPreservedThroughSupersession() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)

        let sessionA = UUID()
        let messageA = UUID()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "React", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionA, messageID: messageA, text: "I use React.")
        pollUntil { memoryManager.edges.count == 1 }
        let originalID = memoryManager.edges.first!.id

        let sessionB = UUID()
        let messageB = UUID()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .memoryEdge, modality: .directStatement, confidence: 0.7, subjectName: "self", predicate: "prefers", literalValue: "Vue", memoryCategory: .preference)
        ]
        coordinator.turnFinalized(sessionID: sessionB, messageID: messageB, text: "I use Vue now.")
        pollUntil { memoryManager.edges.count == 2 }

        let old = memoryManager.edge(id: originalID)
        let new = memoryManager.edges.first { $0.id != originalID }
        XCTAssertEqual(old?.sourceSessionID, sessionA, "the superseded edge's ORIGINAL provenance must be untouched")
        XCTAssertEqual(old?.sourceMessageIDs, [messageA])
        XCTAssertEqual(new?.sourceSessionID, sessionB, "the new edge gets its OWN provenance")
        XCTAssertEqual(new?.sourceMessageIDs, [messageB])
    }

    // MARK: Phase 4.3 - Decision -> ProjectItem structural linking
    //
    // `Decision.relatedItemID` has always existed and always persisted correctly, but nothing on
    // the decision path ever populated it: the extraction prompt requested `relatedItemName` only
    // for projectItem candidates, and `processDecisionCandidate` built `Decision(...)` without the
    // argument. Live evidence: 23/23 decisions in the Phase 4.2 synthetic store had
    // relatedItemID == nil, so `CrossLayerConflictResolver`'s decision-vs-item branch had never
    // executed. These tests assert the link points at the EXACT intended item - never merely
    // "non-nil" - and that an ambiguous or unmatched reference stays nil rather than guessing.

    private func makeLinkingFixture() -> (memory: MemoryManager, projects: ProjectManager, project: Project, sessionID: UUID) {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)
        return (memoryManager, projectManager, project, sessionID)
    }

    /// 1: an explicit relatedItemName matching an existing item links to THAT item.
    func testDecisionLinksToTheExactProjectItemNamedByRelatedItemName() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Conformal Prediction approach", sourceSessionID: fixture.sessionID))
        let decoy = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Conformal Prediction approach", statement: "Reject conformal prediction for message payload bounds", context: "message payload bounds")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We are rejecting conformal prediction for the message payload bounds.")

        pollUntil { !fixture.projects.decisions.isEmpty }
        XCTAssertEqual(fixture.projects.decisions.first?.relatedItemID, target.id, "must point at the named item")
        XCTAssertNotEqual(fixture.projects.decisions.first?.relatedItemID, decoy.id)
    }

    /// 2: no relatedItemName and no matching context - stays nil.
    func testDecisionWithoutAnyItemReferenceLeavesRelatedItemIDNil() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Conformal Prediction approach", sourceSessionID: fixture.sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Ship the paper draft on Friday")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We decided to ship the paper draft on Friday.")

        pollUntil { !fixture.projects.decisions.isEmpty }
        XCTAssertNil(fixture.projects.decisions.first?.relatedItemID)
    }

    /// 3: an explicit relatedItemName that matches nothing - stays nil, no item invented.
    func testDecisionWithUnmatchedRelatedItemNameLeavesRelatedItemIDNilAndCreatesNoItem() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))
        let itemCountBefore = fixture.projects.items.count

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Kalman filter stack", statement: "Adopt temperature scaling", context: "calibration")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We are adopting temperature scaling.")

        pollUntil { !fixture.projects.decisions.isEmpty }
        XCTAssertNil(fixture.projects.decisions.first?.relatedItemID)
        XCTAssertEqual(fixture.projects.items.count, itemCountBefore, "a decision must never invent a ProjectItem")
    }

    /// 4: context fallback resolves when it unambiguously names an existing item.
    func testDecisionFallsBackToContextWhenItUnambiguouslyNamesAnItem() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Online temperature scaling layer", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Pivot to a lightweight approach", context: "Online temperature scaling layer")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We are pivoting on the online temperature scaling layer.")

        pollUntil { !fixture.projects.decisions.isEmpty }
        XCTAssertEqual(fixture.projects.decisions.first?.relatedItemID, target.id)
    }

    /// 5: an ambiguous reference matching TWO similarly-named items must NOT guess.
    func testAmbiguousReferenceMatchingTwoSimilarItemsLeavesRelatedItemIDNil() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Monte Carlo Dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Monte Carlo Dropout approach", sourceSessionID: fixture.sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Monte Carlo Dropout", statement: "Keep MC dropout as the baseline", context: "calibration")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We keep MC dropout as the baseline.")

        pollUntil { !fixture.projects.decisions.isEmpty }
        XCTAssertNil(fixture.projects.decisions.first?.relatedItemID, "two plausible targets is a guess, not a link")
    }

    /// 6: a decision in project A must never link to an identically-named item in project B.
    func testDecisionNeverLinksToAnIdenticallyNamedItemInAnotherProject() {
        let fixture = makeLinkingFixture()
        let otherProject = fixture.projects.createProject(Project(name: "Hotel Revenue Forecasting"))
        let foreignItem = fixture.projects.createProjectItem(ProjectItem(projectID: otherProject.id, kind: .component, name: "Conformal Prediction approach", sourceSessionID: UUID()))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Conformal Prediction approach", statement: "Reject conformal prediction", context: "bounds")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We reject conformal prediction.")

        pollUntil { !fixture.projects.decisions.isEmpty }
        let decision = fixture.projects.decisions.first
        XCTAssertEqual(decision?.projectID, fixture.project.id)
        XCTAssertNil(decision?.relatedItemID, "the only matching item belongs to another project - isolation must hold")
        XCTAssertNotEqual(decision?.relatedItemID, foreignItem.id)
    }

    /// 7: the decision is listed BEFORE the item it references in the same batch - it must still
    /// link, which is what the project-items-first ordering guarantees.
    func testDecisionLinksToAProjectItemCreatedInTheSameBatchEvenWhenListedFirst() {
        let fixture = makeLinkingFixture()

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            // Decision first - the order that previously produced no link at all.
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Conformal Prediction approach", statement: "Reject conformal prediction for message payload bounds", context: "bounds"),
            ExtractionCandidate(type: .projectItem, modality: .explicitTask, confidence: 0.8, projectItemKind: .component, name: "Conformal Prediction approach", projectItemStatus: .active),
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We reject conformal prediction; the conformal prediction approach is tracked.")

        pollUntil { !fixture.projects.decisions.isEmpty && !fixture.projects.items.isEmpty }
        let item = fixture.projects.items.first { $0.name == "Conformal Prediction approach" }
        XCTAssertNotNil(item)
        XCTAssertEqual(fixture.projects.decisions.first?.relatedItemID, item?.id, "same-batch item must be created before the decision resolves its link")
    }

    /// 8: the link survives the real ProjectStore save/load path (no schema change was needed).
    func testRelatedItemIDSurvivesStoreReload() {
        let store = ProjectStore(inMemory: true)
        let projectManager = ProjectManager(store: store)
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)
        let target = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .component, name: "Conformal Prediction approach", sourceSessionID: sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Conformal Prediction approach", statement: "Reject conformal prediction", context: "bounds")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "We reject conformal prediction.")
        pollUntil { !projectManager.decisions.isEmpty }

        // Reload through the SAME store instance's load path - the persisted row, not the
        // in-memory copy.
        let reloaded = store.loadAllDecisions().first { $0.statement == "Reject conformal prediction" }
        XCTAssertEqual(reloaded?.relatedItemID, target.id, "the link must be persisted and reloaded, not just held in memory")
    }

    /// 9: with the link populated, CrossLayerConflictResolver's decision-vs-item branch finally
    /// does what it was written to do - the linked item is deduplicated against its decision.
    /// CrossLayerConflictResolver itself is NOT modified by this phase.
    func testLinkedDecisionSuppressesItsProjectItemInCrossLayerResolution() {
        let projectID = UUID()
        let item = ProjectItem(projectID: projectID, kind: .component, name: "Conformal Prediction approach", sourceSessionID: UUID())
        let linked = Decision(projectID: projectID, statement: "Reject conformal prediction", relatedItemID: item.id, sourceSessionID: UUID())
        let unlinked = Decision(projectID: projectID, statement: "Reject conformal prediction", sourceSessionID: UUID())

        func resolve(_ decision: Decision) -> [ScoredEvidence<ProjectItem>] {
            let provenance = Provenance(sourceSessionID: nil, sourceMessageIDs: [], timestamp: Date())
            let decisionEvidence = ScoredEvidence(value: decision, source: .decision(decision.id), score: 0.9, temporalStatus: .current, provenance: provenance, renderedText: decision.statement)
            let itemEvidence = ScoredEvidence(value: item, source: .projectItem(item.id), score: 0.8, temporalStatus: .current, provenance: provenance, renderedText: item.name)
            return CrossLayerConflictResolver.resolve(memories: [], projectItems: [itemEvidence], decisions: [decisionEvidence], intent: .current).projectItems
        }

        XCTAssertTrue(resolve(linked).isEmpty, "a linked decision must suppress its own project item")
        XCTAssertEqual(resolve(unlinked).count, 1, "without the link the item is kept - the pre-fix behaviour")
    }

    // MARK: Phase 4.3b - source priority (relatedItemName -> statement -> context)
    //
    // Live evidence drove this: a real populated run produced 7 decisions and 0 links because the
    // model emitted no `relatedItemName` and only prose `context` values - while two decisions
    // named their item almost verbatim in the STATEMENT. Sources are now tried strongest-first,
    // with ambiguity at any source TERMINAL (never silently overridden by a weaker source).

    private func runDecision(
        _ fixture: (memory: MemoryManager, projects: ProjectManager, project: Project, sessionID: UUID),
        relatedItemName: String? = nil,
        statement: String,
        context: String? = nil,
        extraCandidates: [ExtractionCandidate] = []
    ) -> Decision? {
        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = extraCandidates + [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: relatedItemName, statement: statement, context: context)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: statement)
        pollUntil { !fixture.projects.decisions.isEmpty }
        return fixture.projects.decisions.first
    }

    /// A: an explicit relatedItemName wins over what statement/context would have matched.
    func testRelatedItemNameTakesPriorityOverStatementAndContext() {
        let fixture = makeLinkingFixture()
        let named = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Online temperature scaling layer", sourceSessionID: fixture.sessionID))
        let viaStatement = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Gridworld calibration sweep", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   relatedItemName: "Online temperature scaling layer",
                                   statement: "Run the Gridworld calibration sweep next",
                                   context: "Gridworld calibration sweep")

        XCTAssertEqual(decision?.relatedItemID, named.id, "the explicitly named item must win")
        XCTAssertNotEqual(decision?.relatedItemID, viaStatement.id)
    }

    /// B: no relatedItemName - the statement resolves it.
    func testStatementResolvesTheLinkWhenRelatedItemNameIsAbsent() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Testing temperature scaling versus MC dropout", sourceSessionID: fixture.sessionID))

        // The statement contains the item name contiguously, which is what the existing
        // conservative substring rule requires.
        let decision = runDecision(fixture, statement: "We are going ahead with Testing temperature scaling versus MC dropout")

        XCTAssertEqual(decision?.relatedItemID, target.id)
    }

    /// C1: the EXACT first live miss - now LINKS via token containment ("online" inserted).
    func testLiveMissOneTemperatureScalingNowLinksViaTokenContainment() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Testing temperature scaling versus MC dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .task, name: "Generate initial calibration curves", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   statement: "Pivot to testing online temperature scaling versus MC dropout",
                                   context: "agent confidence calibration for paper draft")

        XCTAssertEqual(decision?.relatedItemID, target.id, "the exact link missed in the live run must now resolve")
    }

    /// C2: the EXACT second live miss - now LINKS ("into two separate" inserted).
    func testLiveMissTwoTransientGroupDemandNowLinksViaTokenContainment() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .task, name: "Split transient and group demand sub-models", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .task, name: "Investigate exponential retry backoffs for rate shopper scrapers", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   statement: "Split transient and group demand into two separate sub-models",
                                   context: "Demand pipeline and ADR prediction sub-models")

        XCTAssertEqual(decision?.relatedItemID, target.id, "the exact link missed in the live run must now resolve")
    }

    /// D: statement matches nothing - context is still attempted.
    func testContextIsStillTriedWhenStatementMatchesNothing() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   statement: "Freeze the paper draft on Friday",
                                   context: "Gridworld Environment")

        XCTAssertEqual(decision?.relatedItemID, target.id)
    }

    /// E: an AMBIGUOUS relatedItemName must not fall through to a statement/context that would
    /// have produced a (possibly wrong) link - the safe answer is nil.
    func testAmbiguousRelatedItemNameStopsTheSearchInsteadOfFallingThrough() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Monte Carlo Dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Monte Carlo Dropout approach", sourceSessionID: fixture.sessionID))
        let wouldMatchStatement = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   relatedItemName: "Monte Carlo Dropout",
                                   statement: "Keep the Gridworld Environment as the baseline",
                                   context: "Gridworld Environment")

        XCTAssertNil(decision?.relatedItemID, "an ambiguous strongest source must stop the search, not defer to a weaker one")
        XCTAssertNotEqual(decision?.relatedItemID, wouldMatchStatement.id)
    }

    /// F: ambiguous statement - nil, and context must not rescue it.
    func testAmbiguousStatementYieldsNilAndDoesNotFallThroughToContext() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Monte Carlo Dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Monte Carlo Dropout approach", sourceSessionID: fixture.sessionID))
        let contextTarget = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   statement: "Monte Carlo Dropout",
                                   context: "Gridworld Environment")

        XCTAssertNil(decision?.relatedItemID)
        XCTAssertNotEqual(decision?.relatedItemID, contextTarget.id)
    }

    /// G: ambiguous context - nil.
    func testAmbiguousContextYieldsNil() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Monte Carlo Dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Monte Carlo Dropout approach", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   statement: "Freeze the paper draft on Friday",
                                   context: "Monte Carlo Dropout")

        XCTAssertNil(decision?.relatedItemID)
    }

    /// H: nothing matches anywhere - nil, and no item is invented.
    func testNoSourceMatchesYieldsNilAndCreatesNoItem() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))
        let before = fixture.projects.items.count

        let decision = runDecision(fixture,
                                   relatedItemName: "Kalman filter stack",
                                   statement: "Freeze the paper draft on Friday",
                                   context: "publication timeline")

        XCTAssertNil(decision?.relatedItemID)
        XCTAssertEqual(fixture.projects.items.count, before)
    }

    /// I: a statement naming an item that exists only in ANOTHER project must never link.
    func testStatementNeverMatchesAnItemInAnotherProject() {
        let fixture = makeLinkingFixture()
        let otherProject = fixture.projects.createProject(Project(name: "Hotel Revenue Forecasting"))
        let foreign = fixture.projects.createProjectItem(ProjectItem(projectID: otherProject.id, kind: .task, name: "Split transient and group demand sub-models", sourceSessionID: UUID()))

        let decision = runDecision(fixture, statement: "Split transient and group demand into two separate sub-models")

        XCTAssertEqual(decision?.projectID, fixture.project.id)
        XCTAssertNil(decision?.relatedItemID)
        XCTAssertNotEqual(decision?.relatedItemID, foreign.id)
    }

    /// J: same-batch item created before the decision, resolved via STATEMENT this time.
    func testStatementLinksToAProjectItemCreatedInTheSameBatch() {
        let fixture = makeLinkingFixture()
        let itemCandidate = ExtractionCandidate(type: .projectItem, modality: .explicitTask, confidence: 0.8, projectItemKind: .experiment, name: "Testing temperature scaling versus MC dropout", projectItemStatus: .active)

        let decision = runDecision(fixture,
                                   statement: "We are going ahead with Testing temperature scaling versus MC dropout",
                                   extraCandidates: [itemCandidate])

        let item = fixture.projects.items.first { $0.name == "Testing temperature scaling versus MC dropout" }
        XCTAssertNotNil(item)
        XCTAssertEqual(decision?.relatedItemID, item?.id)
    }

    /// K: a statement-resolved link survives the real store save/load path.
    func testStatementResolvedLinkSurvivesStoreReload() {
        let store = ProjectStore(inMemory: true)
        let projectManager = ProjectManager(store: store)
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        let sessionID = UUID()
        projectManager.assignSession(sessionID, to: project.id)
        let target = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .experiment, name: "Testing temperature scaling versus MC dropout", sourceSessionID: sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "We are going ahead with Testing temperature scaling versus MC dropout")
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        coordinator.turnFinalized(sessionID: sessionID, messageID: UUID(), text: "We are going ahead with Testing temperature scaling versus MC dropout")
        pollUntil { !projectManager.decisions.isEmpty }

        let reloaded = store.loadAllDecisions().first
        XCTAssertEqual(reloaded?.relatedItemID, target.id)
    }

    // MARK: Phase 4.3c - token-containment matching
    //
    // Substring matching could not link the two real misses: one inserted word ("online";
    // "into two separate") broke contiguity while every meaningful word was present. The rule is
    // now set containment - every SIGNIFICANT token of the ProjectItem name must appear in the
    // source - which is deterministic, order-independent, and carries no scoring or ranking.

    /// 5: a shared generic token can never establish a link on its own. This is the Q9 shape.
    func testGenericTokenAloneNeverLinks() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Conformal Prediction approach", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture, statement: "What was our approach to hotel demand forecasting?")

        XCTAssertNil(decision?.relatedItemID, "\"approach\" alone must never link")
    }

    /// 6: partial overlap is not a match - a partially-named item is not the item.
    func testPartialTokenOverlapDoesNotLink() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Online temperature scaling layer", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture, statement: "Let's discuss temperature scaling")

        XCTAssertNil(decision?.relatedItemID, "\"online\" and \"layer\" are absent - not this item")
    }

    /// 7: two items both fully contained in the source - ambiguous, so nil.
    func testTwoFullyContainedItemsYieldNil() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Temperature scaling", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .result, name: "Temperature scaling calibration", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture, statement: "Adopt temperature scaling calibration for the paper")

        XCTAssertNil(decision?.relatedItemID, "two fully-contained items is ambiguous, not a link")
    }

    /// 4/D: context resolves via token containment when the statement matches nothing.
    func testContextResolvesViaTokenContainment() {
        let fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Local transcript storage architecture", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   statement: "Encrypt everything at rest before shipping",
                                   context: "Local transcript storage architecture review")

        XCTAssertEqual(decision?.relatedItemID, target.id)
    }

    /// 10: an identically-named item in another project is never even considered.
    func testTokenContainmentNeverCrossesProjects() {
        let fixture = makeLinkingFixture()
        let other = fixture.projects.createProject(Project(name: "Hotel Revenue Forecasting"))
        let foreign = fixture.projects.createProjectItem(ProjectItem(projectID: other.id, kind: .task, name: "Split transient and group demand sub-models", sourceSessionID: UUID()))

        let decision = runDecision(fixture, statement: "Split transient and group demand into two separate sub-models")

        XCTAssertNil(decision?.relatedItemID)
        XCTAssertNotEqual(decision?.relatedItemID, foreign.id)
    }

    // MARK: Phase 4.3c - relatedItemName observability

    /// Distinguishes "the model emitted no relatedItemName" from "it emitted one that matched
    /// nothing" - the distinction that made the live 0-link run unexplainable.
    func testDiagnosticsDistinguishAbsentUnmatchedAndMatchedRelatedItemName() {
        // (a) emitted and matched
        var fixture = makeLinkingFixture()
        let target = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Online temperature scaling layer", sourceSessionID: fixture.sessionID))
        var stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Online temperature scaling layer", statement: "Adopt it")]
        var coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "Adopt the online temperature scaling layer")
        pollUntil { coordinator.lastDecisionLinkDiagnostics != nil }
        XCTAssertEqual(coordinator.lastDecisionLinkDiagnostics?.relatedItemName, "Online temperature scaling layer")
        XCTAssertEqual(coordinator.lastDecisionLinkDiagnostics?.matchedSource, .relatedItemName)
        XCTAssertEqual(coordinator.lastDecisionLinkDiagnostics?.resolvedItemID, target.id)

        // (b) emitted but matched nothing
        fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))
        stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, relatedItemName: "Kalman filter stack", statement: "Freeze the draft")]
        coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "Freeze the draft on Friday")
        pollUntil { coordinator.lastDecisionLinkDiagnostics != nil }
        XCTAssertEqual(coordinator.lastDecisionLinkDiagnostics?.relatedItemName, "Kalman filter stack", "emitted...")
        XCTAssertNil(coordinator.lastDecisionLinkDiagnostics?.matchedSource, "...but unmatched")

        // (c) never emitted - the actual live situation
        fixture = makeLinkingFixture()
        stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Freeze the draft")]
        coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "Freeze the draft on Friday")
        pollUntil { coordinator.lastDecisionLinkDiagnostics != nil }
        XCTAssertNil(coordinator.lastDecisionLinkDiagnostics?.relatedItemName, "the model emitted none at all")
        XCTAssertNil(coordinator.lastDecisionLinkDiagnostics?.matchedSource)
    }

    /// Ambiguity is reported with the source that caused it.
    func testDiagnosticsReportTheAmbiguousSource() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Temperature scaling", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .result, name: "Temperature scaling calibration", sourceSessionID: fixture.sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [ExtractionCandidate(type: .decision, modality: .explicitDecision, confidence: 0.9, statement: "Adopt temperature scaling calibration")]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "Adopt temperature scaling calibration")

        pollUntil { coordinator.lastDecisionLinkDiagnostics != nil }
        XCTAssertEqual(coordinator.lastDecisionLinkDiagnostics?.ambiguousSource, .statement)
        XCTAssertNil(coordinator.lastDecisionLinkDiagnostics?.resolvedItemID)
    }

    /// 15: the project-item path's own matching behaviour is unchanged - an item candidate whose
    /// name substring-matches an existing item still UPDATES it rather than creating a duplicate.
    func testProjectItemMatchingBehaviourIsUnchanged() {
        let fixture = makeLinkingFixture()
        let existing = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .task, name: "Generate initial calibration curves", status: .planned, sourceSessionID: fixture.sessionID))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = [
            ExtractionCandidate(type: .projectItem, modality: .explicitTask, confidence: 0.8, projectItemKind: .task, name: "Generate initial calibration curves", projectItemStatus: .completed)
        ]
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We generated the initial calibration curves.")

        pollUntil { fixture.projects.items.first(where: { $0.id == existing.id })?.status == .completed }
        XCTAssertEqual(fixture.projects.items.count, 1, "must update the existing item, not create a second one")
        XCTAssertEqual(fixture.projects.items.first?.status, .completed)
    }

    // MARK: Phase 4.3d - canonical ProjectItem names supplied to extraction

    /// 2 + 3: only the ACTIVE project's item names are supplied; another project's items are
    /// never exposed to the model.
    func testOnlyTheActiveProjectsItemNamesAreSuppliedToExtraction() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Testing temperature scaling versus MC dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let otherProject = fixture.projects.createProject(Project(name: "Hotel Revenue Forecasting"))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: otherProject.id, kind: .task, name: "Split transient and group demand sub-models", sourceSessionID: UUID()))

        let stub = StubExtractionLLMClient()
        stub.candidatesToReturn = []
        let coordinator = makeCoordinator(stub: stub, memoryManager: fixture.memory, projectManager: fixture.projects)
        coordinator.turnFinalized(sessionID: fixture.sessionID, messageID: UUID(), text: "We talked about the calibration work today and agreed on next steps.")

        pollUntil { !stub.receivedProjectItemNames.isEmpty }
        let supplied = Set(stub.receivedProjectItemNames.first ?? [])
        XCTAssertEqual(supplied, ["Testing temperature scaling versus MC dropout", "Gridworld Environment"])
        XCTAssertFalse(supplied.contains("Split transient and group demand sub-models"), "another project's item must never be exposed")
    }

    /// A session with no project link supplies no names at all (and therefore no prompt section).
    func testSessionWithNoProjectSuppliesNoItemNames() {
        let memoryManager = MemoryManager(store: MemoryStore(inMemory: true))
        let projectManager = ProjectManager(store: ProjectStore(inMemory: true))
        let project = projectManager.createProject(Project(name: "Trustworthy AI"))
        _ = projectManager.createProjectItem(ProjectItem(projectID: project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: UUID()))

        let stub = StubExtractionLLMClient()
        let coordinator = makeCoordinator(stub: stub, memoryManager: memoryManager, projectManager: projectManager)
        // Unlinked session - deliberately never assigned to any project.
        coordinator.turnFinalized(sessionID: UUID(), messageID: UUID(), text: "We agreed to ship the calibration work next week.")

        pollUntil { !stub.receivedProjectItemNames.isEmpty }
        XCTAssertEqual(stub.receivedProjectItemNames.first, [], "no project link means no names, not another project's names")
    }

    /// 9: same-batch ordering is unchanged - items still precede decisions, so a decision can
    /// still link to an item its own batch created even though that item could not have been in
    /// the prompt.
    func testSameBatchOrderingStillLinksAnItemThatCouldNotHaveBeenInThePrompt() {
        let fixture = makeLinkingFixture()
        let itemCandidate = ExtractionCandidate(type: .projectItem, modality: .explicitTask, confidence: 0.8, projectItemKind: .experiment, name: "Testing temperature scaling versus MC dropout", projectItemStatus: .active)

        let decision = runDecision(fixture,
                                   statement: "Pivot to testing online temperature scaling versus MC dropout",
                                   extraCandidates: [itemCandidate])

        let item = fixture.projects.items.first { $0.name == "Testing temperature scaling versus MC dropout" }
        XCTAssertEqual(decision?.relatedItemID, item?.id, "the resolver remains the gate for same-batch items")
    }

    // MARK: Phase 4.3c - exact-name specificity disambiguation
    //
    // Live probe evidence (LiveExtractionSchemaProbeTests, 18 measured requests) established that
    // the model copies item names VERBATIM when it names one at all - 9/9 emitted names were exact
    // copies of a supplied canonical name or of a same-batch item it proposed, with 0 paraphrases
    // and 0 invented names. That made a previously-unreachable false-AMBIGUITY defect reachable:
    // when one item's name is a strict token-subset of another's, naming the longer one matched
    // BOTH and the link was discarded.

    /// The defect: the exactly-named item wins over a strictly LESS SPECIFIC rival that token
    /// containment also matched. Names taken from the shape actually observed live.
    func testExactlyNamedItemWinsOverAStrictlyLessSpecificRival() {
        let fixture = makeLinkingFixture()
        let specific = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Split transient and group demand sub-models in ADR prediction pipeline", sourceSessionID: fixture.sessionID))
        let lessSpecific = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Split transient and group demand models", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture,
                                   relatedItemName: "Split transient and group demand sub-models in ADR prediction pipeline",
                                   statement: "Split transient and group demand into two separate sub-models")

        XCTAssertEqual(decision?.relatedItemID, specific.id, "the verbatim-named, more specific item must win")
        XCTAssertNotEqual(decision?.relatedItemID, lessSpecific.id)
    }

    /// The guard rail: rivals of EQUAL specificity still block the link. This is the same pair
    /// `testAmbiguousReferenceMatchingTwoSimilarItemsLeavesRelatedItemIDNil` pins, asserted here
    /// from the specificity rule's side - "approach" is stripped as a generic token, so the two
    /// names are token-identical and neither is strictly less specific than the other.
    func testExactNameDoesNotBreakATieBetweenEquallySpecificItems() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .experiment, name: "Monte Carlo Dropout", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Monte Carlo Dropout approach", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture, relatedItemName: "Monte Carlo Dropout", statement: "Keep MC dropout as the baseline")

        XCTAssertNil(decision?.relatedItemID, "equal specificity is a genuine tie - it must stay unlinked")
    }

    /// The rule may only ever pick a winner from items token containment ALREADY matched - it can
    /// never resurrect a name containment rejected outright.
    func testExactNameSpecificityNeverInventsAMatchContainmentRejected() {
        let fixture = makeLinkingFixture()
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Kalman filter stack", sourceSessionID: fixture.sessionID))
        _ = fixture.projects.createProjectItem(ProjectItem(projectID: fixture.project.id, kind: .component, name: "Gridworld Environment", sourceSessionID: fixture.sessionID))

        let decision = runDecision(fixture, relatedItemName: "Particle filter stack", statement: "Adopt the particle filter stack")

        XCTAssertNil(decision?.relatedItemID, "a name matching nothing must stay unlinked")
    }

    /// Project isolation survives the new rule: the strictly-less-specific rival living in ANOTHER
    /// project must not even be considered, and the exact name must not reach across projects.
    func testExactNameSpecificityRespectsProjectIsolation() {
        let fixture = makeLinkingFixture()
        let otherProject = fixture.projects.createProject(Project(name: "Hotel Revenue Forecasting"))
        let foreign = fixture.projects.createProjectItem(ProjectItem(projectID: otherProject.id, kind: .component, name: "Split transient and group demand sub-models in ADR prediction pipeline", sourceSessionID: UUID()))

        let decision = runDecision(fixture,
                                   relatedItemName: "Split transient and group demand sub-models in ADR prediction pipeline",
                                   statement: "Split transient and group demand into two separate sub-models")

        XCTAssertNil(decision?.relatedItemID, "the only exact match belongs to another project")
        XCTAssertNotEqual(decision?.relatedItemID, foreign.id)
    }

    /// A same-batch item named VERBATIM by the decision links end to end - the case the prompt
    /// change in `ExtractionLLMClient.systemInstruction` exists to enable, and the dominant
    /// real-world case (a project's first meeting, where no tracked item exists yet).
    func testDecisionLinksToASameBatchItemItNamedVerbatim() {
        let fixture = makeLinkingFixture()
        let itemCandidate = ExtractionCandidate(type: .projectItem, modality: .explicitTask, confidence: 0.8, projectItemKind: .task, name: "Implement rate-limiting retry backoff for rate shopper", projectItemStatus: .planned)

        let decision = runDecision(fixture,
                                   relatedItemName: "Implement rate-limiting retry backoff for rate shopper",
                                   statement: "Reject falling back to third-party OTA feeds and attempt exponential retry backoffs first",
                                   extraCandidates: [itemCandidate])

        let item = fixture.projects.items.first { $0.name == "Implement rate-limiting retry backoff for rate shopper" }
        XCTAssertNotNil(item)
        XCTAssertEqual(decision?.relatedItemID, item?.id, "a same-batch item named verbatim must link")
    }
}
