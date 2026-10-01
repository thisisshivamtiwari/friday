import XCTest
import CoreData
@testable import FounderOfficeCopilotCore

/// Covers MemoryStore's Core Data persistence directly - round-trip correctness, identity
/// preservation, update-in-place semantics, migration safety, and the architectural
/// requirement that this store has ZERO Core Data relationships anywhere in its model
/// (neither within itself nor to ChatSessionStore's model). Every test uses
/// `MemoryStore(inMemory: true)` unless specifically testing on-disk/migration behavior, in
/// which case a temp file is used - never the real app's saved memory.
///
/// Writes are asynchronous (fire-and-forget on a background context, by design - see
/// MemoryStore's own doc comment), so every test waits on the `completion` parameter before
/// asserting. Production code never passes one.
final class MemoryStoreTests: XCTestCase {
    private func makeMemoryEntity(name: String = "Sarah", kind: MemoryEntity.Kind = .person) -> MemoryEntity {
        MemoryEntity(kind: kind, name: name)
    }

    private func makeMemoryEdge(subjectEntityID: UUID = UUID(), predicate: String = "prefers") -> MemoryEdge {
        MemoryEdge(subjectEntityID: subjectEntityID, predicate: predicate, category: .preference, confidence: 0.6, sourceSessionID: UUID())
    }

    private func write(_ store: MemoryStore, _ body: (@escaping () -> Void) -> Void) {
        let expectation = expectation(description: "write completed")
        body { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: Entities - round trip

    func testFreshStoreHasNoEntitiesOrEdges() {
        let store = MemoryStore(inMemory: true)
        XCTAssertTrue(store.loadAllEntities().isEmpty)
        XCTAssertTrue(store.loadAllEdges().isEmpty)
    }

    func testCreateEntityThenLoadAllEntitiesRoundTrips() {
        let store = MemoryStore(inMemory: true)
        let entity = makeMemoryEntity(name: "Sarah", kind: .person)

        write(store) { store.createEntity(entity, completion: $0) }

        let loaded = store.loadAllEntities()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, entity.id)
        XCTAssertEqual(loaded.first?.name, "Sarah")
        XCTAssertEqual(loaded.first?.kind, .person)
    }

    func testEntityAliasesAndNotesRoundTrip() {
        let store = MemoryStore(inMemory: true)
        let entity = MemoryEntity(kind: .organization, name: "Acme Corp", aliases: ["Acme", "Acme Inc"], notes: "met at a conference", isUserVerified: true, mentionCount: 4)

        write(store) { store.createEntity(entity, completion: $0) }

        let loaded = store.loadAllEntities().first
        XCTAssertEqual(loaded?.aliases, ["Acme", "Acme Inc"])
        XCTAssertEqual(loaded?.notes, "met at a conference")
        XCTAssertTrue(loaded?.isUserVerified ?? false)
        XCTAssertEqual(loaded?.mentionCount, 4)
    }

    func testUpdateEntityOverwritesRatherThanDuplicating() {
        let store = MemoryStore(inMemory: true)
        var entity = makeMemoryEntity(name: "Sarah")
        write(store) { store.createEntity(entity, completion: $0) }

        entity.name = "Sarah Chen"
        entity.mentionCount = 2
        write(store) { store.updateEntity(entity, completion: $0) }

        let loaded = store.loadAllEntities()
        XCTAssertEqual(loaded.count, 1, "the same entity id must update in place, not create a duplicate row")
        XCTAssertEqual(loaded.first?.name, "Sarah Chen")
        XCTAssertEqual(loaded.first?.mentionCount, 2)
    }

    func testUpdateEntityWithUnknownIDIsHarmlessNoOp() {
        let store = MemoryStore(inMemory: true)
        let neverCreated = makeMemoryEntity()
        write(store) { store.updateEntity(neverCreated, completion: $0) }
        XCTAssertTrue(store.loadAllEntities().isEmpty)
    }

    func testDeleteEntityRemovesIt() {
        let store = MemoryStore(inMemory: true)
        let entity = makeMemoryEntity()
        write(store) { store.createEntity(entity, completion: $0) }

        write(store) { store.deleteEntity(id: entity.id, completion: $0) }

        XCTAssertTrue(store.loadAllEntities().isEmpty)
    }

    // MARK: Edges - round trip

    func testCreateEdgeThenLoadAllEdgesRoundTrips() {
        let store = MemoryStore(inMemory: true)
        let subject = UUID()
        let object = UUID()
        let session = UUID()
        let message = UUID()
        let edge = MemoryEdge(subjectEntityID: subject, predicate: "prefers", objectEntityID: object, category: .preference, confidence: 0.75, sourceSessionID: session, sourceMessageIDs: [message], isExplicit: true, isPinned: true)

        write(store) { store.createEdge(edge, completion: $0) }

        let loaded = store.loadAllEdges()
        XCTAssertEqual(loaded.count, 1)
        let restored = loaded.first
        XCTAssertEqual(restored?.id, edge.id)
        XCTAssertEqual(restored?.subjectEntityID, subject)
        XCTAssertEqual(restored?.predicate, "prefers")
        XCTAssertEqual(restored?.objectEntityID, object)
        XCTAssertEqual(restored?.category, .preference)
        XCTAssertEqual(restored?.confidence, 0.75)
        XCTAssertEqual(restored?.status, .active)
        XCTAssertEqual(restored?.sourceSessionID, session)
        XCTAssertEqual(restored?.sourceMessageIDs, [message])
        XCTAssertTrue(restored?.isExplicit ?? false)
        XCTAssertTrue(restored?.isPinned ?? false)
    }

    func testEdgeWithLiteralValueAndNoObjectRoundTrips() {
        let store = MemoryStore(inMemory: true)
        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "goal-is", literalValue: "ship Friday by October", category: .goal, confidence: 0.5, sourceSessionID: UUID())

        write(store) { store.createEdge(edge, completion: $0) }

        let loaded = store.loadAllEdges().first
        XCTAssertNil(loaded?.objectEntityID)
        XCTAssertEqual(loaded?.literalValue, "ship Friday by October")
    }

    func testSupersessionLinksRoundTrip() {
        let store = MemoryStore(inMemory: true)
        let oldEdge = makeMemoryEdge()
        write(store) { store.createEdge(oldEdge, completion: $0) }

        var newEdge = makeMemoryEdge()
        newEdge.supersedes = oldEdge.id
        write(store) { store.createEdge(newEdge, completion: $0) }

        var updatedOld = oldEdge
        updatedOld.status = .superseded
        updatedOld.supersededBy = newEdge.id
        write(store) { store.updateEdge(updatedOld, completion: $0) }

        let loaded = store.loadAllEdges()
        let oldLoaded = loaded.first { $0.id == oldEdge.id }
        let newLoaded = loaded.first { $0.id == newEdge.id }
        XCTAssertEqual(oldLoaded?.status, .superseded)
        XCTAssertEqual(oldLoaded?.supersededBy, newEdge.id)
        XCTAssertEqual(newLoaded?.supersedes, oldEdge.id)
        XCTAssertEqual(loaded.count, 2, "superseding must never delete the old edge")
    }

    func testUpdateEdgeOverwritesRatherThanDuplicating() {
        let store = MemoryStore(inMemory: true)
        var edge = makeMemoryEdge()
        write(store) { store.createEdge(edge, completion: $0) }

        edge.confidence = 0.9
        edge.confirmationCount = 3
        write(store) { store.updateEdge(edge, completion: $0) }

        let loaded = store.loadAllEdges()
        XCTAssertEqual(loaded.count, 1, "the same edge id must update in place, not create a duplicate row")
        XCTAssertEqual(loaded.first?.confidence, 0.9)
        XCTAssertEqual(loaded.first?.confirmationCount, 3)
    }

    func testDeleteEdgeRemovesIt() {
        let store = MemoryStore(inMemory: true)
        let edge = makeMemoryEdge()
        write(store) { store.createEdge(edge, completion: $0) }

        write(store) { store.deleteEdge(id: edge.id, completion: $0) }

        XCTAssertTrue(store.loadAllEdges().isEmpty)
    }

    // MARK: In-memory store isolation

    func testTwoSeparateInMemoryStoresDoNotShareState() {
        let storeA = MemoryStore(inMemory: true)
        let storeB = MemoryStore(inMemory: true)
        write(storeA) { storeA.createEntity(self.makeMemoryEntity(), completion: $0) }

        XCTAssertEqual(storeA.loadAllEntities().count, 1)
        XCTAssertEqual(storeB.loadAllEntities().count, 0)
    }

    // MARK: Zero Core Data relationships

    /// Structural proof, not just convention: MemoryStore's own model must contain ZERO
    /// NSRelationshipDescriptions anywhere - not between MemoryEntityRecord and
    /// MemoryEdgeRecord, and certainly not to anything else. subjectEntityID/objectEntityID/
    /// sourceSessionID/sourceMessageIDsData are all plain UUID/Data attributes.
    func testMemoryModelHasZeroCoreDataRelationships() {
        let model = MemoryStore.makeModel()
        XCTAssertEqual(model.entities.count, 2, "expected exactly MemoryEntityRecord and MemoryEdgeRecord")

        for entity in model.entities {
            let relationships = entity.properties.compactMap { $0 as? NSRelationshipDescription }
            XCTAssertTrue(relationships.isEmpty, "\(entity.name ?? "?") must have zero Core Data relationships, found: \(relationships.map { $0.name })")
        }
    }

    func testMemoryModelDoesNotReuseChatSessionEntityNames() {
        let model = MemoryStore.makeModel()
        let chatEntityNames: Set<String> = ["ChatSessionEntity", "ChatMessageEntity"]
        let memoryEntityNames = Set(model.entities.compactMap { $0.name })
        XCTAssertTrue(memoryEntityNames.isDisjoint(with: chatEntityNames), "the memory model must not collide with ChatSessionStore's entity names")
    }

    /// Behavioral proof that the two stores are genuinely independent, not just structurally
    /// relationship-free: deleting a ChatSession that a MemoryEdge's sourceSessionID points at
    /// must have ZERO effect on that MemoryEdge - no cascade, no nullification, nothing. If a
    /// Core Data relationship existed between the two stores (it can't, since they're
    /// different NSManagedObjectModels/NSPersistentContainers entirely, but this proves the
    /// OBSERVABLE guarantee that actually matters), this is exactly the behavior that would
    /// break.
    func testDeletingAChatSessionDoesNotAffectAMemoryEdgeThatReferencesIt() {
        let chatStore = ChatSessionStore(inMemory: true)
        let memoryStore = MemoryStore(inMemory: true)

        let session = ChatSession(id: UUID(), title: "Test", createdAt: Date(), updatedAt: Date(), lastMessageAt: nil, isPinned: false, isArchived: false, summary: nil, messages: [])
        let chatExpectation = expectation(description: "chat session created")
        chatStore.createSession(session) { chatExpectation.fulfill() }
        wait(for: [chatExpectation], timeout: 2.0)

        let edge = MemoryEdge(subjectEntityID: UUID(), predicate: "prefers", category: .preference, confidence: 0.6, sourceSessionID: session.id)
        write(memoryStore) { memoryStore.createEdge(edge, completion: $0) }

        let deleteExpectation = expectation(description: "chat session deleted")
        chatStore.deleteSession(session.id) { deleteExpectation.fulfill() }
        wait(for: [deleteExpectation], timeout: 2.0)

        XCTAssertTrue(chatStore.loadAllSessions().isEmpty, "sanity check: the chat session really was deleted")
        let stillThere = memoryStore.loadAllEdges().first { $0.id == edge.id }
        XCTAssertNotNil(stillThere, "the memory edge must be completely unaffected by the source conversation being deleted")
        XCTAssertEqual(stillThere?.sourceSessionID, session.id, "the now-dangling reference is left as-is, not nullified - resolving it gracefully is a later phase's responsibility, not this store's")
    }

    // MARK: Migration safety

    /// Mirrors ChatSessionStoreTests.testOpeningAPreIndexOnDiskStorePreservesAllData's
    /// approach exactly: builds the entity/attribute shape MemoryStore.makeModel() would have
    /// WITHOUT its indexes, writes real data to a real on-disk SQLite file with that model,
    /// then opens the SAME file with the current (indexed) MemoryStore and confirms the data
    /// survives - proving the migration is safe rather than assuming it.
    private func makePreIndexModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entityRecord = NSEntityDescription()
        entityRecord.name = "MemoryEntityRecord"
        entityRecord.managedObjectClassName = "MemoryEntityRecord"
        let edgeRecord = NSEntityDescription()
        edgeRecord.name = "MemoryEdgeRecord"
        edgeRecord.managedObjectClassName = "MemoryEdgeRecord"

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        entityRecord.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("kindRaw", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("aliasesData", .binaryDataAttributeType),
            attribute("notes", .stringAttributeType, optional: true),
            attribute("isUserVerified", .booleanAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("lastMentionedAt", .dateAttributeType),
            attribute("mentionCount", .integer64AttributeType)
        ]
        edgeRecord.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("subjectEntityID", .UUIDAttributeType),
            attribute("predicate", .stringAttributeType),
            attribute("objectEntityID", .UUIDAttributeType, optional: true),
            attribute("literalValue", .stringAttributeType, optional: true),
            attribute("categoryRaw", .stringAttributeType),
            attribute("confidence", .floatAttributeType),
            attribute("statusRaw", .stringAttributeType),
            attribute("sourceSessionID", .UUIDAttributeType),
            attribute("sourceMessageIDsData", .binaryDataAttributeType),
            attribute("firstObservedAt", .dateAttributeType),
            attribute("lastConfirmedAt", .dateAttributeType),
            attribute("confirmationCount", .integer64AttributeType),
            attribute("supersedes", .UUIDAttributeType, optional: true),
            attribute("supersededBy", .UUIDAttributeType, optional: true),
            attribute("isExplicit", .booleanAttributeType),
            attribute("isPinned", .booleanAttributeType)
        ]
        model.entities = [entityRecord, edgeRecord]
        return model
    }

    func testOpeningAPreIndexOnDiskStorePreservesAllData() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("memory-migration-test-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: tempURL.path + suffix)
            }
        }

        // Phase 1: write real data to a real on-disk SQLite store using the OLD (unindexed)
        // model.
        let oldContainer = NSPersistentContainer(name: "FriendlyMemory", managedObjectModel: makePreIndexModel())
        let oldDescription = NSPersistentStoreDescription()
        oldDescription.type = NSSQLiteStoreType
        oldDescription.url = tempURL
        oldContainer.persistentStoreDescriptions = [oldDescription]
        let loadExpectation = expectation(description: "old store loaded")
        oldContainer.loadPersistentStores { _, error in
            XCTAssertNil(error)
            loadExpectation.fulfill()
        }
        wait(for: [loadExpectation], timeout: 5)

        let entityID = UUID()
        let edgeID = UUID()
        let bgContext = oldContainer.newBackgroundContext()
        let saveExpectation = expectation(description: "old data saved")
        bgContext.perform {
            let entityDesc = NSEntityDescription.entity(forEntityName: "MemoryEntityRecord", in: bgContext)!
            let entityRecord = NSManagedObject(entity: entityDesc, insertInto: bgContext)
            entityRecord.setValue(entityID, forKey: "id")
            entityRecord.setValue("person", forKey: "kindRaw")
            entityRecord.setValue("Pre-index Person", forKey: "name")
            entityRecord.setValue((try? JSONEncoder().encode([String]())) ?? Data(), forKey: "aliasesData")
            entityRecord.setValue(false, forKey: "isUserVerified")
            entityRecord.setValue(Date(), forKey: "createdAt")
            entityRecord.setValue(Date(), forKey: "lastMentionedAt")
            entityRecord.setValue(Int64(1), forKey: "mentionCount")

            let edgeDesc = NSEntityDescription.entity(forEntityName: "MemoryEdgeRecord", in: bgContext)!
            let edgeRecord = NSManagedObject(entity: edgeDesc, insertInto: bgContext)
            edgeRecord.setValue(edgeID, forKey: "id")
            edgeRecord.setValue(entityID, forKey: "subjectEntityID")
            edgeRecord.setValue("prefers", forKey: "predicate")
            edgeRecord.setValue("preference", forKey: "categoryRaw")
            edgeRecord.setValue(Float(0.5), forKey: "confidence")
            edgeRecord.setValue("active", forKey: "statusRaw")
            edgeRecord.setValue(UUID(), forKey: "sourceSessionID")
            edgeRecord.setValue((try? JSONEncoder().encode([UUID]())) ?? Data(), forKey: "sourceMessageIDsData")
            edgeRecord.setValue(Date(), forKey: "firstObservedAt")
            edgeRecord.setValue(Date(), forKey: "lastConfirmedAt")
            edgeRecord.setValue(Int64(1), forKey: "confirmationCount")
            edgeRecord.setValue(false, forKey: "isExplicit")
            edgeRecord.setValue(false, forKey: "isPinned")

            try? bgContext.save()
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 5)

        // Release the old container's connection before opening a second coordinator on the
        // same file - see ChatSessionStoreTests' identical fix for why this matters (two
        // coordinators holding one SQLite file open at once deadlocks Core Data's serialized
        // background-task queue, confirmed directly via `sample` while diagnosing that exact
        // issue earlier in this project).
        if let oldStore = oldContainer.persistentStoreCoordinator.persistentStores.first {
            try? oldContainer.persistentStoreCoordinator.remove(oldStore)
        }

        // Phase 2: open the SAME file with the CURRENT MemoryStore (indexed model) and confirm
        // the data survived the implicit lightweight migration.
        let migratedStore = MemoryStore(storeURL: tempURL)
        let loadedEntities = migratedStore.loadAllEntities()
        let loadedEdges = migratedStore.loadAllEdges()

        XCTAssertEqual(loadedEntities.count, 1, "migration must not lose the entity")
        XCTAssertEqual(loadedEntities.first?.id, entityID)
        XCTAssertEqual(loadedEntities.first?.name, "Pre-index Person")

        XCTAssertEqual(loadedEdges.count, 1, "migration must not lose the edge")
        XCTAssertEqual(loadedEdges.first?.id, edgeID)
        XCTAssertEqual(loadedEdges.first?.subjectEntityID, entityID)

        // Confirm the migrated store is also fully writable, not just readable.
        write(migratedStore) { migratedStore.createEntity(self.makeMemoryEntity(name: "post-migration"), completion: $0) }
        XCTAssertEqual(migratedStore.loadAllEntities().count, 2)
    }
}
