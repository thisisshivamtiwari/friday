import Foundation
import CoreData

// MARK: - Managed object subclasses
// In-code model (no .xcdatamodeld bundle) - same convention as ChatSessionStore/MemoryStore.
// "...Record" suffix, not "...Entity" (matches MemoryStore's own reasoning: "Entity" is
// already taken, here by ProjectItem's use of the word "item" as its own domain concept, and
// consistency with MemoryEntityRecord/MemoryEdgeRecord's naming is valuable on its own).
@objc(ProjectRecord)
final class ProjectRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var statusRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@objc(ProjectItemRecord)
final class ProjectItemRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var projectID: UUID
    @NSManaged var kindRaw: String
    @NSManaged var name: String
    @NSManaged var itemDescription: String?
    @NSManaged var statusRaw: String
    @NSManaged var relatedItemID: UUID?
    @NSManaged var assignedTo: UUID?
    @NSManaged var sourceSessionID: UUID
    @NSManaged var sourceMessageIDsData: Data
    @NSManaged var createdAt: Date
    @NSManaged var lastUpdatedAt: Date
    @NSManaged var confidence: Float
    @NSManaged var isExplicit: Bool
}

@objc(DecisionRecord)
final class DecisionRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var projectID: UUID
    @NSManaged var statement: String
    @NSManaged var context: String?
    @NSManaged var relatedItemID: UUID?
    @NSManaged var madeByData: Data
    @NSManaged var reason: String?
    @NSManaged var statusRaw: String
    @NSManaged var supersedes: UUID?
    @NSManaged var supersededBy: UUID?
    @NSManaged var sourceSessionID: UUID
    @NSManaged var sourceMessageIDsData: Data
    @NSManaged var decidedAt: Date
}

@objc(MeetingRecord)
final class MeetingRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var projectID: UUID
    @NSManaged var title: String
    @NSManaged var participantEntityIDsData: Data
    @NSManaged var sessionIDsData: Data
    @NSManaged var occurredAt: Date
    @NSManaged var checkpointSummary: String?
}

@objc(ProjectEventRecord)
final class ProjectEventRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var projectID: UUID
    @NSManaged var relatedItemID: UUID
    @NSManaged var eventTypeRaw: String
    @NSManaged var eventDescription: String
    @NSManaged var occurredAt: Date
    @NSManaged var sourceSessionID: UUID?
    @NSManaged var sourceMessageIDsData: Data
}

@objc(ProjectSessionLinkRecord)
final class ProjectSessionLinkRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var sessionID: UUID
    @NSManaged var projectID: UUID
    @NSManaged var assignedAt: Date
    @NSManaged var lastReassignedAt: Date?
}

// MARK: - Project Store
/// Local-first Core Data persistence for Friday's project state (Project, ProjectItem,
/// Decision, Meeting, ProjectEvent, ProjectSessionLink) - completely independent of both
/// ChatSessionStore AND MemoryStore: its own SQLite file, its own in-code
/// NSManagedObjectModel, its own NSPersistentContainer. There is deliberately NOT a single
/// Core Data relationship anywhere in this store's model, nor between this store and either
/// of the other two. Cross-store references (`ProjectItem.sourceSessionID`,
/// `Decision.madeBy`, `Meeting.participantEntityIDs`, `ProjectSessionLink.sessionID`, etc.)
/// are ALL plain UUID values, resolved by the caller - exactly the design ChatSessionStore's
/// own doc comment anticipates, extended to a third layer.
///
/// All writes go through `container.performBackgroundTask`, never the main-thread
/// `viewContext` - ProjectManager already holds the authoritative in-memory state, so
/// persistence here is a fire-and-forget mirror, same as ChatSessionStore/MemoryStore. The
/// `completion` parameter on each write exists solely so tests can deterministically wait for
/// a write to land before asserting - production call sites never pass one.
final class ProjectStore {
    private let container: NSPersistentContainer

    /// `inMemory: true` is the test seam - same purpose as ChatSessionStore's/MemoryStore's.
    /// `storeURL` is a second, narrower test seam for pointing a REAL on-disk SQLite store at
    /// a temp file (e.g. for migration testing) without ever touching the real app's store.
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "FriendlyProjects", managedObjectModel: model)

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
                print("[ProjectStore] Failed to load persistent store: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("FounderOfficeCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A third, separate file alongside ChatSessions.sqlite and Memory.sqlite - three
        // independent stores, never one database shared across layers.
        return directory.appendingPathComponent("Projects.sqlite")
    }

    // MARK: Model
    // Not `private` (matches MemoryStore.makeModel()'s reasoning) - internal so tests can
    // inspect the model directly and assert it contains zero NSRelationshipDescriptions.
    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let projectEntity = NSEntityDescription()
        projectEntity.name = "ProjectRecord"
        projectEntity.managedObjectClassName = "ProjectRecord"

        let itemEntity = NSEntityDescription()
        itemEntity.name = "ProjectItemRecord"
        itemEntity.managedObjectClassName = "ProjectItemRecord"

        let decisionEntity = NSEntityDescription()
        decisionEntity.name = "DecisionRecord"
        decisionEntity.managedObjectClassName = "DecisionRecord"

        let meetingEntity = NSEntityDescription()
        meetingEntity.name = "MeetingRecord"
        meetingEntity.managedObjectClassName = "MeetingRecord"

        let eventEntity = NSEntityDescription()
        eventEntity.name = "ProjectEventRecord"
        eventEntity.managedObjectClassName = "ProjectEventRecord"

        let linkEntity = NSEntityDescription()
        linkEntity.name = "ProjectSessionLinkRecord"
        linkEntity.managedObjectClassName = "ProjectSessionLinkRecord"

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        /// Single-attribute index - see ChatSessionStore/MemoryStore's identical helper for
        /// why this matters (an unindexed lookup attribute means every fetch is a full-table
        /// scan).
        func index(_ name: String, _ attribute: NSAttributeDescription, on entity: NSEntityDescription) -> NSFetchIndexDescription {
            NSFetchIndexDescription(name: "\(entity.name ?? "entity")_\(name)_index", elements: [
                NSFetchIndexElementDescription(property: attribute, collationType: .binary)
            ])
        }

        // MARK: ProjectRecord
        let projectIDAttribute = attribute("id", .UUIDAttributeType)
        projectEntity.properties = [
            projectIDAttribute,
            attribute("name", .stringAttributeType),
            attribute("statusRaw", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType)
        ]
        projectEntity.indexes = [index("id", projectIDAttribute, on: projectEntity)]

        // MARK: ProjectItemRecord
        let itemIDAttribute = attribute("id", .UUIDAttributeType)
        let itemProjectIDAttribute = attribute("projectID", .UUIDAttributeType)
        itemEntity.properties = [
            itemIDAttribute,
            itemProjectIDAttribute,
            attribute("kindRaw", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("itemDescription", .stringAttributeType, optional: true),
            attribute("statusRaw", .stringAttributeType),
            attribute("relatedItemID", .UUIDAttributeType, optional: true),
            attribute("assignedTo", .UUIDAttributeType, optional: true),
            attribute("sourceSessionID", .UUIDAttributeType),
            attribute("sourceMessageIDsData", .binaryDataAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("lastUpdatedAt", .dateAttributeType),
            attribute("confidence", .floatAttributeType),
            attribute("isExplicit", .booleanAttributeType)
        ]
        itemEntity.indexes = [
            index("id", itemIDAttribute, on: itemEntity),
            index("projectID", itemProjectIDAttribute, on: itemEntity)
        ]

        // MARK: DecisionRecord
        let decisionIDAttribute = attribute("id", .UUIDAttributeType)
        let decisionProjectIDAttribute = attribute("projectID", .UUIDAttributeType)
        decisionEntity.properties = [
            decisionIDAttribute,
            decisionProjectIDAttribute,
            attribute("statement", .stringAttributeType),
            attribute("context", .stringAttributeType, optional: true),
            attribute("relatedItemID", .UUIDAttributeType, optional: true),
            attribute("madeByData", .binaryDataAttributeType),
            attribute("reason", .stringAttributeType, optional: true),
            attribute("statusRaw", .stringAttributeType),
            attribute("supersedes", .UUIDAttributeType, optional: true),
            attribute("supersededBy", .UUIDAttributeType, optional: true),
            attribute("sourceSessionID", .UUIDAttributeType),
            attribute("sourceMessageIDsData", .binaryDataAttributeType),
            attribute("decidedAt", .dateAttributeType)
        ]
        decisionEntity.indexes = [
            index("id", decisionIDAttribute, on: decisionEntity),
            index("projectID", decisionProjectIDAttribute, on: decisionEntity)
        ]

        // MARK: MeetingRecord
        let meetingIDAttribute = attribute("id", .UUIDAttributeType)
        let meetingProjectIDAttribute = attribute("projectID", .UUIDAttributeType)
        meetingEntity.properties = [
            meetingIDAttribute,
            meetingProjectIDAttribute,
            attribute("title", .stringAttributeType),
            attribute("participantEntityIDsData", .binaryDataAttributeType),
            attribute("sessionIDsData", .binaryDataAttributeType),
            attribute("occurredAt", .dateAttributeType),
            attribute("checkpointSummary", .stringAttributeType, optional: true)
        ]
        meetingEntity.indexes = [
            index("id", meetingIDAttribute, on: meetingEntity),
            index("projectID", meetingProjectIDAttribute, on: meetingEntity)
        ]

        // MARK: ProjectEventRecord
        let eventIDAttribute = attribute("id", .UUIDAttributeType)
        let eventProjectIDAttribute = attribute("projectID", .UUIDAttributeType)
        eventEntity.properties = [
            eventIDAttribute,
            eventProjectIDAttribute,
            attribute("relatedItemID", .UUIDAttributeType),
            attribute("eventTypeRaw", .stringAttributeType),
            attribute("eventDescription", .stringAttributeType),
            attribute("occurredAt", .dateAttributeType),
            attribute("sourceSessionID", .UUIDAttributeType, optional: true),
            attribute("sourceMessageIDsData", .binaryDataAttributeType)
        ]
        eventEntity.indexes = [
            index("id", eventIDAttribute, on: eventEntity),
            index("projectID", eventProjectIDAttribute, on: eventEntity)
        ]

        // MARK: ProjectSessionLinkRecord
        // sessionID AND projectID both indexed - required so forward (project -> sessions)
        // and reverse (session -> project) lookups are both real fetches, not full scans.
        let linkIDAttribute = attribute("id", .UUIDAttributeType)
        let linkSessionIDAttribute = attribute("sessionID", .UUIDAttributeType)
        let linkProjectIDAttribute = attribute("projectID", .UUIDAttributeType)
        linkEntity.properties = [
            linkIDAttribute,
            linkSessionIDAttribute,
            linkProjectIDAttribute,
            attribute("assignedAt", .dateAttributeType),
            attribute("lastReassignedAt", .dateAttributeType, optional: true)
        ]
        linkEntity.indexes = [
            index("id", linkIDAttribute, on: linkEntity),
            index("sessionID", linkSessionIDAttribute, on: linkEntity),
            index("projectID", linkProjectIDAttribute, on: linkEntity)
        ]

        // No NSRelationshipDescription anywhere in this model - every cross-reference above
        // (including intra-store ones like ProjectItem.projectID) is a plain UUID attribute.
        model.entities = [projectEntity, itemEntity, decisionEntity, meetingEntity, eventEntity, linkEntity]
        return model
    }

    // MARK: Reads - startup only, small, synchronous (same convention as ChatSessionStore/MemoryStore)

    func loadAllProjects() -> [Project] {
        let request = NSFetchRequest<ProjectRecord>(entityName: "ProjectRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.project(from:))
    }

    func loadAllProjectItems() -> [ProjectItem] {
        let request = NSFetchRequest<ProjectItemRecord>(entityName: "ProjectItemRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.item(from:))
    }

    func loadAllDecisions() -> [Decision] {
        let request = NSFetchRequest<DecisionRecord>(entityName: "DecisionRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "decidedAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.decision(from:))
    }

    func loadAllMeetings() -> [Meeting] {
        let request = NSFetchRequest<MeetingRecord>(entityName: "MeetingRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "occurredAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.meeting(from:))
    }

    func loadAllProjectEvents() -> [ProjectEvent] {
        let request = NSFetchRequest<ProjectEventRecord>(entityName: "ProjectEventRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "occurredAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.event(from:))
    }

    func loadAllProjectSessionLinks() -> [ProjectSessionLink] {
        let request = NSFetchRequest<ProjectSessionLinkRecord>(entityName: "ProjectSessionLinkRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "assignedAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else { return [] }
        return records.map(Self.link(from:))
    }

    // MARK: Record -> value conversion

    private static func project(from record: ProjectRecord) -> Project {
        Project(
            id: record.id,
            name: record.name,
            status: Project.Status(rawValue: record.statusRaw) ?? .active,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func item(from record: ProjectItemRecord) -> ProjectItem {
        ProjectItem(
            id: record.id,
            projectID: record.projectID,
            kind: ProjectItem.Kind(rawValue: record.kindRaw) ?? .task,
            name: record.name,
            description: record.itemDescription,
            status: ProjectItem.Status(rawValue: record.statusRaw) ?? .proposed,
            relatedItemID: record.relatedItemID,
            assignedTo: record.assignedTo,
            sourceSessionID: record.sourceSessionID,
            sourceMessageIDs: decode([UUID].self, from: record.sourceMessageIDsData) ?? [],
            createdAt: record.createdAt,
            lastUpdatedAt: record.lastUpdatedAt,
            confidence: record.confidence,
            isExplicit: record.isExplicit
        )
    }

    private static func decision(from record: DecisionRecord) -> Decision {
        Decision(
            id: record.id,
            projectID: record.projectID,
            statement: record.statement,
            context: record.context,
            relatedItemID: record.relatedItemID,
            madeBy: decode([UUID].self, from: record.madeByData) ?? [],
            reason: record.reason,
            status: Decision.Status(rawValue: record.statusRaw) ?? .active,
            supersedes: record.supersedes,
            supersededBy: record.supersededBy,
            sourceSessionID: record.sourceSessionID,
            sourceMessageIDs: decode([UUID].self, from: record.sourceMessageIDsData) ?? [],
            decidedAt: record.decidedAt
        )
    }

    private static func meeting(from record: MeetingRecord) -> Meeting {
        Meeting(
            id: record.id,
            projectID: record.projectID,
            title: record.title,
            participantEntityIDs: decode([UUID].self, from: record.participantEntityIDsData) ?? [],
            sessionIDs: decode([UUID].self, from: record.sessionIDsData) ?? [],
            occurredAt: record.occurredAt,
            checkpointSummary: record.checkpointSummary
        )
    }

    private static func event(from record: ProjectEventRecord) -> ProjectEvent {
        ProjectEvent(
            id: record.id,
            projectID: record.projectID,
            relatedItemID: record.relatedItemID,
            eventType: ProjectEvent.EventType(rawValue: record.eventTypeRaw) ?? .itemCreated,
            description: record.eventDescription,
            occurredAt: record.occurredAt,
            sourceSessionID: record.sourceSessionID,
            sourceMessageIDs: decode([UUID].self, from: record.sourceMessageIDsData) ?? []
        )
    }

    private static func link(from record: ProjectSessionLinkRecord) -> ProjectSessionLink {
        ProjectSessionLink(
            id: record.id,
            sessionID: record.sessionID,
            projectID: record.projectID,
            assignedAt: record.assignedAt,
            lastReassignedAt: record.lastReassignedAt
        )
    }

    // MARK: Writes - all async, background context. "create" = unconditional insert (mirrors
    // ChatSessionStore.createSession); "update" = fetch-then-apply, harmless no-op if the id
    // isn't found (mirrors ChatSessionStore.updateSessionMetadata).

    func createProject(_ project: Project, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = ProjectRecord(entity: context.entityDescription("ProjectRecord"), insertInto: context)
            Self.apply(project, to: record)
            try? context.save()
            completion?()
        }
    }

    func updateProject(_ project: Project, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchProjectRecord(id: project.id, in: context) else {
                completion?()
                return
            }
            Self.apply(project, to: record)
            try? context.save()
            completion?()
        }
    }

    func deleteProject(id: UUID, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchProjectRecord(id: id, in: context) else {
                completion?()
                return
            }
            context.delete(record)
            try? context.save()
            completion?()
        }
    }

    func createProjectItem(_ item: ProjectItem, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = ProjectItemRecord(entity: context.entityDescription("ProjectItemRecord"), insertInto: context)
            Self.apply(item, to: record)
            try? context.save()
            completion?()
        }
    }

    func updateProjectItem(_ item: ProjectItem, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchItemRecord(id: item.id, in: context) else {
                completion?()
                return
            }
            Self.apply(item, to: record)
            try? context.save()
            completion?()
        }
    }

    func createDecision(_ decision: Decision, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = DecisionRecord(entity: context.entityDescription("DecisionRecord"), insertInto: context)
            Self.apply(decision, to: record)
            try? context.save()
            completion?()
        }
    }

    func updateDecision(_ decision: Decision, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchDecisionRecord(id: decision.id, in: context) else {
                completion?()
                return
            }
            Self.apply(decision, to: record)
            try? context.save()
            completion?()
        }
    }

    func createMeeting(_ meeting: Meeting, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = MeetingRecord(entity: context.entityDescription("MeetingRecord"), insertInto: context)
            Self.apply(meeting, to: record)
            try? context.save()
            completion?()
        }
    }

    func updateMeeting(_ meeting: Meeting, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchMeetingRecord(id: meeting.id, in: context) else {
                completion?()
                return
            }
            Self.apply(meeting, to: record)
            try? context.save()
            completion?()
        }
    }

    func createProjectEvent(_ event: ProjectEvent, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = ProjectEventRecord(entity: context.entityDescription("ProjectEventRecord"), insertInto: context)
            Self.apply(event, to: record)
            try? context.save()
            completion?()
        }
    }

    func createProjectSessionLink(_ link: ProjectSessionLink, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let record = ProjectSessionLinkRecord(entity: context.entityDescription("ProjectSessionLinkRecord"), insertInto: context)
            Self.apply(link, to: record)
            try? context.save()
            completion?()
        }
    }

    func updateProjectSessionLink(_ link: ProjectSessionLink, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchLinkRecord(id: link.id, in: context) else {
                completion?()
                return
            }
            Self.apply(link, to: record)
            try? context.save()
            completion?()
        }
    }

    func deleteProjectSessionLink(id: UUID, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            guard let record = Self.fetchLinkRecord(id: id, in: context) else {
                completion?()
                return
            }
            context.delete(record)
            try? context.save()
            completion?()
        }
    }

    /// Deletes every ProjectSessionLink row for `projectID` in one background pass - used by
    /// ProjectManager when a project is permanently deleted (see its doc comment for why only
    /// links are cleaned up here, never the referenced ChatSessions).
    func deleteProjectSessionLinks(forProject projectID: UUID, completion: (() -> Void)? = nil) {
        container.performBackgroundTask { context in
            let request = NSFetchRequest<ProjectSessionLinkRecord>(entityName: "ProjectSessionLinkRecord")
            request.predicate = NSPredicate(format: "projectID == %@", projectID as CVarArg)
            if let records = try? context.fetch(request) {
                for record in records {
                    context.delete(record)
                }
            }
            try? context.save()
            completion?()
        }
    }

    // MARK: apply (value -> record)

    private static func apply(_ project: Project, to record: ProjectRecord) {
        record.id = project.id
        record.name = project.name
        record.statusRaw = project.status.rawValue
        record.createdAt = project.createdAt
        record.updatedAt = project.updatedAt
    }

    private static func apply(_ item: ProjectItem, to record: ProjectItemRecord) {
        record.id = item.id
        record.projectID = item.projectID
        record.kindRaw = item.kind.rawValue
        record.name = item.name
        record.itemDescription = item.description
        record.statusRaw = item.status.rawValue
        record.relatedItemID = item.relatedItemID
        record.assignedTo = item.assignedTo
        record.sourceSessionID = item.sourceSessionID
        record.sourceMessageIDsData = encode(item.sourceMessageIDs) ?? Data()
        record.createdAt = item.createdAt
        record.lastUpdatedAt = item.lastUpdatedAt
        record.confidence = item.confidence
        record.isExplicit = item.isExplicit
    }

    private static func apply(_ decision: Decision, to record: DecisionRecord) {
        record.id = decision.id
        record.projectID = decision.projectID
        record.statement = decision.statement
        record.context = decision.context
        record.relatedItemID = decision.relatedItemID
        record.madeByData = encode(decision.madeBy) ?? Data()
        record.reason = decision.reason
        record.statusRaw = decision.status.rawValue
        record.supersedes = decision.supersedes
        record.supersededBy = decision.supersededBy
        record.sourceSessionID = decision.sourceSessionID
        record.sourceMessageIDsData = encode(decision.sourceMessageIDs) ?? Data()
        record.decidedAt = decision.decidedAt
    }

    private static func apply(_ meeting: Meeting, to record: MeetingRecord) {
        record.id = meeting.id
        record.projectID = meeting.projectID
        record.title = meeting.title
        record.participantEntityIDsData = encode(meeting.participantEntityIDs) ?? Data()
        record.sessionIDsData = encode(meeting.sessionIDs) ?? Data()
        record.occurredAt = meeting.occurredAt
        record.checkpointSummary = meeting.checkpointSummary
    }

    private static func apply(_ event: ProjectEvent, to record: ProjectEventRecord) {
        record.id = event.id
        record.projectID = event.projectID
        record.relatedItemID = event.relatedItemID
        record.eventTypeRaw = event.eventType.rawValue
        record.eventDescription = event.description
        record.occurredAt = event.occurredAt
        record.sourceSessionID = event.sourceSessionID
        record.sourceMessageIDsData = encode(event.sourceMessageIDs) ?? Data()
    }

    private static func apply(_ link: ProjectSessionLink, to record: ProjectSessionLinkRecord) {
        record.id = link.id
        record.sessionID = link.sessionID
        record.projectID = link.projectID
        record.assignedAt = link.assignedAt
        record.lastReassignedAt = link.lastReassignedAt
    }

    // MARK: Fetch helpers

    private static func fetchProjectRecord(id: UUID, in context: NSManagedObjectContext) -> ProjectRecord? {
        let request = NSFetchRequest<ProjectRecord>(entityName: "ProjectRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func fetchItemRecord(id: UUID, in context: NSManagedObjectContext) -> ProjectItemRecord? {
        let request = NSFetchRequest<ProjectItemRecord>(entityName: "ProjectItemRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func fetchDecisionRecord(id: UUID, in context: NSManagedObjectContext) -> DecisionRecord? {
        let request = NSFetchRequest<DecisionRecord>(entityName: "DecisionRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func fetchMeetingRecord(id: UUID, in context: NSManagedObjectContext) -> MeetingRecord? {
        let request = NSFetchRequest<MeetingRecord>(entityName: "MeetingRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private static func fetchLinkRecord(id: UUID, in context: NSManagedObjectContext) -> ProjectSessionLinkRecord? {
        let request = NSFetchRequest<ProjectSessionLinkRecord>(entityName: "ProjectSessionLinkRecord")
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
