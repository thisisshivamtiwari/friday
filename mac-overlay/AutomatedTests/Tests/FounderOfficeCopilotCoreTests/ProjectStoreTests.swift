import XCTest
import CoreData
@testable import FounderOfficeCopilotCore

/// Covers ProjectStore's Core Data persistence directly - round-trip correctness for all six
/// entities, update-in-place semantics, decision supersession persistence, migration safety,
/// and the architectural requirement that this store has ZERO Core Data relationships
/// anywhere in its model, including to ChatSessionStore's and MemoryStore's models. Every
/// test uses `ProjectStore(inMemory: true)` unless specifically testing on-disk/migration
/// behavior, in which case a temp file is used - never the real app's saved project data.
final class ProjectStoreTests: XCTestCase {
    private func write(_ store: ProjectStore, _ body: (@escaping () -> Void) -> Void) {
        let expectation = expectation(description: "write completed")
        body { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: Project round trip

    func testFreshStoreHasNoData() {
        let store = ProjectStore(inMemory: true)
        XCTAssertTrue(store.loadAllProjects().isEmpty)
        XCTAssertTrue(store.loadAllProjectItems().isEmpty)
        XCTAssertTrue(store.loadAllDecisions().isEmpty)
        XCTAssertTrue(store.loadAllMeetings().isEmpty)
        XCTAssertTrue(store.loadAllProjectEvents().isEmpty)
        XCTAssertTrue(store.loadAllProjectSessionLinks().isEmpty)
    }

    func testCreateProjectRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let project = Project(name: "Trustworthy AI")
        write(store) { store.createProject(project, completion: $0) }

        let loaded = store.loadAllProjects()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, project.id)
        XCTAssertEqual(loaded.first?.name, "Trustworthy AI")
        XCTAssertEqual(loaded.first?.status, .active)
    }

    func testUpdateProjectOverwritesRatherThanDuplicating() {
        let store = ProjectStore(inMemory: true)
        var project = Project(name: "Trustworthy AI")
        write(store) { store.createProject(project, completion: $0) }

        project.status = .completed
        write(store) { store.updateProject(project, completion: $0) }

        let loaded = store.loadAllProjects()
        XCTAssertEqual(loaded.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(loaded.first?.status, .completed)
    }

    func testDeleteProjectRemovesIt() {
        let store = ProjectStore(inMemory: true)
        let project = Project(name: "Trustworthy AI")
        write(store) { store.createProject(project, completion: $0) }
        write(store) { store.deleteProject(id: project.id, completion: $0) }
        XCTAssertTrue(store.loadAllProjects().isEmpty)
    }

    // MARK: ProjectItem round trip

    func testCreateProjectItemRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let projectID = UUID()
        let sessionID = UUID()
        let messageID = UUID()
        let assignee = UUID()
        let item = ProjectItem(projectID: projectID, kind: .task, name: "Implement Bayesian calibration", description: "compare against baseline", status: .inProgress, assignedTo: assignee, sourceSessionID: sessionID, sourceMessageIDs: [messageID], confidence: 0.8, isExplicit: true)

        write(store) { store.createProjectItem(item, completion: $0) }

        let loaded = store.loadAllProjectItems().first
        XCTAssertEqual(loaded?.projectID, projectID)
        XCTAssertEqual(loaded?.kind, .task)
        XCTAssertEqual(loaded?.name, "Implement Bayesian calibration")
        XCTAssertEqual(loaded?.description, "compare against baseline")
        XCTAssertEqual(loaded?.status, .inProgress)
        XCTAssertEqual(loaded?.assignedTo, assignee)
        XCTAssertEqual(loaded?.sourceSessionID, sessionID)
        XCTAssertEqual(loaded?.sourceMessageIDs, [messageID])
        XCTAssertEqual(loaded?.confidence, 0.8)
        XCTAssertTrue(loaded?.isExplicit ?? false)
    }

    func testUpdateProjectItemOverwritesRatherThanDuplicating() {
        let store = ProjectStore(inMemory: true)
        var item = ProjectItem(projectID: UUID(), kind: .task, name: "Compare methods", sourceSessionID: UUID())
        write(store) { store.createProjectItem(item, completion: $0) }

        item.status = .completed
        write(store) { store.updateProjectItem(item, completion: $0) }

        let loaded = store.loadAllProjectItems()
        XCTAssertEqual(loaded.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(loaded.first?.status, .completed)
    }

    func testResultRelatedItemIDRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let projectID = UUID()
        let sessionID = UUID()
        let experiment = ProjectItem(projectID: projectID, kind: .experiment, name: "Experiment 4", sourceSessionID: sessionID)
        let result = ProjectItem(projectID: projectID, kind: .result, name: "12% improvement", relatedItemID: experiment.id, sourceSessionID: sessionID)
        write(store) { store.createProjectItem(experiment, completion: $0) }
        write(store) { store.createProjectItem(result, completion: $0) }

        let loadedResult = store.loadAllProjectItems().first { $0.id == result.id }
        XCTAssertEqual(loadedResult?.relatedItemID, experiment.id)
    }

    // MARK: Decision round trip and supersession

    func testCreateDecisionRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let projectID = UUID()
        let sessionID = UUID()
        let professor = UUID()
        let shivam = UUID()
        let decision = Decision(projectID: projectID, statement: "Use Bayesian calibration", context: "XYZ algorithm", madeBy: [professor, shivam], reason: "better uncertainty estimates", sourceSessionID: sessionID)

        write(store) { store.createDecision(decision, completion: $0) }

        let loaded = store.loadAllDecisions().first
        XCTAssertEqual(loaded?.statement, "Use Bayesian calibration")
        XCTAssertEqual(loaded?.context, "XYZ algorithm")
        XCTAssertEqual(loaded?.madeBy, [professor, shivam])
        XCTAssertEqual(loaded?.reason, "better uncertainty estimates")
        XCTAssertEqual(loaded?.status, .active)
    }

    func testDecisionSupersessionLinksRoundTrip() {
        let store = ProjectStore(inMemory: true)
        let projectID = UUID()
        let sessionID = UUID()
        let oldDecision = Decision(projectID: projectID, statement: "Use method B", sourceSessionID: sessionID)
        write(store) { store.createDecision(oldDecision, completion: $0) }

        var newDecision = Decision(projectID: projectID, statement: "Use Bayesian calibration instead", sourceSessionID: sessionID)
        newDecision.supersedes = oldDecision.id
        write(store) { store.createDecision(newDecision, completion: $0) }

        var updatedOld = oldDecision
        updatedOld.status = .superseded
        updatedOld.supersededBy = newDecision.id
        write(store) { store.updateDecision(updatedOld, completion: $0) }

        let loaded = store.loadAllDecisions()
        let oldLoaded = loaded.first { $0.id == oldDecision.id }
        let newLoaded = loaded.first { $0.id == newDecision.id }
        XCTAssertEqual(oldLoaded?.status, .superseded)
        XCTAssertEqual(oldLoaded?.supersededBy, newDecision.id)
        XCTAssertEqual(newLoaded?.supersedes, oldDecision.id)
        XCTAssertEqual(loaded.count, 2, "superseding must never delete the old decision - history is preserved")
    }

    // MARK: Meeting round trip

    func testCreateMeetingRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let projectID = UUID()
        let participant = UUID()
        let sessionA = UUID()
        let sessionB = UUID()
        let meeting = Meeting(projectID: projectID, title: "Weekly sync", participantEntityIDs: [participant], sessionIDs: [sessionA, sessionB], checkpointSummary: "discussed calibration results")

        write(store) { store.createMeeting(meeting, completion: $0) }

        let loaded = store.loadAllMeetings().first
        XCTAssertEqual(loaded?.title, "Weekly sync")
        XCTAssertEqual(loaded?.participantEntityIDs, [participant])
        XCTAssertEqual(loaded?.sessionIDs, [sessionA, sessionB])
        XCTAssertEqual(loaded?.checkpointSummary, "discussed calibration results")
    }

    func testUpdateMeetingOverwritesRatherThanDuplicating() {
        let store = ProjectStore(inMemory: true)
        var meeting = Meeting(projectID: UUID(), title: "Weekly sync")
        write(store) { store.createMeeting(meeting, completion: $0) }

        meeting.checkpointSummary = "now with a summary"
        write(store) { store.updateMeeting(meeting, completion: $0) }

        let loaded = store.loadAllMeetings()
        XCTAssertEqual(loaded.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(loaded.first?.checkpointSummary, "now with a summary")
    }

    // MARK: ProjectEvent round trip (append-only)

    func testCreateProjectEventRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let projectID = UUID()
        let relatedID = UUID()
        let sessionID = UUID()
        let event = ProjectEvent(projectID: projectID, relatedItemID: relatedID, eventType: .decisionMade, description: "Decided to use Bayesian calibration", sourceSessionID: sessionID)

        write(store) { store.createProjectEvent(event, completion: $0) }

        let loaded = store.loadAllProjectEvents().first
        XCTAssertEqual(loaded?.relatedItemID, relatedID)
        XCTAssertEqual(loaded?.eventType, .decisionMade)
        XCTAssertEqual(loaded?.sourceSessionID, sessionID)
    }

    // MARK: ProjectSessionLink round trip

    func testCreateProjectSessionLinkRoundTrips() {
        let store = ProjectStore(inMemory: true)
        let sessionID = UUID()
        let projectID = UUID()
        let link = ProjectSessionLink(sessionID: sessionID, projectID: projectID)

        write(store) { store.createProjectSessionLink(link, completion: $0) }

        let loaded = store.loadAllProjectSessionLinks().first
        XCTAssertEqual(loaded?.sessionID, sessionID)
        XCTAssertEqual(loaded?.projectID, projectID)
        XCTAssertNil(loaded?.lastReassignedAt)
    }

    func testUpdateProjectSessionLinkOverwritesRatherThanDuplicating() {
        let store = ProjectStore(inMemory: true)
        var link = ProjectSessionLink(sessionID: UUID(), projectID: UUID())
        write(store) { store.createProjectSessionLink(link, completion: $0) }

        let newProjectID = UUID()
        link.projectID = newProjectID
        link.lastReassignedAt = Date()
        write(store) { store.updateProjectSessionLink(link, completion: $0) }

        let loaded = store.loadAllProjectSessionLinks()
        XCTAssertEqual(loaded.count, 1, "reassignment must update in place, never duplicate")
        XCTAssertEqual(loaded.first?.projectID, newProjectID)
        XCTAssertNotNil(loaded.first?.lastReassignedAt)
    }

    func testDeleteProjectSessionLinksForProjectRemovesOnlyThatProjectsLinks() {
        let store = ProjectStore(inMemory: true)
        let projectA = UUID()
        let projectB = UUID()
        write(store) { store.createProjectSessionLink(ProjectSessionLink(sessionID: UUID(), projectID: projectA), completion: $0) }
        write(store) { store.createProjectSessionLink(ProjectSessionLink(sessionID: UUID(), projectID: projectA), completion: $0) }
        write(store) { store.createProjectSessionLink(ProjectSessionLink(sessionID: UUID(), projectID: projectB), completion: $0) }

        write(store) { store.deleteProjectSessionLinks(forProject: projectA, completion: $0) }

        let remaining = store.loadAllProjectSessionLinks()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.projectID, projectB)
    }

    // MARK: Zero Core Data relationships

    /// Structural proof: ProjectStore's own model must contain ZERO NSRelationshipDescriptions
    /// anywhere - not among its own six entities, and certainly not to ChatSessionStore's or
    /// MemoryStore's. Every cross-reference (projectID, sourceSessionID, sessionID,
    /// assignedTo, madeBy, etc.) is a plain UUID/Data attribute.
    func testProjectModelHasZeroCoreDataRelationships() {
        let model = ProjectStore.makeModel()
        XCTAssertEqual(model.entities.count, 6)

        for entity in model.entities {
            let relationships = entity.properties.compactMap { $0 as? NSRelationshipDescription }
            XCTAssertTrue(relationships.isEmpty, "\(entity.name ?? "?") must have zero Core Data relationships, found: \(relationships.map { $0.name })")
        }
    }

    func testProjectModelDoesNotReuseChatOrMemoryEntityNames() {
        let model = ProjectStore.makeModel()
        let otherStoreEntityNames: Set<String> = [
            "ChatSessionEntity", "ChatMessageEntity",
            "MemoryEntityRecord", "MemoryEdgeRecord"
        ]
        let projectEntityNames = Set(model.entities.compactMap { $0.name })
        XCTAssertTrue(projectEntityNames.isDisjoint(with: otherStoreEntityNames))
    }

    /// sessionID and projectID must BOTH be indexed on ProjectSessionLinkRecord specifically -
    /// this is the entity the whole session<->project association design depends on for fast
    /// forward and reverse lookups.
    func testProjectSessionLinkRecordHasBothSessionIDAndProjectIDIndexed() {
        let model = ProjectStore.makeModel()
        guard let linkEntity = model.entities.first(where: { $0.name == "ProjectSessionLinkRecord" }) else {
            return XCTFail("ProjectSessionLinkRecord entity not found")
        }
        let indexedAttributeNames = Set(linkEntity.indexes.flatMap { $0.elements.compactMap { ($0.property as? NSAttributeDescription)?.name } })
        XCTAssertTrue(indexedAttributeNames.contains("sessionID"), "sessionID must be indexed")
        XCTAssertTrue(indexedAttributeNames.contains("projectID"), "projectID must be indexed")
    }

    // MARK: Cross-store independence

    func testDeletingAChatSessionDoesNotAffectAProjectItemThatReferencesIt() {
        let chatStore = ChatSessionStore(inMemory: true)
        let projectStore = ProjectStore(inMemory: true)

        let session = ChatSession(id: UUID(), title: "Test", createdAt: Date(), updatedAt: Date(), lastMessageAt: nil, isPinned: false, isArchived: false, summary: nil, messages: [])
        let chatExpectation = expectation(description: "chat session created")
        chatStore.createSession(session) { chatExpectation.fulfill() }
        wait(for: [chatExpectation], timeout: 2.0)

        let item = ProjectItem(projectID: UUID(), kind: .task, name: "Task", sourceSessionID: session.id)
        write(projectStore) { projectStore.createProjectItem(item, completion: $0) }

        let deleteExpectation = expectation(description: "chat session deleted")
        chatStore.deleteSession(session.id) { deleteExpectation.fulfill() }
        wait(for: [deleteExpectation], timeout: 2.0)

        XCTAssertTrue(chatStore.loadAllSessions().isEmpty, "sanity check")
        let stillThere = projectStore.loadAllProjectItems().first { $0.id == item.id }
        XCTAssertNotNil(stillThere, "the project item must be completely unaffected by the source conversation being deleted")
        XCTAssertEqual(stillThere?.sourceSessionID, session.id, "the now-dangling reference is left as-is, not nullified")
    }

    func testDeletingAMemoryEntityDoesNotAffectADecisionThatReferencesItAsMadeBy() {
        let memoryStore = MemoryStore(inMemory: true)
        let projectStore = ProjectStore(inMemory: true)

        let professor = MemoryEntity(kind: .person, name: "Professor X")
        let memoryExpectation = expectation(description: "memory entity created")
        memoryStore.createEntity(professor) { memoryExpectation.fulfill() }
        wait(for: [memoryExpectation], timeout: 2.0)

        let decision = Decision(projectID: UUID(), statement: "Use Bayesian calibration", madeBy: [professor.id], sourceSessionID: UUID())
        write(projectStore) { projectStore.createDecision(decision, completion: $0) }

        let deleteExpectation = expectation(description: "memory entity deleted")
        memoryStore.deleteEntity(id: professor.id) { deleteExpectation.fulfill() }
        wait(for: [deleteExpectation], timeout: 2.0)

        XCTAssertTrue(memoryStore.loadAllEntities().isEmpty, "sanity check")
        let stillThere = projectStore.loadAllDecisions().first { $0.id == decision.id }
        XCTAssertNotNil(stillThere)
        XCTAssertEqual(stillThere?.madeBy, [professor.id], "the now-dangling reference is left as-is, not nullified")
    }

    func testTwoSeparateInMemoryStoresDoNotShareState() {
        let storeA = ProjectStore(inMemory: true)
        let storeB = ProjectStore(inMemory: true)
        write(storeA) { storeA.createProject(Project(name: "A"), completion: $0) }

        XCTAssertEqual(storeA.loadAllProjects().count, 1)
        XCTAssertEqual(storeB.loadAllProjects().count, 0)
    }

    // MARK: Migration safety

    /// Mirrors ChatSessionStoreTests/MemoryStoreTests' identical approach: builds the full
    /// six-entity shape ProjectStore.makeModel() would have WITHOUT its indexes, writes real
    /// data with that model to a real on-disk SQLite file, then opens the SAME file with the
    /// current (indexed) ProjectStore and confirms the data survives.
    private func makePreIndexModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        func makeEntity(_ name: String) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = name
            return entity
        }

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }

        let project = makeEntity("ProjectRecord")
        project.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("name", .stringAttributeType),
            attribute("statusRaw", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType)
        ]

        let item = makeEntity("ProjectItemRecord")
        item.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
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

        let decision = makeEntity("DecisionRecord")
        decision.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
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

        let meeting = makeEntity("MeetingRecord")
        meeting.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
            attribute("title", .stringAttributeType),
            attribute("participantEntityIDsData", .binaryDataAttributeType),
            attribute("sessionIDsData", .binaryDataAttributeType),
            attribute("occurredAt", .dateAttributeType),
            attribute("checkpointSummary", .stringAttributeType, optional: true)
        ]

        let event = makeEntity("ProjectEventRecord")
        event.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
            attribute("relatedItemID", .UUIDAttributeType),
            attribute("eventTypeRaw", .stringAttributeType),
            attribute("eventDescription", .stringAttributeType),
            attribute("occurredAt", .dateAttributeType),
            attribute("sourceSessionID", .UUIDAttributeType, optional: true),
            attribute("sourceMessageIDsData", .binaryDataAttributeType)
        ]

        let link = makeEntity("ProjectSessionLinkRecord")
        link.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("sessionID", .UUIDAttributeType),
            attribute("projectID", .UUIDAttributeType),
            attribute("assignedAt", .dateAttributeType),
            attribute("lastReassignedAt", .dateAttributeType, optional: true)
        ]

        model.entities = [project, item, decision, meeting, event, link]
        return model
    }

    func testOpeningAPreIndexOnDiskStorePreservesAllData() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("project-migration-test-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: tempURL.path + suffix)
            }
        }

        let oldContainer = NSPersistentContainer(name: "FriendlyProjects", managedObjectModel: makePreIndexModel())
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

        let projectID = UUID()
        let linkID = UUID()
        let sessionID = UUID()
        let bgContext = oldContainer.newBackgroundContext()
        let saveExpectation = expectation(description: "old data saved")
        bgContext.perform {
            let projectDesc = NSEntityDescription.entity(forEntityName: "ProjectRecord", in: bgContext)!
            let projectRecord = NSManagedObject(entity: projectDesc, insertInto: bgContext)
            projectRecord.setValue(projectID, forKey: "id")
            projectRecord.setValue("Pre-index Project", forKey: "name")
            projectRecord.setValue("active", forKey: "statusRaw")
            projectRecord.setValue(Date(), forKey: "createdAt")
            projectRecord.setValue(Date(), forKey: "updatedAt")

            let linkDesc = NSEntityDescription.entity(forEntityName: "ProjectSessionLinkRecord", in: bgContext)!
            let linkRecord = NSManagedObject(entity: linkDesc, insertInto: bgContext)
            linkRecord.setValue(linkID, forKey: "id")
            linkRecord.setValue(sessionID, forKey: "sessionID")
            linkRecord.setValue(projectID, forKey: "projectID")
            linkRecord.setValue(Date(), forKey: "assignedAt")

            try? bgContext.save()
            saveExpectation.fulfill()
        }
        wait(for: [saveExpectation], timeout: 5)

        // Release the old container's connection before opening a second coordinator on the
        // same file - see ChatSessionStoreTests/MemoryStoreTests' identical fix.
        if let oldStore = oldContainer.persistentStoreCoordinator.persistentStores.first {
            try? oldContainer.persistentStoreCoordinator.remove(oldStore)
        }

        let migratedStore = ProjectStore(storeURL: tempURL)
        let loadedProjects = migratedStore.loadAllProjects()
        let loadedLinks = migratedStore.loadAllProjectSessionLinks()

        XCTAssertEqual(loadedProjects.count, 1, "migration must not lose the project")
        XCTAssertEqual(loadedProjects.first?.id, projectID)
        XCTAssertEqual(loadedProjects.first?.name, "Pre-index Project")

        XCTAssertEqual(loadedLinks.count, 1, "migration must not lose the session link")
        XCTAssertEqual(loadedLinks.first?.sessionID, sessionID)
        XCTAssertEqual(loadedLinks.first?.projectID, projectID)

        // Confirm the migrated store is also fully writable, not just readable.
        write(migratedStore) { migratedStore.createProject(Project(name: "post-migration"), completion: $0) }
        XCTAssertEqual(migratedStore.loadAllProjects().count, 2)
    }
}
