import SwiftUI

// MARK: - Entity Inspector Sheet

/// ONE inspector for every entity type, rather than six unrelated detail views. Each kind
/// supplies a title, a status, its fields and its real relationships; the chrome, the layout and
/// the navigation affordances are shared, so an entity looks the same wherever it is reached
/// from.
struct EntityInspectorSheet: View {
    @ObservedObject var workspace: WorkspaceModel
    let entity: EntityReference
    /// Navigate the main window to a destination (and optionally focus a project), closing this.
    let navigate: (WorkspaceDestination, UUID?) -> Void
    /// Show this entity's node in the knowledge graph, selected and centred.
    let openInGraph: (EntityReference) -> Void
    /// Start a Chat question about this entity. The prompt is SEEDED, not sent: the user stays
    /// in control of what is actually asked, and can edit it first.
    let askAI: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    content
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
        .background(DS.Surface.canvas)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(kindLabel.uppercased()).font(DS.Font.metadata).foregroundColor(.secondary)
                Text(title).font(DS.Font.title).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Close")
        }
        .padding(DS.Space.l)
    }

    // MARK: Per-kind content

    @ViewBuilder
    private var content: some View {
        switch entity.kind {
        case .decision(let id): decisionContent(id)
        case .workItem(let id): workItemContent(id)
        case .project(let id): projectContent(id)
        case .person(let id): personContent(id)
        case .conversation(let id): conversationContent(id)
        }
    }

    @ViewBuilder
    private func decisionContent(_ id: UUID) -> some View {
        if let decision = workspace.projects.decision(id: id) {
            if let reason = decision.reason, !reason.isEmpty {
                section("Why") { Text(reason).font(DS.Font.body).fixedSize(horizontal: false, vertical: true) }
            }
            section("Details") {
                DetailField(label: "Project", value: workspace.projectName(decision.projectID))
                DetailField(label: "Concerns", value: decision.context)
                DetailField(label: "Decided", value: decision.decidedAt.formatted(date: .abbreviated, time: .shortened))
                DetailField(label: "Made by", value: decision.madeBy.compactMap(workspace.personName).joined(separator: ", "))
                DetailField(label: "From", value: workspace.sessionTitle(decision.sourceSessionID))
            }
            section("Related work") {
                if let item = workspace.item(decision.relatedItemID) {
                    entityLink(.init(kind: .workItem(item.id)), title: item.name,
                               subtitle: DS.lifecycleLabel(item.status))
                } else if decision.relatedItemID != nil {
                    Text("Linked to a work item that no longer exists.")
                        .font(DS.Font.callout).foregroundColor(.orange)
                } else {
                    // The honest answer. Never inferred from similar wording.
                    Text("Not linked to a tracked work item.").font(DS.Font.callout).foregroundColor(.secondary)
                }
            }
            actions(projectID: decision.projectID)
        } else {
            missing
        }
    }

    @ViewBuilder
    private func workItemContent(_ id: UUID) -> some View {
        if let item = workspace.projects.projectItem(id: id) {
            StatusBadge(text: DS.lifecycleLabel(item.status), tint: DS.lifecycleTint(item.status))
            section("Details") {
                DetailField(label: "Kind", value: item.kind.rawValue)
                DetailField(label: "Project", value: workspace.projectName(item.projectID))
                DetailField(label: "Description", value: item.description)
                DetailField(label: "Owner", value: item.assignedTo.flatMap(workspace.personName))
                DetailField(label: "Updated", value: item.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                DetailField(label: "From", value: workspace.sessionTitle(item.sourceSessionID))
            }
            let related = workspace.decisions(referencing: item.id)
            section("Decisions about this") {
                if related.isEmpty {
                    Text("No decisions recorded about this work.").font(DS.Font.callout).foregroundColor(.secondary)
                } else {
                    ForEach(related) { decision in
                        entityLink(.init(kind: .decision(decision.id)), title: decision.statement,
                                   subtitle: decision.decidedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
            actions(projectID: item.projectID)
        } else {
            missing
        }
    }

    @ViewBuilder
    private func projectContent(_ id: UUID) -> some View {
        if let project = workspace.project(id) {
            section("Contents") {
                DetailField(label: "Status", value: project.status.rawValue)
                DetailField(label: "Work items", value: "\(workspace.items(in: id).count)")
                DetailField(label: "Open", value: "\(workspace.openItems(in: id).count)")
                DetailField(label: "Decisions", value: "\(workspace.decisions(in: id).count)")
            }
            actions(projectID: id)
        } else {
            missing
        }
    }

    @ViewBuilder
    private func personContent(_ id: UUID) -> some View {
        let decisions = workspace.allDecisions.filter { $0.madeBy.contains(id) }
        let owned = workspace.projects.items.filter { $0.assignedTo == id }
        section("Involvement") {
            DetailField(label: "Decisions", value: "\(decisions.count)")
            DetailField(label: "Work items", value: "\(owned.count)")
        }
        actions(projectID: nil)
        if !decisions.isEmpty {
            section("Decisions made") {
                ForEach(decisions.prefix(6)) { decision in
                    entityLink(.init(kind: .decision(decision.id)), title: decision.statement,
                               subtitle: workspace.projectName(decision.projectID))
                }
            }
        }
    }

    @ViewBuilder
    private func conversationContent(_ id: UUID) -> some View {
        if let session = workspace.sessions.sessions.first(where: { $0.id == id }) {
            section("Details") {
                DetailField(label: "Messages", value: "\(session.messages.count)")
                DetailField(label: "Last activity", value: (session.lastMessageAt ?? session.updatedAt).formatted(date: .abbreviated, time: .shortened))
                DetailField(label: "Project", value: workspace.projects.project(forSession: id).flatMap(workspace.projectName) ?? "Not linked")
            }
            actions(projectID: workspace.projects.project(forSession: id))
            section("Transcript") {
                ForEach(session.messages.suffix(6)) { message in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.role == .heard ? "HEARD" : "COPILOT")
                            .font(DS.Font.metadata).foregroundColor(.secondary)
                        Text(message.text).font(DS.Font.callout)
                            .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, DS.Space.xs)
                }
            }
        } else {
            missing
        }
    }

    // MARK: Building blocks

    private var missing: some View {
        Text("This item is no longer in your workspace.")
            .font(DS.Font.body).foregroundColor(.secondary)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title)
            content()
        }
    }

    /// A navigable reference to another entity - the mechanism behind
    /// decision → work item → project → person traversal.
    private func entityLink(_ target: EntityReference, title: String, subtitle: String?) -> some View {
        Button {
            switch target.kind {
            case .workItem(let id):
                navigate(.work, workspace.projects.projectItem(id: id)?.projectID)
            case .decision(let id):
                navigate(.decisions, workspace.projects.decision(id: id)?.projectID)
            case .project(let id): navigate(.projects, id)
            case .person: navigate(.people, nil)
            case .conversation: navigate(.home, nil)
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(DS.Font.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(DS.Font.caption).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(DS.Font.caption).foregroundColor(.secondary)
            }
            .padding(DS.Space.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small).fill(DS.Surface.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open")
    }

    private func actions(projectID: UUID?) -> some View {
        HStack(spacing: DS.Space.s) {
            Button {
                askAI(askPrompt)
            } label: {
                Label("Ask AI about this", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Start a question about this in Chat")

            if entity.graphNodeID != nil {
                Button {
                    openInGraph(entity)
                } label: {
                    Label("Open in graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                }
                .accessibilityHint("Show this in the knowledge graph")
            }
            if let projectID {
                Button("Open project") { navigate(.projects, projectID) }
            }
            Spacer()
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.top, DS.Space.xs)
    }

    /// The seeded question. Phrased as the founder would ask it, and naming the entity exactly,
    /// so retrieval's own lexical matching has the best chance of finding it.
    private var askPrompt: String {
        switch entity.kind {
        case .decision: return "Why did we decide: \(title)?"
        case .workItem: return "What is the current state of \(title)?"
        case .project: return "What is happening in \(title)?"
        case .person: return "What has \(title) been involved in?"
        case .conversation: return "What was discussed in \(title)?"
        }
    }

    private var kindLabel: String {
        switch entity.kind {
        case .project: return "Project"
        case .workItem: return "Work item"
        case .decision: return "Decision"
        case .person: return "Person"
        case .conversation: return "Conversation"
        }
    }

    private var title: String {
        switch entity.kind {
        case .project(let id): return workspace.project(id)?.name ?? "Unknown project"
        case .workItem(let id): return workspace.projects.projectItem(id: id)?.name ?? "Unknown work item"
        case .decision(let id): return workspace.projects.decision(id: id)?.statement ?? "Unknown decision"
        case .person(let id): return workspace.personName(id) ?? "Unknown person"
        case .conversation(let id): return workspace.sessionTitle(id) ?? "Conversation"
        }
    }
}
