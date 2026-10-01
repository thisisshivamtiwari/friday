import SwiftUI

// MARK: - Work
/// Cross-project work list. Grouped by lifecycle rather than by project, because the question
/// this screen answers is "what is in flight / stuck / done", not "what belongs where" - the
/// Projects screen already answers the latter.
struct WorkView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var selectedItemID: UUID?
    @State private var showCompleted = false

    var body: some View {
        let items = showCompleted ? workspace.projects.items.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt } : workspace.allOpenWork
        Group {
            if workspace.projects.items.isEmpty {
                EmptyStateView(icon: "checklist", title: "No work tracked yet",
                               message: "Tasks, experiments and open questions appear here as they come up in your conversations.")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(showCompleted ? "All work" : "Open work").font(DS.Font.headline)
                        Text("\(items.count)").font(DS.Font.caption).foregroundColor(.secondary).monospacedDigit()
                        Spacer()
                        Toggle("Show completed", isOn: $showCompleted)
                            .toggleStyle(.switch).controlSize(.small).font(DS.Font.caption)
                    }
                    .padding(DS.Space.l)
                    Divider()
                    WorkList(workspace: workspace, items: items, selectedItemID: $selectedItemID)
                }
                .background(DS.Surface.canvas)
            }
        }
    }
}

/// Shared between the Work screen and a project's Work tab, so a work item looks and behaves
/// identically wherever it is encountered.
struct WorkList: View {
    @ObservedObject var workspace: WorkspaceModel
    let items: [ProjectItem]
    @Binding var selectedItemID: UUID?

    var body: some View {
        if items.isEmpty {
            EmptyStateView(icon: "checkmark.circle", title: "Nothing open",
                           message: "All tracked work here is complete.")
        } else {
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: DS.stackSpacing) {
                        ForEach(items) { item in
                            Button { selectedItemID = item.id } label: {
                                WorkRowCard(workspace: workspace, item: item, isSelected: selectedItemID == item.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(DS.Space.l)
                }
                .frame(minWidth: 340)

                Group {
                    if let id = selectedItemID, let item = items.first(where: { $0.id == id }) ?? workspace.item(id) {
                        WorkItemInspector(workspace: workspace, item: item)
                    } else {
                        EmptyStateView(icon: "sidebar.right", title: "Select a work item",
                                       message: "See its status, the decisions about it and where it came from.")
                    }
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
    }
}

struct WorkRowCard: View {
    @ObservedObject var workspace: WorkspaceModel
    let item: ProjectItem
    var isSelected: Bool = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(item.name).font(DS.Font.body).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.s) {
                        StatusBadge(text: DS.lifecycleLabel(item.status), tint: DS.lifecycleTint(item.status))
                        Text(item.kind.rawValue).font(DS.Font.caption).foregroundColor(.secondary)
                        if let project = workspace.projectName(item.projectID) {
                            Text("· \(project)").font(DS.Font.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                let linked = workspace.decisions(referencing: item.id).count
                if linked > 0 {
                    Label("\(linked)", systemImage: "checkmark.seal")
                        .font(DS.Font.caption).foregroundColor(.secondary)
                        .help("\(linked) decision\(linked == 1 ? "" : "s") about this work")
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(DS.lifecycleLabel(item.status))")
    }
}

/// Everything stored about one work item, including the reverse of the Decision link - which
/// only exists on the decision side in the model, so this is the one place the user can see it
/// from the work item's perspective.
struct WorkItemInspector: View {
    @ObservedObject var workspace: WorkspaceModel
    let item: ProjectItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("WORK ITEM").font(DS.Font.metadata).foregroundColor(.secondary)
                    Text(item.name).font(DS.Font.headline).fixedSize(horizontal: false, vertical: true)
                    StatusBadge(text: DS.lifecycleLabel(item.status), tint: DS.lifecycleTint(item.status))
                }

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SectionHeader("Details")
                    DetailField(label: "Kind", value: item.kind.rawValue)
                    DetailField(label: "Project", value: workspace.projectName(item.projectID))
                    DetailField(label: "Description", value: item.description)
                    DetailField(label: "Owner", value: item.assignedTo.flatMap(workspace.personName))
                    DetailField(label: "Updated", value: item.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                    DetailField(label: "From", value: workspace.sessionTitle(item.sourceSessionID))
                }

                let related = workspace.decisions(referencing: item.id)
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SectionHeader("Decisions about this")
                    if related.isEmpty {
                        Text("No decisions recorded about this work.")
                            .font(DS.Font.callout).foregroundColor(.secondary)
                    } else {
                        ForEach(related) { decision in
                            Card(padding: DS.Space.s) {
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(decision.statement).font(DS.Font.callout).fixedSize(horizontal: false, vertical: true)
                                    Text(decision.decidedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(DS.Font.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.l)
        }
        .background(DS.Surface.sidebar)
    }
}

// MARK: - Decisions

struct DecisionsView: View {
    @ObservedObject var workspace: WorkspaceModel
    @State private var selectedDecisionID: UUID?

    var body: some View {
        Group {
            if workspace.allDecisions.isEmpty {
                EmptyStateView(icon: "checkmark.seal", title: "No decisions captured yet",
                               message: "When you settle on an approach in a meeting, it is recorded here with its reasoning, the work it affects and who made it.")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Decisions").font(DS.Font.headline)
                        Text("\(workspace.allDecisions.count)").font(DS.Font.caption).foregroundColor(.secondary).monospacedDigit()
                        Spacer()
                    }
                    .padding(DS.Space.l)
                    Divider()
                    DecisionList(workspace: workspace, decisions: workspace.allDecisions, selectedDecisionID: $selectedDecisionID)
                }
                .background(DS.Surface.canvas)
            }
        }
    }
}

struct DecisionList: View {
    @ObservedObject var workspace: WorkspaceModel
    let decisions: [Decision]
    @Binding var selectedDecisionID: UUID?

    var body: some View {
        if decisions.isEmpty {
            EmptyStateView(icon: "checkmark.seal", title: "No decisions here",
                           message: "Nothing has been decided in this project yet.")
        } else {
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: DS.stackSpacing) {
                        ForEach(decisions) { decision in
                            Button { selectedDecisionID = decision.id } label: {
                                DecisionRowCard(workspace: workspace, decision: decision, isSelected: selectedDecisionID == decision.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(DS.Space.l)
                }
                .frame(minWidth: 340)

                Group {
                    if let id = selectedDecisionID, let decision = decisions.first(where: { $0.id == id }) {
                        DecisionInspector(workspace: workspace, decision: decision)
                    } else {
                        EmptyStateView(icon: "sidebar.right", title: "Select a decision",
                                       message: "See why it was made, what work it affects and who was involved.")
                    }
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
            }
        }
    }
}

struct DecisionRowCard: View {
    @ObservedObject var workspace: WorkspaceModel
    let decision: Decision
    var isSelected: Bool = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(decision.statement).font(DS.Font.body).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s) {
                    if decision.status == .superseded {
                        StatusBadge(text: "superseded", tint: .secondary)
                    }
                    if let project = workspace.projectName(decision.projectID) {
                        Text(project).font(DS.Font.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Text("· \(decision.decidedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(DS.Font.caption).foregroundColor(.secondary)
                    if workspace.item(decision.relatedItemID) != nil {
                        Label("linked", systemImage: "link").font(DS.Font.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decision: \(decision.statement)")
    }
}

/// The decision detail. This is the app's most differentiating surface: it shows not just WHAT
/// was decided but WHY, WHAT WORK it affects and WHERE it came from - and it says plainly when a
/// link is absent rather than hiding the gap.
struct DecisionInspector: View {
    @ObservedObject var workspace: WorkspaceModel
    let decision: Decision

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("DECISION").font(DS.Font.metadata).foregroundColor(.secondary)
                    Text(decision.statement).font(DS.Font.headline).fixedSize(horizontal: false, vertical: true)
                    if decision.status == .superseded {
                        StatusBadge(text: "no longer current", tint: .secondary)
                    }
                }

                if let reason = decision.reason, !reason.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        SectionHeader("Why")
                        Text(reason).font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SectionHeader("Details")
                    DetailField(label: "Project", value: workspace.projectName(decision.projectID))
                    DetailField(label: "Concerns", value: decision.context)
                    DetailField(label: "Decided", value: decision.decidedAt.formatted(date: .abbreviated, time: .shortened))
                    DetailField(label: "Made by", value: decision.madeBy.compactMap(workspace.personName).joined(separator: ", "))
                    DetailField(label: "From", value: workspace.sessionTitle(decision.sourceSessionID))
                }

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SectionHeader("Related work")
                    if let item = workspace.item(decision.relatedItemID) {
                        Card(padding: DS.Space.s) {
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(item.name).font(DS.Font.callout).fixedSize(horizontal: false, vertical: true)
                                StatusBadge(text: DS.lifecycleLabel(item.status), tint: DS.lifecycleTint(item.status))
                            }
                        }
                    } else if decision.relatedItemID != nil {
                        // The link exists but its target does not - a data-integrity problem the
                        // user should see, not one the UI should quietly paper over.
                        Text("Linked to a work item that no longer exists.")
                            .font(DS.Font.callout).foregroundColor(.orange)
                    } else {
                        Text("Not linked to a tracked work item.")
                            .font(DS.Font.callout).foregroundColor(.secondary)
                    }
                }
            }
            .padding(DS.Space.l)
        }
        .background(DS.Surface.sidebar)
    }
}

// MARK: - People

struct PeopleView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        Group {
            if workspace.people.isEmpty {
                EmptyStateView(icon: "person.2", title: "No people yet",
                               message: "People appear as they are mentioned making decisions or owning work in your conversations.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: DS.Space.m)], spacing: DS.Space.m) {
                        ForEach(workspace.people) { person in
                            let decisions = workspace.allDecisions.filter { $0.madeBy.contains(person.id) }
                            let owned = workspace.projects.items.filter { $0.assignedTo == person.id }
                            Card {
                                VStack(alignment: .leading, spacing: DS.Space.s) {
                                    HStack(spacing: DS.Space.s) {
                                        Image(systemName: "person.circle.fill")
                                            .font(.system(size: 22)).foregroundColor(.secondary)
                                        Text(person.name).font(DS.Font.headline).lineLimit(1)
                                    }
                                    HStack(spacing: DS.Space.m) {
                                        Label(decisions.count.pluralised("decision"), systemImage: "checkmark.seal")
                                        Label(owned.count.pluralised("item"), systemImage: "checklist")
                                    }
                                    .font(DS.Font.caption).foregroundColor(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(person.name), \(decisions.count.pluralised("decision")), \(owned.count.pluralised("work item"))")
                        }
                    }
                    .padding(DS.Space.l)
                }
                .background(DS.Surface.canvas)
            }
        }
    }
}
