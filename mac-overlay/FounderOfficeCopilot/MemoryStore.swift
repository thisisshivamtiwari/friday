import Foundation
import CoreData

// MARK: - Managed object subclasses
// In-code model (no .xcdatamodeld bundle) - same reasoning as ChatSessionStore: the
// hand-maintained project.pbxproj has an established, working pattern for registering plain
// Swift source files, but no template for a compiled Core Data resource. @objc(...) pins the
// runtime class name so it matches NSEntityDescription.managedObjectClassName exactly,
// regardless of Swift module-name mangling.
//
// Named "...Record" rather than "...Entity" (the convention ChatSessionStore uses) because
// "Entity" is already taken as this feature's own domain type name (MemoryEntity) - stacking
// it here would read as "MemoryEntityEntity".
@objc(MemoryEntityRecord)
final class MemoryEntityRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var kindRaw: String
    @NSManaged var name: String
    /// JSON-encoded [String] - Core Data has no native string-array attribute type; encoding
    /// avoids any delimiter-collision risk a joined string would have.
    @NSManaged var aliasesData: Data
    @NSManaged var notes: String?
    @NSManaged var isUserVerified: Bool
    @NSManaged var createdAt: Date
    @NSManaged var lastMentionedAt: Date
    @NSManaged var mentionCount: Int64
}

@objc(MemoryEdgeRecord)
final class MemoryEdgeRecord: NSManagedObject {
    @NSManaged var id: UUID
    /// Plain UUID, NOT a Core Data relationship to MemoryEntityRecord - see MemoryStore's
    /// own doc comment for why this store has zero Core Data relationships of any kind.
    @NSManaged var subjectEntityID: UUID
    @NSManaged var predicate: String
    @NSManaged var objectEntityID: UUID?
    @NSManaged var literalValue: String?
    @NSManaged var categoryRaw: String
    @NSManaged var confidence: Float
    @NSManaged var statusRaw: String
    /// Plain UUID reference into ChatSessionStore's data - NEVER a Core Data relationship
    /// across stores. See MemoryStore's doc comment.
    @NSManaged var sourceSessionID: UUID
    /// JSON-encoded [UUID].
    @NSManaged var sourceMessageIDsData: Data
    @NSManaged var firstObservedAt: Date
    @NSManaged var lastConfirmedAt: Date
    @NSManaged var confirmationCount: Int64
    @NSManaged var supersedes: UUID?
    @NSManaged var supersededBy: UUID?
    @NSManaged var isExplicit: Bool
    @NSManaged var isPinned: Bool
}

// MARK: - Memory Store
/// Local-first Core Data persistence for Friday's memory graph (MemoryEntity nodes,
/// MemoryEdge edges) - completely independent of ChatSessionStore: its own SQLite file, its
/// own in-code NSManagedObjectModel, its own NSPersistentContainer. There is deliberately NOT
/// a single Core Data relationship anywhere in this store's model - not between
/// MemoryEntityRecord and MemoryEdgeRecord, and certainly not to anything in
/// ChatSessionStore's model. `MemoryEdgeRecord.subjectEntityID`/`objectEntityID` reference
/// MemoryEntityRecord rows, and `sourceSessionID`/`sourceMessageIDsData` reference
/// ChatSessionStore's rows, but ALL of these are plain UUID values, resolved by the caller
/// (MemoryManager, and later ChatSessionManager lookups) rather than by Core Data - exactly
/// the design ChatSessionStore's own doc comment anticipates: "chat history" and "derived
/// knowledge" never become entangled at the data layer.
///
/// All writes go through `container.performBackgroundTask`, never the main-thread
/// `viewContext` - MemoryManager already holds the authoritative in-memory state and updates
/// it synchronously, so persistence here is a fire-and-forget mirror, same as
/// ChatSessionStore. The `completion` parameter on each write exists solely so tests can
/// deterministically wait for a write to land before asserting - production call sites never
/// pass one.
final class MemoryStore {
    private let container: NSPersistentContainer

    /// `inMemory: true` is the test seam - same purpose as ChatSessionStore's. `storeURL` is
    /// a second, narrower test seam for pointing a REAL on-disk SQLite store at a temp file
    /// (e.g. for migration testing) without ever touching the real app's store.
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "FriendlyMemory", managedObjectModel: model)

        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            description.type = NSSQLiteStoreType
            description.url = storeURL ?? Self.storeURL()
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error {
                print("[MemoryStore] Failed to load persistent store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("FounderOfficeCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A separate file from ChatSessions.sqlite, in the same app support directory - two
        // independent stores, not two databases sharing one file.
        return directory.appendingPathComponent("Memory.sqlite")
    }

    // MARK: Model
    // Not `private` (unlike ChatSessionStore.makeModel()) - deliberately internal so tests
    // can inspect the model directly and assert it contains zero NSRelationshipDescriptions,
    // proving "no Core Data relationships to ChatSessionStore" structurally, not just by
    // convention.
    static func makeModel() -> NSManagedObjectModel {
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

        /// A single-attribute index - see ChatSessionStore's identical helper for why this
        /// matters (an unindexed `id`/lookup attribute means every fetch is a full-table
        /// scan). `NSFetchIndexDescription`/`NSFetchIndexElementDescription`, not the
        /// deprecated `NSAttributeDescription.isIndexed`.
        func index(_ name: String, _ attribute: NSAttributeDescription, on entity: NSEntityDescription) -> NSFetchIndexDescription {
            NSFetchIndexDescription(name: "\(entity.name ?? "entity")_\(name)_index", elements: [
                NSFetchIndexElementDescription(property: attribute, collationType: .binary)
            ])
        }

        let entityIDAttribute = attribute("id", .UUIDAttributeType)
        entityRecord.properties = [
            entityIDAttribute,
            attribute("kindRaw", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("aliasesData", .binaryDataAttributeType),
            attribute("notes", .stringAttributeType, optional: true),
            attribute("isUserVerified", .booleanAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("lastMentionedAt", .dateAttributeType),
            attribute("mentionCount", .integer64AttributeType)
        ]
        entityRecord.indexes = [index("id", entityIDAttribute, on: entityRecord)]

        let edgeIDAttribute = attribute("id", .UUIDAttributeType)
        let subjectEntityIDAttribute = attribute("subjectEntityID", .UUIDAttributeType)
        edgeRecord.properties = [
            edgeIDAttribute,
            subjectEntityIDAttribute,
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
        edgeRecord.indexes = [
            index("id", edgeIDAttribute, on: edgeRecord),
            index("subjectEntityID", subjectEntityIDAttribute, on: edgeRecord)
        ]

        // No NSRelationshipDescription anywhere - subjectEntityID/objectEntityID are plain
        // UUID attributes above, not relationships, even though both entities live in this
        // same model. Uniform with sourceSessionID/sourceMessageIDsData (which MUST be plain
        // UUIDs since they cross into a different store entirely) rather than mixing
        // Core Data relationships for intra-store links with UUIDs for cross-store ones.
        model.entities = [entityRecord, edgeRecord]
        return model
    }

    // MARK: Reads - startup only, small, synchronous (same convention as ChatSessionStore)

    func loadAllEntities() -> [MemoryEntity] {
        let request = NSFetchRequest<MemoryEntityRecord>(entityName: "MemoryEntityRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.entity(from:))
    }

    func loadAllEdges() -> [MemoryEdge] {
        let request = NSFetchRequest<MemoryEdgeRecord>(entityName: "MemoryEdgeRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "firstObservedAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.edge(from:))
    }

    private static func entity(from record: MemoryEntityRecord) -> MemoryEntity {
        MemoryEntity(
            id: record.id,
            kind: MemoryEntity.Kind(rawValue: record.kindRaw) ?? .other,
            name: record.name,
            aliases: decode([String].self, from: record.aliasesData) ?? [],
            notes: record.notes,
            isUserVerified: record.isUserVerified,
            createdAt: record.createdAt,
            lastMentionedAt: record.lastMentionedAt,
            mentionCount: Int(record.mentionCount)
        )
    }

    private static func edge(from record: MemoryEdgeRecord) -> MemoryEdge {
        MemoryEdge(
            id: record.id,
            subjectEntityID: record.subjectEntityID,
            predicate: record.predicate,
            objectEntityID: record.objectEntityID,
            literalValue: record.literalValue,
            category: MemoryEdge.Category(rawValue: record.categoryRaw) ?? .other,
            confidence: record.confidence,
            status: MemoryEdge.Status(rawValue: record.statusRaw) ?? .active,
            sourceSessionID: record.sourceSessionID,
            sourceMessageIDs: decode([UUID].self, from: record.sourceMessageIDsData) ?? [],
            firstObservedAt: record.firstObservedAt,
            lastConfirmedAt: record.lastConfirmedAt,
            confirmationCount: Int(record.confirmationCount),
            supersedes: record.supersedes,
            supersededBy: record.supersededBy,
            isExplicit: record.isExplicit,
            isPinned: record.isPinned
        )
    }

    // MARK: Writes - all async, background context

    /// Unconditional insert - mirrors ChatSessionStore.createSession's "this is new, no
    /// existence check" semantics.
    func createEntity(_ entity: MemoryEntity, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = MemoryEntityRecord(entity: context.entityDescription("MemoryEntityRecord"), insertInto: context)
            Self.apply(entity, to: record)
            try? context.save()
            completion?()
        }
    }

    /// Fetch-then-apply - mirrors ChatSessionStore.updateSessionMetadata's "must already
    /// exist" semantics; a harmless no-op if the id isn't found.
    func updateEntity(_ entity: MemoryEntity, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchEntityRecord(id: entity.id, in: context) else {
                completion?()
                return
            }
            Self.apply(entity, to: record)
            try? context.save()
            completion?()
        }
    }

    func createEdge(_ edge: MemoryEdge, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = MemoryEdgeRecord(entity: context.entityDescription("MemoryEdgeRecord"), insertInto: context)
            Self.apply(edge, to: record)
            try? context.save()
            completion?()
        }
    }

    func updateEdge(_ edge: MemoryEdge, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchEdgeRecord(id: edge.id, in: context) else {
                completion?()
                return
            }
            Self.apply(edge, to: record)
            try? context.save()
            completion?()
        }
    }

    /// Permanent, irreversible removal - distinct from soft-forgetting (a status update via
    /// updateEdge, see MemoryManager.forgetEdge). Nothing in this phase calls this
    /// automatically; it exists as the store-level primitive future user-facing "permanently
    /// delete" actions will call.
    func deleteEntity(id: UUID, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchEntityRecord(id: id, in: context) else {
                completion?()
                return
            }
            context.delete(record)
            try? context.save()
            completion?()
        }
    }

    func deleteEdge(id: UUID, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchEdgeRecord(id: id, in: context) else {
                completion?()
                return
            }
            context.delete(record)
            try? context.save()
            completion?()
        }
    }

    private static func apply(_ entity: MemoryEntity, to record: MemoryEntityRecord) {
        record.id = entity.id
        record.kindRaw = entity.kind.rawValue
        record.name = entity.name
        record.aliasesData = encode(entity.aliases) ?? Data()
        record.notes = entity.notes
        record.isUserVerified = entity.isUserVerified
        record.createdAt = entity.createdAt
        record.lastMentionedAt = entity.lastMentionedAt
        record.mentionCount = Int64(entity.mentionCount)
    }

    private static func apply(_ edge: MemoryEdge, to record: MemoryEdgeRecord) {
        record.id = edge.id
        record.subjectEntityID = edge.subjectEntityID
        record.predicate = edge.predicate
        record.objectEntityID = edge.objectEntityID
        record.literalValue = edge.literalValue
        record.categoryRaw = edge.category.rawValue
        record.confidence = edge.confidence
        record.statusRaw = edge.status.rawValue
        record.sourceSessionID = edge.sourceSessionID
        record.sourceMessageIDsData = encode(edge.sourceMessageIDs) ?? Data()
        record.firstObservedAt = edge.firstObservedAt
        record.lastConfirmedAt = edge.lastConfirmedAt
        record.confirmationCount = Int64(edge.confirmationCount)
        record.supersedes = edge.supersedes
        record.supersededBy = edge.supersededBy
        record.isExplicit = edge.isExplicit
        record.isPinned = edge.isPinned
    }

    private static func fetchEntityRecord(id: UUID, in context: NSManagedObjectContext) -> MemoryEntityRecord? {
        let request = NSFetchRequest<MemoryEntityRecord>(entityName: "MemoryEntityRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func fetchEdgeRecord(id: UUID, in context: NSManagedObjectContext) -> MemoryEdgeRecord? {
        let request = NSFetchRequest<MemoryEdgeRecord>(entityName: "MemoryEdgeRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

private extension NSManagedObjectContext {
    func entityDescription(_ name: String) -> NSEntityDescription {
        NSEntityDescription.entity(forEntityName: name, in: self)!
    }
}
