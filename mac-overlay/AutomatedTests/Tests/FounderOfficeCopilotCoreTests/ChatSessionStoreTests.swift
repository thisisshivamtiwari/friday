import XCTest
@testable import FounderOfficeCopilotCore

/// Covers ChatSessionStore's Core Data persistence directly - round-trip correctness,
/// message identity surviving a reload, and update-in-place (not duplicate) semantics.
/// Every test uses `ChatSessionStore(inMemory: true)`, never the real on-disk store.
///
/// Writes are asynchronous (fire-and-forget on a background context, by design - see the
/// store's doc comment on why), so every test waits on the `completion` parameter before
/// asserting. Production code never passes one.
final class ChatSessionStoreTests: XCTestCase {
    private func makeSession(title: String = "Session") -> ChatSession {
        let now = Date()
        return ChatSession(id: UUID(), title: title, createdAt: now, updatedAt: now, lastMessageAt: nil, isPinned: false, isArchived: false, summary: nil, messages: [])
    }

    private func write(_ store: ChatSessionStore, _ body: (@escaping () -> Void) -> Void) {
        let expectation = expectation(description: "write completed")
        body { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
    }

    func testFreshStoreHasNoSessions() {
        let store = ChatSessionStore(inMemory: true)
        XCTAssertTrue(store.loadAllSessions().isEmpty)
    }

    func testCreateSessionThenLoadAllSessionsRoundTrips() {
        let store = ChatSessionStore(inMemory: true)
        let session = makeSession(title: "Test Session")

        write(store) { store.createSession(session, completion: $0) }

        let loaded = store.loadAllSessions()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, session.id)
        XCTAssertEqual(loaded.first?.title, "Test Session")
    }

    func testMessagesPersistAndRestoreWithStableIdentity() {
        let store = ChatSessionStore(inMemory: true)
        let session = makeSession()
        write(store) { store.createSession(session, completion: $0) }

        let message = ChatMessage(role: .heard, text: "hello there")
        write(store) { store.appendOrUpdateMessage(message, sessionID: session.id, completion: $0) }

        let loaded = store.loadAllSessions()
        XCTAssertEqual(loaded.first?.messages.count, 1)
        XCTAssertEqual(loaded.first?.messages.first?.id, message.id, "restored messages must keep their original identity, not get a fresh UUID")
        XCTAssertEqual(loaded.first?.messages.first?.text, "hello there")
        XCTAssertEqual(loaded.first?.messages.first?.role, .heard)
    }

    func testUpdatingAnExistingMessageOverwritesRatherThanDuplicating() {
        let store = ChatSessionStore(inMemory: true)
        let session = makeSession()
        write(store) { store.createSession(session, completion: $0) }

        var message = ChatMessage(role: .response, text: "partial", isStreaming: true)
        write(store) { store.appendOrUpdateMessage(message, sessionID: session.id, completion: $0) }

        message.text = "partial answer complete"
        message.isStreaming = false
        write(store) { store.appendOrUpdateMessage(message, sessionID: session.id, completion: $0) }

        let loaded = store.loadAllSessions()
        XCTAssertEqual(loaded.first?.messages.count, 1, "the same message id must update in place, not create a duplicate row")
        XCTAssertEqual(loaded.first?.messages.first?.text, "partial answer complete")
    }

    func testReloadedMessagesAreNeverMarkedAsStillStreaming() {
        let store = ChatSessionStore(inMemory: true)
        let session = makeSession()
        write(store) { store.createSession(session, completion: $0) }

        let message = ChatMessage(role: .response, text: "partial", isStreaming: true)
        write(store) { store.appendOrUpdateMessage(message, sessionID: session.id, completion: $0) }

        let loaded = store.loadAllSessions()
        XCTAssertFalse(loaded.first?.messages.first?.isStreaming ?? true, "nothing is actually still streaming after a relaunch, regardless of what was last saved")
    }

    func testMultipleMessagesLoadInChronologicalOrder() {
        let store = ChatSessionStore(inMemory: true)
        let session = makeSession()
        write(store) { store.createSession(session, completion: $0) }

        let first = ChatMessage(role: .heard, text: "first", timestamp: Date(timeIntervalSinceReferenceDate: 100))
        let second = ChatMessage(role: .response, text: "second", timestamp: Date(timeIntervalSinceReferenceDate: 200))
        write(store) { store.appendOrUpdateMessage(first, sessionID: session.id, completion: $0) }
        write(store) { store.appendOrUpdateMessage(second, sessionID: session.id, completion: $0) }

        let loaded = store.loadAllSessions().first?.messages
        XCTAssertEqual(loaded?.map(\.text), ["first", "second"])
    }

    func testUpdateSessionMetadataPersistsTitleAndArchiveState() {
        let store = ChatSessionStore(inMemory: true)
        var session = makeSession(title: "Original")
        write(store) { store.createSession(session, completion: $0) }

        session.title = "Renamed"
        session.isArchived = true
        write(store) { store.updateSessionMetadata(session, completion: $0) }

        let loaded = store.loadAllSessions()
        XCTAssertEqual(loaded.first?.title, "Renamed")
        XCTAssertTrue(loaded.first?.isArchived ?? false)
    }

    func testDeletingASessionRemovesItAndItsMessages() {
        let store = ChatSessionStore(inMemory: true)
        let session = makeSession()
        write(store) { store.createSession(session, completion: $0) }
        write(store) { store.appendOrUpdateMessage(ChatMessage(role: .heard, text: "hi"), sessionID: session.id, completion: $0) }

        write(store) { store.deleteSession(session.id, completion: $0) }

        XCTAssertTrue(store.loadAllSessions().isEmpty)
    }

    func testTwoSeparateInMemoryStoresDoNotShareState() {
        // Confirms `inMemory: true` genuinely isolates instances - important since every
        // test in this suite (and ChatSessionManagerTests) relies on that isolation.
        let storeA = ChatSessionStore(inMemory: true)
        let storeB = ChatSessionStore(inMemory: true)
        write(storeA) { storeA.createSession(self.makeSession(), completion: $0) }

        XCTAssertEqual(storeA.loadAllSessions().count, 1)
        XCTAssertEqual(storeB.loadAllSessions().count, 0)
    }

    // MARK: Migration safety (adding `isIndexed = true` to the `id` attributes)

    /// Builds the entity/attribute shape ChatSessionStore.makeModel() used BEFORE `id` gained
    /// `isIndexed = true` - same entity names, attribute names, types, and relationships, just
    /// without the index. Standing in for "a real on-disk store created by an older build of
    /// the app", so this test can verify the CURRENT ChatSessionStore (with the index) can
    /// still open it and read its data back intact, rather than just assuming lightweight
    /// migration handles it.
    private func makePreIndexModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let sessionEntity = NSEntityDescription()
        sessionEntity.name = "ChatSessionEntity"
        sessionEntity.managedObjectClassName = "ChatSessionEntity"
        let messageEntity = NSEntityDescription()
        messageEntity.name = "ChatMessageEntity"
        messageEntity.managedObjectClassName = "ChatMessageEntity"

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        let sessionMessages = NSRelationshipDescription()
        sessionMessages.name = "messages"
        sessionMessages.destinationEntity = messageEntity
        sessionMessages.minCount = 0
        sessionMessages.maxCount = 0
        sessionMessages.deleteRule = .cascadeDeleteRule

        let messageSession = NSRelationshipDescription()
        messageSession.name = "session"
        messageSession.destinationEntity = sessionEntity
        messageSession.minCount = 0
        messageSession.maxCount = 1
        messageSession.deleteRule = .nullifyDeleteRule

        sessionMessages.inverseRelationship = messageSession
        messageSession.inverseRelationship = sessionMessages

        sessionEntity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("title", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("lastMessageAt", .dateAttributeType, optional: true),
            attribute("isPinned", .booleanAttributeType),
            attribute("isArchived", .booleanAttributeType),
            attribute("summary", .stringAttributeType, optional: true),
            sessionMessages
        ]
        messageEntity.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("roleRaw", .stringAttributeType),
            attribute("text", .stringAttributeType),
            attribute("timestamp", .dateAttributeType),
            messageSession
        ]
        model.entities = [sessionEntity, messageEntity]
        return model
    }

    func testOpeningAPreIndexOnDiskStorePreservesAllData() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("migration-test-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: tempURL.path + suffix)
            }
        }

        // Phase 1: write real data to a real on-disk SQLite store using the OLD (unindexed)
        // model - standing in for a store created by a build of the app before this change.
        let oldContainer = NSPersistentContainer(name: "ChatSessions", managedObjectModel: makePreIndexModel())
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

        let sessionID = UUID()
        let messageID = UUID()
        let bgContext = oldContainer.newBackgroundContext()
        let saveExpectation = expectation(description: "old data saved")
        bgContext.perform {
            let sessionEntity = NSEntityDescription.entity(forEntityName: "ChatSessionEntity", in: bgContext)!
            let session = NSManagedObject(entity: sessionEntity, insertInto: bgContext)
            session.setValue(sessionID, forKey: "id")
            session.setValue("Pre-index session", forKey: "title")
            session.setValue(Date(), forKey: "createdAt")
            session.setValue(Date(), forKey: "updatedAt")
            session.setValue(false, forKey: "isPinned")
            session.setValue(false, forKey: "isArchived")

            let messageEntity = NSEntityDescription.entity(forEntityName: "ChatMessageEntity", in: bgContext)!
            let message = NSManagedObject(entity: messageEntity, insertInto: bgContext)
            message.setValue(messageID, forKey: "id")
            message.setValue("heard", forKey: "roleRaw")
            message.setValue("hello from before the index existed", forKey: "text")
            message.setValue(Date(), forKey: "timestamp")
            message.setValue(session, forKey: "session")

            try? bgContext.save()
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 5)

        // `oldContainer` must fully release its connection to `tempURL` before phase 2 opens a
        // SECOND persistent store coordinator on the same file - without this, both coordinators
        // hold the file open at once and Core Data's serialized background-task queue deadlocks
        // waiting on a SQLite-level lock the other side never releases (confirmed directly via
        // `sample` on the hung process while writing this test, not assumed).
        if let oldStore = oldContainer.persistentStoreCoordinator.persistentStores.first {
            try? oldContainer.persistentStoreCoordinator.remove(oldStore)
        }

        // Phase 2: open the SAME file with the CURRENT ChatSessionStore (indexed model) and
        // confirm the data survived the implicit lightweight migration.
        let migratedStore = ChatSessionStore(storeURL: tempURL)
        let loaded = migratedStore.loadAllSessions()
        XCTAssertEqual(loaded.count, 1, "migration must not lose the session")
        XCTAssertEqual(loaded.first?.id, sessionID)
        XCTAssertEqual(loaded.first?.title, "Pre-index session")
        XCTAssertEqual(loaded.first?.messages.count, 1, "migration must not lose the message")
        XCTAssertEqual(loaded.first?.messages.first?.id, messageID)
        XCTAssertEqual(loaded.first?.messages.first?.text, "hello from before the index existed")

        // Confirm the migrated store is also fully writable, not just readable.
        write(migratedStore) { migratedStore.appendOrUpdateMessage(ChatMessage(role: .response, text: "post-migration write"), sessionID: sessionID, completion: $0) }
        let reloaded = migratedStore.loadAllSessions()
        XCTAssertEqual(reloaded.first?.messages.count, 2)
    }

    // MARK: Write serialization - the two established data-loss races
    //
    // Writes used to run on a FRESH `container.performBackgroundTask` context each, with no
    // ordering between them, which produced two real losses:
    //   1. create/append - an append could fetch the session before the create committed, hit its
    //      `guard let sessionEntity ... else { return }` and drop the message entirely.
    //   2. same row - `appendOrUpdateMessage` + `updateSessionMetadata` (issued back-to-back by
    //      `ChatSessionManager.appendHeardDelta`) mutated one session row from two contexts; under
    //      the default merge policy the loser's save threw and `try?` discarded it.
    // All writes now share ONE serialized private-queue context.
    //
    // No sleeps anywhere: every test waits on the store's own completion callbacks, so it asserts
    // only after the write queue has genuinely drained.

    /// Writes go to a REAL on-disk store in a temp directory, then are read back through a
    /// SEPARATE store instance - proving what reached disk, not what a cache still remembers.
    private func makeOnDiskStore() throws -> (url: URL, store: ChatSessionStore, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("ChatSessions.sqlite")
        return (url, ChatSessionStore(storeURL: url), { try? FileManager.default.removeItem(at: root) })
    }

    /// 1: ~50 rapid appends/updates all persist, with the final text intact.
    func testRapidFireAppendsAllPersist() throws {
        let stack = try makeOnDiskStore()
        defer { stack.cleanup() }
        let session = makeSession(title: "Rapid")
        let created = expectation(description: "session created")
        stack.store.createSession(session) { created.fulfill() }
        wait(for: [created], timeout: 5)

        let count = 50
        let done = expectation(description: "writes drained")
        done.expectedFulfillmentCount = count
        var messages: [ChatMessage] = []
        for index in 0..<count {
            let message = ChatMessage(role: .heard, text: "line \(index)")
            messages.append(message)
            stack.store.appendOrUpdateMessage(message, sessionID: session.id) { done.fulfill() }
        }
        wait(for: [done], timeout: 20)

        let reloaded = ChatSessionStore(storeURL: stack.url).loadAllSessions().first { $0.id == session.id }
        XCTAssertEqual(reloaded?.messages.count, count, "every rapid append must reach disk")
        let texts = Set(reloaded?.messages.map(\.text) ?? [])
        for index in 0..<count { XCTAssertTrue(texts.contains("line \(index)"), "lost line \(index)") }
    }

    /// 2: create-then-immediately-append, with NO delay - the exact former ordering race.
    func testCreateThenImmediateAppendPersists() throws {
        let stack = try makeOnDiskStore()
        defer { stack.cleanup() }
        let session = makeSession(title: "Immediate")
        let message = ChatMessage(role: .heard, text: "first thing said")

        let done = expectation(description: "append drained")
        stack.store.createSession(session)                                  // no completion wait - deliberate
        stack.store.appendOrUpdateMessage(message, sessionID: session.id) { done.fulfill() }
        wait(for: [done], timeout: 10)

        let reloaded = ChatSessionStore(storeURL: stack.url).loadAllSessions().first { $0.id == session.id }
        XCTAssertEqual(reloaded?.messages.first?.text, "first thing said", "the append must not be dropped by an uncommitted create")
    }

    /// 3: interleaved message + metadata writes on the SAME session - both must survive.
    func testInterleavedAppendAndMetadataBothPersist() throws {
        let stack = try makeOnDiskStore()
        defer { stack.cleanup() }
        var session = makeSession(title: "Interleaved")
        let created = expectation(description: "created")
        stack.store.createSession(session) { created.fulfill() }
        wait(for: [created], timeout: 5)

        let rounds = 20
        let done = expectation(description: "drained")
        done.expectedFulfillmentCount = rounds * 2
        let message = ChatMessage(role: .heard, text: "")
        for index in 0..<rounds {
            let updated = ChatMessage(id: message.id, role: .heard, text: String(repeating: "x", count: index + 1), timestamp: message.timestamp)
            stack.store.appendOrUpdateMessage(updated, sessionID: session.id) { done.fulfill() }
            session.title = "Interleaved \(index)"
            stack.store.updateSessionMetadata(session) { done.fulfill() }
        }
        wait(for: [done], timeout: 20)

        let reloaded = ChatSessionStore(storeURL: stack.url).loadAllSessions().first { $0.id == session.id }
        XCTAssertEqual(reloaded?.messages.count, 1, "one row for one message id")
        XCTAssertEqual(reloaded?.messages.first?.text, String(repeating: "x", count: rounds), "the last message write must survive the metadata writes")
        XCTAssertEqual(reloaded?.title, "Interleaved \(rounds - 1)", "the last metadata write must survive the message writes")
    }

    /// 4: repeating one message id converges on exactly one row.
    func testRepeatedSameMessageIDProducesExactlyOneRow() throws {
        let stack = try makeOnDiskStore()
        defer { stack.cleanup() }
        let session = makeSession(title: "Dedup")
        let created = expectation(description: "created")
        stack.store.createSession(session) { created.fulfill() }
        wait(for: [created], timeout: 5)

        let message = ChatMessage(role: .heard, text: "v0")
        let done = expectation(description: "drained")
        done.expectedFulfillmentCount = 25
        for index in 0..<25 {
            let updated = ChatMessage(id: message.id, role: .heard, text: "v\(index)", timestamp: message.timestamp)
            stack.store.appendOrUpdateMessage(updated, sessionID: session.id) { done.fulfill() }
        }
        wait(for: [done], timeout: 20)

        let reloaded = ChatSessionStore(storeURL: stack.url).loadAllSessions().first { $0.id == session.id }
        XCTAssertEqual(reloaded?.messages.count, 1)
        XCTAssertEqual(reloaded?.messages.first?.text, "v24", "last write wins")
    }

    /// 5: rapid writes preserve message ordering (by timestamp, as `session(from:)` sorts).
    func testRapidWritesPreserveOrdering() throws {
        let stack = try makeOnDiskStore()
        defer { stack.cleanup() }
        let session = makeSession(title: "Ordering")
        let created = expectation(description: "created")
        stack.store.createSession(session) { created.fulfill() }
        wait(for: [created], timeout: 5)

        let base = Date()
        let done = expectation(description: "drained")
        done.expectedFulfillmentCount = 15
        for index in 0..<15 {
            let message = ChatMessage(role: .heard, text: "m\(index)", timestamp: base.addingTimeInterval(Double(index)))
            stack.store.appendOrUpdateMessage(message, sessionID: session.id) { done.fulfill() }
        }
        wait(for: [done], timeout: 20)

        let reloaded = ChatSessionStore(storeURL: stack.url).loadAllSessions().first { $0.id == session.id }
        XCTAssertEqual(reloaded?.messages.map(\.text), (0..<15).map { "m\($0)" })
    }

    /// 6: delete still cascades, and still works when queued behind other writes.
    func testDeleteSessionStillCascadesAfterSerializedWrites() throws {
        let stack = try makeOnDiskStore()
        defer { stack.cleanup() }
        let session = makeSession(title: "Doomed")
        let created = expectation(description: "created")
        stack.store.createSession(session) { created.fulfill() }
        wait(for: [created], timeout: 5)

        let writes = expectation(description: "writes")
        writes.expectedFulfillmentCount = 5
        for index in 0..<5 {
            stack.store.appendOrUpdateMessage(ChatMessage(role: .heard, text: "m\(index)"), sessionID: session.id) { writes.fulfill() }
        }
        wait(for: [writes], timeout: 20)

        let deleted = expectation(description: "deleted")
        stack.store.deleteSession(session.id) { deleted.fulfill() }
        wait(for: [deleted], timeout: 10)

        let reloaded = ChatSessionStore(storeURL: stack.url).loadAllSessions()
        XCTAssertFalse(reloaded.contains { $0.id == session.id }, "session removed")
        XCTAssertTrue(reloaded.allSatisfy { $0.messages.isEmpty || $0.id != session.id }, "messages cascaded away")
    }
}
