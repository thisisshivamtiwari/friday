import XCTest
@testable import FounderOfficeCopilotCore

/// Covers MemoryManager: in-memory state management, persistence mirroring, lookup
/// accessors, and staleness calculation. Every test uses an in-memory MemoryStore, so
/// nothing here ever touches the real app's saved memory.
///
/// Phase 3.1 note: MemoryManager currently has NO extraction logic and NO reference to
/// AIEngineController/Gemini*/Audio* - this file only exercises the foundation surface that
/// exists right now (load, create, update, forget, permanently delete, lookups, staleness).
final class MemoryManagerTests: XCTestCase {
    private func makeManager(store: MemoryStore = MemoryStore(inMemory: true)) -> MemoryManager {
        MemoryManager(store: store)
    }

    private func makeEntity(name: String = "Sarah", kind: MemoryEntity.Kind = .person) -> MemoryEntity {
        MemoryEntity(kind: kind, name: name)
    }

    private func makeEdge(subjectEntityID: UUID, predicate: String = "prefers", lastConfirmedAt: Date = Date()) -> MemoryEdge {
        MemoryEdge(subjectEntityID: subjectEntityID, predicate: predicate, category: .preference, confidence: 0.6, sourceSessionID: UUID(), lastConfirmedAt: lastConfirmedAt)
    }

    /// Polls a MemoryStore's synchronous read until `predicate` is satisfied or the timeout
    /// elapses - used to verify MemoryManager's fire-and-forget mirroring actually reached
    /// the store, without adding a completion parameter MemoryManager itself doesn't have
    /// (ChatSessionManager doesn't expose one either - this keeps the same shape).
    private func pollUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: Initial load

    func testFreshManagerHasNoEntitiesOrEdges() {
        let manager = makeManager()
        XCTAssertTrue(manager.entities.isEmpty)
        XCTAssertTrue(manager.edges.isEmpty)
    }

    func testManagerLoadsExistingStoreStateAtInit() {
        let store = MemoryStore(inMemory: true)
        let createExpectation = expectation(description: "entity created")
        let entity = makeEntity()
        store.createEntity(entity) { createExpectation.fulfill() }
        wait(for: [createExpectation], timeout: 2.0)

        let manager = makeManager(store: store)

        XCTAssertEqual(manager.entities.count, 1)
        XCTAssertEqual(manager.entities.first?.id, entity.id)
    }

    // MARK: In-memory mutation

    func testCreateEntityAddsItToInMemoryState() {
        let manager = makeManager()
        let entity = makeEntity()

        manager.createEntity(entity)

        XCTAssertEqual(manager.entities.count, 1)
        XCTAssertEqual(manager.entities.first?.id, entity.id)
    }

    func testUpdateEntityChangesInMemoryStateInPlace() {
        let manager = makeManager()
        var entity = makeEntity(name: "Sarah")
        manager.createEntity(entity)

        entity.name = "Sarah Chen"
        manager.updateEntity(entity)

        XCTAssertEqual(manager.entities.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(manager.entities.first?.name, "Sarah Chen")
    }

    func testUpdateEntityWithUnknownIDIsNoOp() {
        let manager = makeManager()
        let neverCreated = makeEntity()

        manager.updateEntity(neverCreated)

        XCTAssertTrue(manager.entities.isEmpty)
    }

    func testCreateEdgeAddsItToInMemoryState() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)

        manager.createEdge(edge)

        XCTAssertEqual(manager.edges.count, 1)
        XCTAssertEqual(manager.edges.first?.id, edge.id)
    }

    func testUpdateEdgeChangesInMemoryStateInPlace() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        var edge = makeEdge(subjectEntityID: subject.id)
        manager.createEdge(edge)

        edge.confidence = 0.95
        edge.confirmationCount = 4
        manager.updateEdge(edge)

        XCTAssertEqual(manager.edges.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(manager.edges.first?.confidence, 0.95)
        XCTAssertEqual(manager.edges.first?.confirmationCount, 4)
    }

    func testForgetEdgeSetsStatusToForgottenWithoutRemovingTheRow() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)
        manager.createEdge(edge)

        manager.forgetEdge(id: edge.id)

        XCTAssertEqual(manager.edges.count, 1, "forgetting is a status change, not a removal")
        XCTAssertEqual(manager.edge(id: edge.id)?.status, .forgotten)
    }

    func testForgetEdgeWithUnknownIDIsNoOp() {
        let manager = makeManager()
        manager.forgetEdge(id: UUID())
        XCTAssertTrue(manager.edges.isEmpty)
    }

    func testPermanentlyDeleteEdgeRemovesItFromInMemoryState() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)
        manager.createEdge(edge)

        manager.permanentlyDeleteEdge(id: edge.id)

        XCTAssertTrue(manager.edges.isEmpty)
    }

    func testPermanentlyDeleteEntityRemovesItFromInMemoryState() {
        let manager = makeManager()
        let entity = manager.createEntity(makeEntity())

        manager.permanentlyDeleteEntity(id: entity.id)

        XCTAssertTrue(manager.entities.isEmpty)
    }

    func testForgettingIsDistinctFromPermanentDeletion() {
        // Direct regression guard for the privacy requirement: forgetting must never remove
        // the row the way permanent deletion does.
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)
        manager.createEdge(edge)

        manager.forgetEdge(id: edge.id)
        XCTAssertEqual(manager.edges.count, 1)

        manager.permanentlyDeleteEdge(id: edge.id)
        XCTAssertEqual(manager.edges.count, 0)
    }

    // MARK: Persistence mirroring

    func testCreateEntityMirrorsToTheStore() {
        let store = MemoryStore(inMemory: true)
        let manager = makeManager(store: store)
        let entity = makeEntity()

        manager.createEntity(entity)

        pollUntil { store.loadAllEntities().contains { $0.id == entity.id } }
        XCTAssertTrue(store.loadAllEntities().contains { $0.id == entity.id })
    }

    func testUpdateEntityMirrorsToTheStore() {
        let store = MemoryStore(inMemory: true)
        let manager = makeManager(store: store)
        var entity = makeEntity(name: "Sarah")
        manager.createEntity(entity)
        pollUntil { store.loadAllEntities().contains { $0.id == entity.id } }

        entity.name = "Sarah Chen"
        manager.updateEntity(entity)

        pollUntil { store.loadAllEntities().first { $0.id == entity.id }?.name == "Sarah Chen" }
        XCTAssertEqual(store.loadAllEntities().first { $0.id == entity.id }?.name, "Sarah Chen")
    }

    func testCreateEdgeMirrorsToTheStore() {
        let store = MemoryStore(inMemory: true)
        let manager = makeManager(store: store)
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)

        manager.createEdge(edge)

        pollUntil { store.loadAllEdges().contains { $0.id == edge.id } }
        XCTAssertTrue(store.loadAllEdges().contains { $0.id == edge.id })
    }

    func testForgetEdgeMirrorsToTheStore() {
        let store = MemoryStore(inMemory: true)
        let manager = makeManager(store: store)
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)
        manager.createEdge(edge)
        pollUntil { store.loadAllEdges().contains { $0.id == edge.id } }

        manager.forgetEdge(id: edge.id)

        pollUntil { store.loadAllEdges().first { $0.id == edge.id }?.status == .forgotten }
        XCTAssertEqual(store.loadAllEdges().first { $0.id == edge.id }?.status, .forgotten)
    }

    func testPermanentlyDeleteEdgeMirrorsToTheStore() {
        let store = MemoryStore(inMemory: true)
        let manager = makeManager(store: store)
        let subject = manager.createEntity(makeEntity())
        let edge = makeEdge(subjectEntityID: subject.id)
        manager.createEdge(edge)
        pollUntil { store.loadAllEdges().contains { $0.id == edge.id } }

        manager.permanentlyDeleteEdge(id: edge.id)

        pollUntil { !store.loadAllEdges().contains { $0.id == edge.id } }
        XCTAssertFalse(store.loadAllEdges().contains { $0.id == edge.id })
    }

    // MARK: Lookups

    func testEntityLookupByID() {
        let manager = makeManager()
        let entity = manager.createEntity(makeEntity())
        XCTAssertEqual(manager.entity(id: entity.id)?.id, entity.id)
        XCTAssertNil(manager.entity(id: UUID()))
    }

    func testEntityLookupByNameIsCaseInsensitive() {
        let manager = makeManager()
        manager.createEntity(makeEntity(name: "Sarah Chen"))
        XCTAssertNotNil(manager.entity(named: "sarah chen"))
        XCTAssertNotNil(manager.entity(named: "SARAH CHEN"))
        XCTAssertNil(manager.entity(named: "someone else"))
    }

    func testEntityLookupByNameMatchesAliases() {
        let manager = makeManager()
        manager.createEntity(MemoryEntity(kind: .organization, name: "University of Bath", aliases: ["UOB"]))
        XCTAssertNotNil(manager.entity(named: "UOB"))
        XCTAssertNotNil(manager.entity(named: "uob"))
    }

    func testEntityLookupByNameIgnoresEmptyQuery() {
        let manager = makeManager()
        manager.createEntity(makeEntity())
        XCTAssertNil(manager.entity(named: "   "))
    }

    func testEdgeLookupByID() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        let edge = manager.createEdge(makeEdge(subjectEntityID: subject.id))
        XCTAssertEqual(manager.edge(id: edge.id)?.id, edge.id)
        XCTAssertNil(manager.edge(id: UUID()))
    }

    func testEdgesForSubjectReturnsOnlyThatSubjectsEdges() {
        let manager = makeManager()
        let sarah = manager.createEntity(makeEntity(name: "Sarah"))
        let dave = manager.createEntity(makeEntity(name: "Dave"))
        let sarahEdge = manager.createEdge(makeEdge(subjectEntityID: sarah.id, predicate: "works-at"))
        manager.createEdge(makeEdge(subjectEntityID: dave.id, predicate: "works-at"))

        let sarahEdges = manager.edges(forSubject: sarah.id)

        XCTAssertEqual(sarahEdges.count, 1)
        XCTAssertEqual(sarahEdges.first?.id, sarahEdge.id)
    }

    // MARK: Staleness

    func testStaleEdgesReturnsOnlyEdgesPastTheThreshold() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        let fresh = manager.createEdge(makeEdge(subjectEntityID: subject.id, predicate: "fresh", lastConfirmedAt: Date()))
        let stale = manager.createEdge(makeEdge(subjectEntityID: subject.id, predicate: "stale", lastConfirmedAt: Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600)))

        let staleEdges = manager.staleEdges()

        XCTAssertEqual(staleEdges.map(\.id), [stale.id])
        XCTAssertFalse(staleEdges.map(\.id).contains(fresh.id))
    }

    func testStaleEdgesExcludesNonActiveStatuses() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        var oldEnough = makeEdge(subjectEntityID: subject.id, lastConfirmedAt: Date().addingTimeInterval(-MemoryEdge.staleThreshold - 3600))
        oldEnough.status = .superseded
        manager.createEdge(oldEnough)

        XCTAssertTrue(manager.staleEdges().isEmpty, "only .active edges can be stale")
    }

    func testStaleEdgesIsEmptyWhenNothingIsOld() {
        let manager = makeManager()
        let subject = manager.createEntity(makeEntity())
        manager.createEdge(makeEdge(subjectEntityID: subject.id))
        XCTAssertTrue(manager.staleEdges().isEmpty)
    }

    // MARK: State surviving reload

    func testStateSurvivesReloadIntoAFreshManagerInstance() {
        let store = MemoryStore(inMemory: true)
        let firstManager = makeManager(store: store)
        let subject = firstManager.createEntity(makeEntity(name: "Sarah"))
        let edge = firstManager.createEdge(makeEdge(subjectEntityID: subject.id))

        pollUntil { store.loadAllEntities().contains { $0.id == subject.id } && store.loadAllEdges().contains { $0.id == edge.id } }

        // A brand new MemoryManager instance against the SAME store must load exactly what
        // the first instance persisted - the same guarantee ChatSessionManager provides when
        // the app relaunches against its existing store.
        let reloadedManager = makeManager(store: store)

        XCTAssertEqual(reloadedManager.entities.count, 1)
        XCTAssertEqual(reloadedManager.entities.first?.id, subject.id)
        XCTAssertEqual(reloadedManager.entities.first?.name, "Sarah")
        XCTAssertEqual(reloadedManager.edges.count, 1)
        XCTAssertEqual(reloadedManager.edges.first?.id, edge.id)
    }

    // MARK: Independence from audio/Gemini components

    /// Uses `Mirror` to enumerate MemoryManager's actual stored properties and asserts none
    /// of their type names mention any of the forbidden components - a real structural check,
    /// not just a comment. This is what actually enforces the architectural requirement that
    /// MemoryManager has no reference to AIEngineController, GeminiLiveClient,
    /// GeminiResponseGenerator, AudioCaptureManager, AudioMixer, or SystemAudioCaptureManager -
    /// if a future change ever added one, this test fails immediately rather than relying on
    /// someone noticing during review.
    func testMemoryManagerHasNoAudioOrGeminiStoredDependencies() {
        let forbidden = [
            "AIEngineController",
            "GeminiLiveClient",
            "GeminiResponseGenerator",
            "AudioCaptureManager",
            "AudioMixer",
            "SystemAudioCaptureManager"
        ]
        let manager = makeManager()
        let mirror = Mirror(reflecting: manager)

        for child in mirror.children {
            let typeName = String(describing: type(of: child.value))
            for name in forbidden {
                XCTAssertFalse(typeName.contains(name), "MemoryManager must not hold a stored property referencing \(name) (found on '\(child.label ?? "?")': \(typeName))")
            }
        }
    }
}
