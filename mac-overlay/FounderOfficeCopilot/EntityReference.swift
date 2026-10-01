import Foundation

// MARK: - Entity Reference
/// One addressable thing in the workspace. This is the app's navigation currency: a source, a
/// graph node and a search result all reduce to this, so every surface can hand off to every
/// other surface without knowing anything about it.
struct EntityReference: Identifiable, Equatable {
    enum Kind: Equatable {
        case project(UUID)
        case workItem(UUID)
        case decision(UUID)
        case person(UUID)
        case conversation(UUID)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .project(let id): return "project-\(id)"
        case .workItem(let id): return "item-\(id)"
        case .decision(let id): return "decision-\(id)"
        case .person(let id): return "person-\(id)"
        case .conversation(let id): return "conversation-\(id)"
        }
    }

    init(kind: Kind) { self.kind = kind }

    /// Built from a chat source. The mapping reads the retrieval layer's OWN typed
    /// `EvidenceSource`, so a source can only ever open the entity it genuinely pointed at -
    /// there is no name-matching or guessing anywhere in this path.
    /// The graph node this entity corresponds to, when the graph models that type. People,
    /// work items, decisions, projects and sessions are all nodes; anything else returns nil and
    /// simply has no "Open in graph" action rather than opening the wrong thing.
    var graphNodeID: GraphNodeID? {
        switch kind {
        case .project(let id): return GraphNodeID(kind: .project, entityID: id)
        case .workItem(let id): return GraphNodeID(kind: .projectItem, entityID: id)
        case .decision(let id): return GraphNodeID(kind: .decision, entityID: id)
        case .person(let id): return GraphNodeID(kind: .person, entityID: id)
        case .conversation(let id): return GraphNodeID(kind: .session, entityID: id)
        }
    }

    init?(_ reference: AnswerSource) {
        // No retrieval identifier means the source did not come from retrieval (the screen
        // capture). It is shown, but it is not an entity, so it is not navigable.
        guard let evidenceSource = reference.source else { return nil }
        switch evidenceSource {
        case .decision(let id): kind = .decision(id)
        case .projectItem(let id): kind = .workItem(id)
        case .chatMessage(let sessionID, _): kind = .conversation(sessionID)
        case .episode(let sessionID): kind = .conversation(sessionID)
        case .memoryEdge, .projectEvent:
            // A remembered fact and a project event are real evidence, but neither has a
            // dedicated screen in this MVP. Returning nil makes the row non-navigable rather
            // than opening something that only approximately corresponds to it.
            return nil
        }
    }
}
