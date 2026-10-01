import Foundation

// MARK: - Graph Snapshot Builder
/// The ONE place persisted state becomes a graph. Pure and static: it takes plain arrays in and
/// returns a `GraphSnapshot`, so it can be tested exhaustively with no store, no UI, no
/// `ProjectManager` and no main actor. `GraphViewModel` is the only thing that knows where the
/// arrays come from.
///
/// TWO RULES GOVERN EVERYTHING HERE.
///
/// 1. NEVER FABRICATE AN EDGE. Every edge comes from a field that literally holds the other
///    end's id. Nothing is inferred from names, text similarity, timestamps or co-occurrence.
///    In particular a `Decision` with `relatedItemID == nil` produces NO
///    `decisionRelatesToItem` edge - the absence of a link is information, and drawing a
///    plausible-looking one would destroy the only evidence that Phase 4.3 linking works.
///
/// 2. NEVER SILENTLY REPAIR. A `relatedItemID` that dangles, or that resolves into a different
///    project, is a data-integrity failure. It becomes a `GraphIntegrityIssue` and NO edge -
///    it is never coerced into the "nearest" valid target and never dropped without trace.
enum GraphSnapshotBuilder {

    /// `people` is `MemoryEntity` rows; only `.person`/`.self` kinds are projected, since those
    /// are the only ones `Decision.madeBy` and `ProjectItem.assignedTo` ever reference.
    /// `sessionTitles` and `sessionDates` come from `ChatSessionManager`, keyed by session id -
    /// passed as plain dictionaries rather than whole `ChatSession` values so this file never
    /// needs to know about message storage.
    static func build(
        projects: [Project],
        items: [ProjectItem],
        decisions: [Decision],
        sessionLinks: [ProjectSessionLink],
        people: [MemoryEntity],
        sessionTitles: [UUID: String],
        sessionDates: [UUID: Date]
    ) -> GraphSnapshot {
        var nodes: [GraphNode] = []
        // A Set keyed by `GraphEdgeID` makes duplicate prevention structural: the same
        // relationship discovered twice collapses to one entry with no de-dup pass to forget.
        var edges: Set<GraphEdge> = []
        var issues: [GraphIntegrityIssue] = []

        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let decisionsByID = Dictionary(decisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let peopleByID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // MARK: Projects
        for project in projects {
            nodes.append(GraphNode(
                id: GraphNodeID(kind: .project, entityID: project.id),
                title: project.name,
                subtitle: project.status.rawValue,
                lifecycleStatus: nil,
                projectID: project.id
            ))
        }

        // MARK: Work items
        for item in items {
            let node = GraphNodeID(kind: .projectItem, entityID: item.id)
            nodes.append(GraphNode(
                id: node,
                title: item.name,
                subtitle: item.kind.rawValue,
                lifecycleStatus: item.status.rawValue,
                projectID: item.projectID
            ))

            if projectsByID[item.projectID] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .projectContainsItem, source: GraphNodeID(kind: .project, entityID: item.projectID), destination: node),
                    projectID: item.projectID
                ))
            } else {
                issues.append(GraphIntegrityIssue(
                    id: "orphan-item-\(item.id.uuidString)", kind: .orphanedProjectReference, subject: node,
                    detail: "Work item \"\(item.name)\" names a project that does not exist."
                ))
            }

            // ProjectItem -> ProjectItem, same integrity rules as the decision link below.
            if let relatedID = item.relatedItemID {
                switch resolveItemLink(relatedID, ownerProjectID: item.projectID, itemsByID: itemsByID) {
                case .valid:
                    edges.insert(GraphEdge(
                        id: GraphEdgeID(kind: .itemRelatesToItem, source: node, destination: GraphNodeID(kind: .projectItem, entityID: relatedID)),
                        projectID: item.projectID
                    ))
                case .dangling:
                    issues.append(GraphIntegrityIssue(
                        id: "dangling-item-link-\(item.id.uuidString)", kind: .danglingRelatedItem, subject: node,
                        detail: "Work item \"\(item.name)\" points at a related item that no longer exists."
                    ))
                case .crossProject(let otherProjectID):
                    issues.append(GraphIntegrityIssue(
                        id: "cross-project-item-link-\(item.id.uuidString)", kind: .crossProjectRelatedItem, subject: node,
                        detail: "Work item \"\(item.name)\" points at an item in \(name(of: otherProjectID, in: projectsByID)) - project isolation violation."
                    ))
                }
            }

            if let assignee = item.assignedTo, peopleByID[assignee] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .itemAssignedToPerson, source: node, destination: GraphNodeID(kind: .person, entityID: assignee)),
                    projectID: item.projectID
                ))
            }

            if sessionTitles[item.sourceSessionID] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .itemDiscussedInSession, source: node, destination: GraphNodeID(kind: .session, entityID: item.sourceSessionID)),
                    projectID: item.projectID
                ))
            }
        }

        // MARK: Decisions
        for decision in decisions {
            let node = GraphNodeID(kind: .decision, entityID: decision.id)
            nodes.append(GraphNode(
                id: node,
                title: decision.statement,
                subtitle: decision.context,
                lifecycleStatus: nil,
                projectID: decision.projectID
            ))

            if projectsByID[decision.projectID] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .projectHasDecision, source: GraphNodeID(kind: .project, entityID: decision.projectID), destination: node),
                    projectID: decision.projectID
                ))
            } else {
                issues.append(GraphIntegrityIssue(
                    id: "orphan-decision-\(decision.id.uuidString)", kind: .orphanedProjectReference, subject: node,
                    detail: "Decision \"\(decision.statement)\" names a project that does not exist."
                ))
            }

            // THE PHASE 4.3 EDGE. nil means nil: no link, no edge, no inference.
            if let relatedID = decision.relatedItemID {
                switch resolveItemLink(relatedID, ownerProjectID: decision.projectID, itemsByID: itemsByID) {
                case .valid:
                    edges.insert(GraphEdge(
                        id: GraphEdgeID(kind: .decisionRelatesToItem, source: node, destination: GraphNodeID(kind: .projectItem, entityID: relatedID)),
                        projectID: decision.projectID
                    ))
                case .dangling:
                    issues.append(GraphIntegrityIssue(
                        id: "dangling-decision-link-\(decision.id.uuidString)", kind: .danglingRelatedItem, subject: node,
                        detail: "Decision \"\(decision.statement)\" is linked to a work item that no longer exists."
                    ))
                case .crossProject(let otherProjectID):
                    issues.append(GraphIntegrityIssue(
                        id: "cross-project-decision-link-\(decision.id.uuidString)", kind: .crossProjectRelatedItem, subject: node,
                        detail: "Decision \"\(decision.statement)\" is linked to a work item in \(name(of: otherProjectID, in: projectsByID)) - project isolation violation."
                    ))
                }
            }

            for personID in decision.madeBy where peopleByID[personID] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .decisionMadeByPerson, source: node, destination: GraphNodeID(kind: .person, entityID: personID)),
                    projectID: decision.projectID
                ))
            }

            // Supersession is directional and recorded on BOTH rows; normalising to a single
            // "newer supersedes older" direction is what stops one chain producing two
            // opposite-facing edges.
            if let supersededID = decision.supersedes {
                if decisionsByID[supersededID] != nil {
                    edges.insert(GraphEdge(
                        id: GraphEdgeID(kind: .decisionSupersedesDecision, source: node, destination: GraphNodeID(kind: .decision, entityID: supersededID)),
                        projectID: decision.projectID
                    ))
                } else {
                    issues.append(GraphIntegrityIssue(
                        id: "dangling-supersedes-\(decision.id.uuidString)", kind: .danglingSupersession, subject: node,
                        detail: "Decision \"\(decision.statement)\" supersedes a decision that no longer exists."
                    ))
                }
            }
            if let supersededByID = decision.supersededBy {
                if decisionsByID[supersededByID] != nil {
                    edges.insert(GraphEdge(
                        id: GraphEdgeID(kind: .decisionSupersedesDecision, source: GraphNodeID(kind: .decision, entityID: supersededByID), destination: node),
                        projectID: decision.projectID
                    ))
                } else {
                    issues.append(GraphIntegrityIssue(
                        id: "dangling-supersededby-\(decision.id.uuidString)", kind: .danglingSupersession, subject: node,
                        detail: "Decision \"\(decision.statement)\" claims to be superseded by a decision that no longer exists."
                    ))
                }
            }

            if sessionTitles[decision.sourceSessionID] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .decisionDiscussedInSession, source: node, destination: GraphNodeID(kind: .session, entityID: decision.sourceSessionID)),
                    projectID: decision.projectID
                ))
            }
        }

        // MARK: Sessions
        //
        // Only sessions that actually participate in the project graph are projected - a linked
        // session, or one that some item/decision cites as its source. The app can hold hundreds
        // of unrelated chat sessions and rendering all of them would bury the project structure
        // in nodes with exactly zero project relationships.
        let linkedProjectBySession = Dictionary(sessionLinks.map { ($0.sessionID, $0.projectID) }, uniquingKeysWith: { first, _ in first })
        var participatingSessions = Set(linkedProjectBySession.keys)
        participatingSessions.formUnion(items.map(\.sourceSessionID))
        participatingSessions.formUnion(decisions.map(\.sourceSessionID))

        for sessionID in participatingSessions.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let title = sessionTitles[sessionID] else { continue }
            let node = GraphNodeID(kind: .session, entityID: sessionID)
            nodes.append(GraphNode(
                id: node,
                title: title,
                subtitle: sessionDates[sessionID].map(Self.dateFormatter.string(from:)),
                lifecycleStatus: nil,
                projectID: linkedProjectBySession[sessionID]
            ))

            if let projectID = linkedProjectBySession[sessionID], projectsByID[projectID] != nil {
                edges.insert(GraphEdge(
                    id: GraphEdgeID(kind: .projectLinkedToSession, source: GraphNodeID(kind: .project, entityID: projectID), destination: node),
                    projectID: projectID
                ))
            }
        }

        // MARK: People
        //
        // Same participation rule: only people some decision or item actually references. The
        // memory graph holds people who have nothing to do with any project, and they are not
        // project-graph nodes.
        var participatingPeople = Set(decisions.flatMap(\.madeBy))
        participatingPeople.formUnion(items.compactMap(\.assignedTo))

        for personID in participatingPeople.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let person = peopleByID[personID] else { continue }
            nodes.append(GraphNode(
                id: GraphNodeID(kind: .person, entityID: person.id),
                title: person.name,
                subtitle: nil,
                lifecycleStatus: nil,
                // Deliberately nil: a person is not owned by a project and may appear in
                // several. Project filtering keeps a person visible whenever any surviving edge
                // still reaches them - see `GraphFilter`.
                projectID: nil
            ))
        }

        // Sorting is what makes the output ORDER deterministic, not just its content. Dictionary
        // and Set iteration order is unspecified and varies between runs, so any edge or node
        // that passed through one above must be re-ordered before it leaves.
        return GraphSnapshot(
            nodes: nodes.sorted { $0.id < $1.id },
            edges: edges.sorted(by: edgeOrdering),
            integrityIssues: issues.sorted { $0.id < $1.id },
            projectNames: projectsByID.mapValues(\.name)
        )
    }

    // MARK: Link resolution

    private enum ItemLinkResolution {
        case valid
        case dangling
        case crossProject(UUID)
    }

    /// The single gate every `relatedItemID` passes through, for decisions and items alike, so
    /// the two can never drift into different definitions of a valid link.
    private static func resolveItemLink(_ relatedID: UUID, ownerProjectID: UUID, itemsByID: [UUID: ProjectItem]) -> ItemLinkResolution {
        guard let target = itemsByID[relatedID] else { return .dangling }
        guard target.projectID == ownerProjectID else { return .crossProject(target.projectID) }
        return .valid
    }

    private static func name(of projectID: UUID, in projects: [UUID: Project]) -> String {
        projects[projectID].map { "\"\($0.name)\"" } ?? "another project"
    }

    private static func edgeOrdering(_ lhs: GraphEdge, _ rhs: GraphEdge) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        return lhs.destination < rhs.destination
    }

    /// Fixed locale/timezone-independent-enough short format. Static so the (expensive)
    /// formatter is built once rather than per session node.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
