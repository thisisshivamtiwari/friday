import Foundation
import CoreData

// MARK: - Managed object subclasses
// In-code model (no .xcdatamodeld bundle) - same reasoning as everywhere else new resource
// types get avoided in this project: the hand-maintained project.pbxproj has an established,
// working pattern for registering plain Swift source files, but no template for a compiled
// Core Data resource, so this sidesteps needing to invent one. @objc(...) pins the runtime
// class name so it matches NSEntityDescription.managedObjectClassName exactly, regardless of
// Swift module-name mangling.
@objc(ChatSessionEntity)
final class ChatSessionEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var lastMessageAt: Date?
    @NSManaged var isPinned: Bool
    @NSManaged var isArchived: Bool
    @NSManaged var summary: String?
    @NSManaged var messages: NSSet?
}

@objc(ChatMessageEntity)
final class ChatMessageEntity: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var roleRaw: String
    @NSManaged var text: String
    @NSManaged var timestamp: Date
    @NSManaged var session: ChatSessionEntity?
}

// MARK: - Chat Session Store
/// Local-first Core Data persistence for chat sessions and their messages - the only
/// persistence in the app besides SettingsStore's UserDefaults/Keychain use. Deliberately NOT
/// used for anything beyond "what was said" - the future memory graph is a completely
/// separate store, cross-referenced only by plain UUIDs, never a Core Data relationship, so
/// "chat history" and "derived knowledge" never become entangled at the data layer.
///
/// All writes go through ONE dedicated private-queue context (`writeContext`), never the
/// main-thread `viewContext` - ChatSessionManager already holds the authoritative in-memory state and
/// updates it synchronously, so persistence here is a fire-and-forget mirror, never something
/// the UI has to wait on. (The `completion` parameter on each write exists solely so tests can
/// deterministically wait for a write to land before asserting - production call sites never
/// pass one.)
final class ChatSessionStore {
    private let container: NSPersistentContainer
    /// THE single serialized write path. Every mutation runs through this one private-queue
    /// context, which Core Data guarantees executes its `perform` blocks FIFO on its own queue.
    ///
    /// It used to be one fresh `container.performBackgroundTask` context PER WRITE, which gave
    /// no ordering between writes and produced two real, observed data-loss races:
    ///
    /// 1. CREATE/APPEND: `createSession` and `appendOrUpdateMessage` ran concurrently, so the
    ///    append could fetch the session before the create committed, hit its `guard let
    ///    sessionEntity ... else { return }`, and drop the message entirely. Observed live: a
    ///    populated meeting transcript missing from disk while extraction saw all of it.
    /// 2. SAME ROW: `appendOrUpdateMessage` and `updateSessionMetadata` (issued back-to-back by
    ///    `ChatSessionManager.appendHeardDelta`) mutated the same session row from two contexts;
    ///    under the default `NSErrorMergePolicy` the loser's `save()` threw and `try?` discarded
    ///    it. Observed live: transcripts persisted at 44% and 86% of their real length.
    ///
    /// Serializing fixes both by construction: creates precede appends, and no two writes touch
    /// the same row at once. The merge policy below is defence-in-depth, not the mechanism.
    private let writeContext: NSManagedObjectContext

    /// `inMemory: true` is the test seam - same purpose as AIEngineController's
    /// `apiKeyProvider` override: keeps automated tests from ever touching the real app's
    /// on-disk session history. `storeURL` is a second, narrower test seam: it lets a test
    /// point a REAL on-disk SQLite store at a temp file (e.g. to verify migration behavior
    /// against actual SQLite, not just the in-memory store type) without ever touching the
    /// real app's store - ignored when `inMemory` is true. Production call sites pass neither.
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "ChatSessions", managedObjectModel: model)

        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            description.type = NSSQLiteStoreType
            description.url = storeURL ?? Self.storeURL()
        }
        // Explicit rather than relying on the (also-true) framework defaults: an index-only
        // attribute change like `id`'s below is a lightweight-migration-eligible change (it
        // doesn't alter the entity's shape, just adds a SQLite index), so this is what lets an
        // existing on-disk store opened with an updated model migrate in place instead of
        // failing to load - verified directly, not just asserted, by
        // ChatSessionStoreTests.testOpeningAPreIndexOnDiskStorePreservesAllData.
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error {
                print("[ChatSessionStore] Failed to load persistent store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true

        writeContext = container.newBackgroundContext()
        // Defence-in-depth only - serialization already prevents the conflicts this would
        // resolve. Kept so a future concurrent writer degrades to "last property wins" rather
        // than to a thrown, silently discarded save.
        writeContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("FounderOfficeCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ChatSessions.sqlite")
    }

    // MARK: Model

    private static func makeModel() -> NSManagedObjectModel {
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

        /// A single-attribute index on `attribute` - `NSFetchIndexDescription`/
        /// `NSFetchIndexElementDescription` rather than the older `NSAttributeDescription.
        /// isIndexed` (deprecated since macOS 10.13). `fetchSessionEntity(id:)`/
        /// `fetchMessageEntity(id:)` below both filter on `id` on every write, and without an
        /// index that's an unindexed scan of every row of that entity ever persisted, not just
        /// the current session's messages - this is what fixes that. An index-only change like
        /// this is lightweight-migration-eligible (see `init`'s `shouldMigrateStoreAutomatically`),
        /// verified directly by ChatSessionStoreTests.testOpeningAPreIndexOnDiskStorePreservesAllData.
        func idIndex(_ attribute: NSAttributeDescription, on entity: NSEntityDescription) -> NSFetchIndexDescription {
            NSFetchIndexDescription(name: "\(entity.name ?? "entity")_id_index", elements: [
                NSFetchIndexElementDescription(property: attribute, collationType: .binary)
            ])
        }

        let sessionMessages = NSRelationshipDescription()
        sessionMessages.name = "messages"
        sessionMessages.destinationEntity = messageEntity
        sessionMessages.minCount = 0
        sessionMessages.maxCount = 0 // to-many
        sessionMessages.deleteRule = .cascadeDeleteRule

        let messageSession = NSRelationshipDescription()
        messageSession.name = "session"
        messageSession.destinationEntity = sessionEntity
        messageSession.minCount = 0
        messageSession.maxCount = 1
        messageSession.deleteRule = .nullifyDeleteRule

        sessionMessages.inverseRelationship = messageSession
        messageSession.inverseRelationship = sessionMessages

        let sessionIDAttribute = attribute("id", .UUIDAttributeType)
        sessionEntity.properties = [
            sessionIDAttribute,
            attribute("title", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("lastMessageAt", .dateAttributeType, optional: true),
            attribute("isPinned", .booleanAttributeType),
            attribute("isArchived", .booleanAttributeType),
            attribute("summary", .stringAttributeType, optional: true),
            sessionMessages
        ]
        sessionEntity.indexes = [idIndex(sessionIDAttribute, on: sessionEntity)]

        let messageIDAttribute = attribute("id", .UUIDAttributeType)
        messageEntity.properties = [
            messageIDAttribute,
            attribute("roleRaw", .stringAttributeType),
            attribute("text", .stringAttributeType),
            attribute("timestamp", .dateAttributeType),
            messageSession
        ]
        messageEntity.indexes = [idIndex(messageIDAttribute, on: messageEntity)]

        model.entities = [sessionEntity, messageEntity]
        return model
    }

    // MARK: Reads - startup only, small, synchronous (same convention as SettingsStore's
    // synchronous Keychain reads: infrequent, not worth an async/caching layer)

    func loadAllSessions() -> [ChatSession] {
        let request = NSFetchRequest<ChatSessionEntity>(entityName: "ChatSessionEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: true)]
        guard let entities = try? container.viewContext.fetch(request) else { return [] }
        return entities.map(Self.session(from:))
    }

    private static func session(from entity: ChatSessionEntity) -> ChatSession {
        let messageEntities = (entity.messages as? Set<ChatMessageEntity>) ?? []
        let messages = messageEntities
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                // isStreaming is deliberately never persisted (see appendOrUpdateMessage) -
                // nothing is actually still streaming after a relaunch, so it always
                // reconstructs as false regardless of what was true when last saved.
                ChatMessage(id: $0.id, role: $0.roleRaw == "response" ? .response : .heard, text: $0.text, timestamp: $0.timestamp)
            }
        return ChatSession(
            id: entity.id,
            title: entity.title,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            lastMessageAt: entity.lastMessageAt,
            isPinned: entity.isPinned,
            isArchived: entity.isArchived,
            summary: entity.summary,
            messages: messages
        )
    }

    // MARK: Writes - all async, background context

    func createSession(_ session: ChatSession, completion: (() -> Void)? = nil) {
        writeContext.perform { [writeContext] in
            let entity = ChatSessionEntity(entity: writeContext.entityDescription("ChatSessionEntity"), insertInto: writeContext)
            Self.apply(session, to: entity)
            Self.save(writeContext, operation: "createSession", sessionID: session.id)
            completion?()
        }
    }

    func updateSessionMetadata(_ session: ChatSession, completion: (() -> Void)? = nil) {
        writeContext.perform { [writeContext] in
            guard let entity = Self.fetchSessionEntity(id: session.id, in: writeContext) else {
                completion?()
                return
            }
            Self.apply(session, to: entity)
            Self.save(writeContext, operation: "updateSessionMetadata", sessionID: session.id)
            completion?()
        }
    }

    /// Creates or updates (by message id) - a delta append and a "mark complete" both go
    /// through this, always converging on one row per message id, never duplicating.
    func appendOrUpdateMessage(_ message: ChatMessage, sessionID: UUID, completion: (() -> Void)? = nil) {
        writeContext.perform { [writeContext] in
            guard let sessionEntity = Self.fetchSessionEntity(id: sessionID, in: writeContext) else {
                // Now only reachable for a session that genuinely does not exist - a create
                // issued before this call has already run, because both go through this same
                // serialized queue in order.
                print("[ChatSessionStore] appendOrUpdateMessage skipped - no session \(sessionID) (message \(message.id))")
                completion?()
                return
            }
            let entity = Self.fetchMessageEntity(id: message.id, in: writeContext)
                ?? ChatMessageEntity(entity: writeContext.entityDescription("ChatMessageEntity"), insertInto: writeContext)
            entity.id = message.id
            entity.roleRaw = message.role == .response ? "response" : "heard"
            entity.text = message.text
            entity.timestamp = message.timestamp
            entity.session = sessionEntity
            Self.save(writeContext, operation: "appendOrUpdateMessage", sessionID: sessionID, messageID: message.id)
            completion?()
        }
    }

    func deleteSession(_ sessionID: UUID, completion: (() -> Void)? = nil) {
        writeContext.perform { [writeContext] in
            guard let entity = Self.fetchSessionEntity(id: sessionID, in: writeContext) else {
                completion?()
                return
            }
            writeContext.delete(entity) // cascades to its messages
            Self.save(writeContext, operation: "deleteSession", sessionID: sessionID)
            completion?()
        }
    }

    /// A persistence failure used to vanish into `try?`. Losing a transcript silently is the
    /// worst possible outcome here, so a failed save now names the operation and the ids
    /// involved. The in-memory state in ChatSessionManager remains authoritative either way, so
    /// there is nothing to roll back - this is a mirror, and a broken mirror should be loud.
    private static func save(_ context: NSManagedObjectContext, operation: String, sessionID: UUID, messageID: UUID? = nil) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            let message = messageID.map { ", message \($0)" } ?? ""
            print("[ChatSessionStore] \(operation) FAILED to save (session \(sessionID)\(message)): \(error)")
        }
    }

    private static func apply(_ session: ChatSession, to entity: ChatSessionEntity) {
        entity.id = session.id
        entity.title = session.title
        entity.createdAt = session.createdAt
        entity.updatedAt = session.updatedAt
        entity.lastMessageAt = session.lastMessageAt
        entity.isPinned = session.isPinned
        entity.isArchived = session.isArchived
        entity.summary = session.summary
    }

    private static func fetchSessionEntity(id: UUID, in context: NSManagedObjectContext) -> ChatSessionEntity? {
        let request = NSFetchRequest<ChatSessionEntity>(entityName: "ChatSessionEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func fetchMessageEntity(id: UUID, in context: NSManagedObjectContext) -> ChatMessageEntity? {
        let request = NSFetchRequest<ChatMessageEntity>(entityName: "ChatMessageEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}

private extension NSManagedObjectContext {
    func entityDescription(_ name: String) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: name, in: self)!
    }
}
