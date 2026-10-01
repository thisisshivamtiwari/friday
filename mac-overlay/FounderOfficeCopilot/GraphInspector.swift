import SwiftUI

// MARK: - Graph Inspector
/// Detail for the selected node, plus the data-integrity report.
///
/// Every field shown here is read from a real persisted property. Where a value is genuinely
/// absent the row is OMITTED rather than filled with a placeholder or an invented default -
/// "no reason recorded" and "reason: N/A" say different things, and only the first is honest.
struct GraphInspector: View {
    @ObservedObject var model: GraphViewModel
    /// Hands a node to the workspace's universal entity inspector.
    var openEntity: ((EntityReference) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selection = model.selection, let node = model.visibleSnapshot.node(selection) {
                    header(node)
                    if let openEntity, let reference = node.entityReference {
                        Button {
                            openEntity(reference)
                        } label: {
                            Label("Open details", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityHint("Open this in the workspace inspector")
                    }
                    detail(for: node)
                    relationships(of: node)
                } else {
                    placeholder
                }
                integritySection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Header

    private func header(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.kind.displayName.uppercased())
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            Text(node.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let status = node.lifecycleStatus {
                Text(status).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            }
            if let project = model.projectName(node.projectID), node.kind != .project {
                Text(project).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing selected").font(.system(size: 13, weight: .semibold))
            Text("Select a node in the graph, or from the node list on the left, to see everything stored about it.")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Per-kind detail

    @ViewBuilder
    private func detail(for node: GraphNode) -> some View {
        switch node.kind {
        case .project: projectDetail(node)
        case .projectItem: itemDetail(node)
        case .decision: decisionDetail(node)
        case .session: sessionDetail(node)
        case .person: personDetail(node)
        }
    }

    private func projectDetail(_ node: GraphNode) -> some View {
        let projectID = node.id.entityID
        let items = model.fullSnapshot.nodes.filter { $0.kind == .projectItem && $0.projectID == projectID }
        let decisions = model.fullSnapshot.nodes.filter { $0.kind == .decision && $0.projectID == projectID }
        let sessions = model.fullSnapshot.nodes.filter { $0.kind == .session && $0.projectID == projectID }
        // Lifecycle breakdown, sorted for a stable order rather than dictionary order.
        let byStatus = Dictionary(grouping: items.compactMap(\.lifecycleStatus), by: { $0 })
            .map { (status: $0.key, count: $0.value.count) }
            .sorted { $0.status < $1.status }

        return VStack(alignment: .leading, spacing: 10) {
            section("Contents") {
                field("Work items", "\(items.count)")
                field("Decisions", "\(decisions.count)")
                field("Sessions", "\(sessions.count)")
                if let status = node.subtitle { field("Status", status) }
            }
            if !byStatus.isEmpty {
                section("Lifecycle") {
                    ForEach(byStatus, id: \.status) { entry in field(entry.status, "\(entry.count)") }
                }
            }
            let events = model.recentEvents(forProject: projectID)
            if !events.isEmpty {
                section("Recent activity") {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.description).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func itemDetail(_ node: GraphNode) -> some View {
        let item = model.projectItem(node.id.entityID)
        return VStack(alignment: .leading, spacing: 10) {
            section("Details") {
                if let kind = item?.kind.rawValue { field("Kind", kind) }
                if let status = item?.status.rawValue { field("Status", status) }
                if let description = item?.description, !description.isEmpty {
                    field("Description", description)
                }
                if let assignee = item?.assignedTo, let name = model.personName(assignee) {
                    field("Assigned to", name)
                }
                if let confidence = item?.confidence { field("Confidence", String(format: "%.2f", confidence)) }
                if let updated = item?.lastUpdatedAt {
                    field("Last updated", updated.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    private func decisionDetail(_ node: GraphNode) -> some View {
        let decision = model.decision(node.id.entityID)
        return VStack(alignment: .leading, spacing: 10) {
            section("Details") {
                if let context = decision?.context, !context.isEmpty { field("Context", context) }
                if let reason = decision?.reason, !reason.isEmpty { field("Reason", reason) }
                if let status = decision?.status.rawValue { field("Status", status) }
                if let decidedAt = decision?.decidedAt {
                    field("Decided", decidedAt.formatted(date: .abbreviated, time: .shortened))
                }
                let people = (decision?.madeBy ?? []).compactMap(model.personName)
                if !people.isEmpty { field("Made by", people.joined(separator: ", ")) }
            }

            // The Phase 4.3 relationship, stated explicitly in both directions - including when
            // it is absent, because "no linked work item" is a real and meaningful answer here
            // rather than a gap to hide.
            section("Linked work item") {
                if let relatedID = decision?.relatedItemID {
                    if let item = model.projectItem(relatedID) {
                        Text(item.name).font(.system(size: 11))
                        Text(item.status.rawValue).font(.system(size: 10)).foregroundColor(.secondary)
                    } else {
                        Text("Linked to a work item that no longer exists")
                            .font(.system(size: 11)).foregroundColor(.orange)
                    }
                } else {
                    Text("Not linked to a tracked work item")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            if let supersedes = decision?.supersedes, let old = model.decision(supersedes) {
                section("Supersedes") { Text(old.statement).font(.system(size: 11)) }
            }
            if let supersededBy = decision?.supersededBy, let newer = model.decision(supersededBy) {
                section("Superseded by") { Text(newer.statement).font(.system(size: 11)) }
            }
        }
    }

    private func sessionDetail(_ node: GraphNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Details") {
                if let date = node.subtitle { field("Date", date) }
                if let count = model.messageCount(forSession: node.id.entityID) { field("Messages", "\(count)") }
                if let project = model.projectName(node.projectID) {
                    field("Project", project)
                } else {
                    field("Project", "Not linked")
                }
            }
        }
    }

    private func personDetail(_ node: GraphNode) -> some View {
        let decisions = model.fullSnapshot.edges.filter {
            $0.kind == .decisionMadeByPerson && $0.destination == node.id
        }
        let assignments = model.fullSnapshot.edges.filter {
            $0.kind == .itemAssignedToPerson && $0.destination == node.id
        }
        return section("Involvement") {
            field("Decisions made", "\(decisions.count)")
            field("Items assigned", "\(assignments.count)")
        }
    }

    // MARK: Relationships

    private func relationships(of node: GraphNode) -> some View {
        let edges = model.visibleSnapshot.edges(touching: node.id)
        return Group {
            if edges.isEmpty {
                section("Relationships") {
                    Text("No relationships in the current view").font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                section("Relationships (\(edges.count))") {
                    ForEach(edges) { edge in
                        let isOutgoing = edge.source == node.id
                        let otherID = isOutgoing ? edge.destination : edge.source
                        Button {
                            model.selection = otherID
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isOutgoing ? "arrow.right" : "arrow.left")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(edge.kind.displayName).font(.system(size: 9)).foregroundColor(.secondary)
                                    Text(model.visibleSnapshot.node(otherID)?.title ?? "—")
                                        .font(.system(size: 11)).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("\(edge.kind.displayName) \(model.visibleSnapshot.node(otherID)?.title ?? "")")
                        .accessibilityHint("Select this related node")
                    }
                }
            }
        }
    }

    // MARK: Integrity

    @ViewBuilder
    private var integritySection: some View {
        let issues = model.visibleSnapshot.integrityIssues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Data integrity (\(issues.count))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                // Surfaced, never silently repaired: the graph refuses to draw these
                // relationships, and says so rather than quietly dropping them.
                ForEach(issues) { issue in
                    Button { model.selection = issue.subject } label: {
                        Text(issue.detail)
                            .font(.system(size: 10)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
