import Foundation

// MARK: - Graph Filter
/// Filtering and search as a PURE function of (snapshot, criteria) -> snapshot. Kept out of the
/// view for the same reason the builder is: every filtering rule below is a behaviour worth
/// asserting directly, and none of them need a window to be correct.
///
/// Filtering NEVER invents nodes or edges, and never rewrites an edge's endpoints. It only ever
/// removes - so a filtered graph is always a subgraph of the full one, and an edge can never
/// survive without both of its endpoints (the invariant `GraphLayoutEngine` and the renderer
/// both rely on).
struct GraphFilterCriteria: Equatable {
    /// nil means "all projects". A specific id restricts the graph to that project's subgraph.
    var projectID: UUID?
    /// Which node kinds may appear. Empty is treated as "all", so a UI that has not yet
    /// initialised its toggles never renders an accidentally blank graph.
    var nodeKinds: Set<GraphNodeKind>
    /// Which work-item lifecycle statuses may appear (`ProjectItem.Status.rawValue`). Applies to
    /// work items ONLY - a decision has no lifecycle, and filtering by lifecycle must not
    /// silently delete every other node type.
    var lifecycleStatuses: Set<String>
    /// Case-insensitive substring over title and subtitle.
    var searchText: String

    static let unfiltered = GraphFilterCriteria(projectID: nil, nodeKinds: [], lifecycleStatuses: [], searchText: "")

    var isActive: Bool {
        projectID != nil || !nodeKinds.isEmpty || !lifecycleStatuses.isEmpty
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum GraphFilter {
    static func apply(_ criteria: GraphFilterCriteria, to snapshot: GraphSnapshot) -> GraphSnapshot {
        let query = criteria.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var survivors = snapshot.nodes.filter { node in
            matchesProject(node, criteria: criteria, snapshot: snapshot)
                && matchesKind(node, criteria: criteria)
                && matchesLifecycle(node, criteria: criteria)
                && matchesSearch(node, query: query)
        }

        // People are RELATIONAL, not owned by a project, so they carry no `projectID` and would
        // be filtered out of every project view by the project rule alone - taking their
        // "made by"/"assigned to" edges with them and quietly changing what the graph claims
        // about who decided what. Instead a person is kept exactly when some other surviving
        // node still points at them. Search and kind filters still apply normally: an explicitly
        // hidden or unmatched person stays hidden.
        if criteria.projectID != nil {
            let survivingIDs = Set(survivors.map(\.id))
            let reachablePeople = snapshot.edges
                .filter { survivingIDs.contains($0.source) && $0.destination.kind == .person }
                .map(\.destination)
            let keep = Set(reachablePeople)
            let people = snapshot.nodes.filter {
                $0.kind == .person && keep.contains($0.id)
                    && matchesKind($0, criteria: criteria) && matchesSearch($0, query: query)
            }
            survivors.append(contentsOf: people.filter { person in !survivors.contains(where: { $0.id == person.id }) })
            survivors.sort { $0.id < $1.id }
        }

        let survivingIDs = Set(survivors.map(\.id))
        let survivingEdges = snapshot.edges.filter {
            survivingIDs.contains($0.source) && survivingIDs.contains($0.destination)
        }

        // Integrity issues follow their subject: hiding a node must not leave an orphaned
        // warning about something the user can no longer see, but a visible node's problem must
        // never be filtered out of sight either.
        let survivingIssues = snapshot.integrityIssues.filter { survivingIDs.contains($0.subject) }

        return GraphSnapshot(
            nodes: survivors,
            edges: survivingEdges,
            integrityIssues: survivingIssues,
            projectNames: snapshot.projectNames
        )
    }

    private static func matchesProject(_ node: GraphNode, criteria: GraphFilterCriteria, snapshot: GraphSnapshot) -> Bool {
        guard let projectID = criteria.projectID else { return true }
        return node.projectID == projectID
    }

    private static func matchesKind(_ node: GraphNode, criteria: GraphFilterCriteria) -> Bool {
        criteria.nodeKinds.isEmpty || criteria.nodeKinds.contains(node.kind)
    }

    private static func matchesLifecycle(_ node: GraphNode, criteria: GraphFilterCriteria) -> Bool {
        guard !criteria.lifecycleStatuses.isEmpty else { return true }
        // Only work items carry a lifecycle. Everything else is exempt rather than excluded -
        // filtering to "completed" should narrow the work items, not empty the graph of
        // projects, decisions, sessions and people that have no status at all.
        guard node.kind == .projectItem, let status = node.lifecycleStatus else { return true }
        return criteria.lifecycleStatuses.contains(status)
    }

    private static func matchesSearch(_ node: GraphNode, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if node.title.lowercased().contains(query) { return true }
        return node.subtitle?.lowercased().contains(query) ?? false
    }
}
