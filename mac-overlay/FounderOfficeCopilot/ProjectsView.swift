import SwiftUI

// MARK: - Projects
/// Project list on the left, project detail on the right. The detail view is tabbed rather than
/// one long scroll because a project holds four genuinely different kinds of thing - work,
/// decisions, timeline, people - and a founder arrives wanting one of them, not all four.
struct ProjectsView: View {
    @ObservedObject var workspace: WorkspaceModel
    @Binding var selectedProjectID: UUID?
    @State private var isCreatingProject = false

    var body: some View {
        Group {
            if workspace.allProjectsByActivity.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "No projects yet",
                    message: workspace.needsFirstProject
                        ? "You've had \(workspace.recentSessions.count.pluralised("conversation")), but nothing can be filed yet: the assistant only records work, decisions and people against a project. Create your first one and it will start filling in."
                        : "Projects are where your work, decisions and people are filed. Create one to get started.",
                    actionTitle: "New project"
                ) { isCreatingProject = true }
            } else {
                HSplitView {
                    list.frame(minWidth: 230, idealWidth: 270, maxWidth: 340)
                    detail.frame(minWidth: 480)
                }
            }
        }
        .onAppear {
            if selectedProjectID == nil { selectedProjectID = workspace.allProjectsByActivity.first?.id }
        }
        .sheet(isPresented: $isCreatingProject) {
            NewProjectSheet(workspace: workspace, linkableSession: workspace.recentSessions.first) { project in
                selectedProjectID = project.id
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: DS.stackSpacing) {
                ForEach(workspace.allProjectsByActivity) { project in
                    SelectableRow(isSelected: selectedProjectID == project.id) {
                        selectedProjectID = project.id
                    } content: {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(project.name).font(DS.Font.body).lineLimit(1)
                            HStack(spacing: DS.Space.s) {
                                Text("\(workspace.openItems(in: project.id).count) open")
                                if !workspace.blockedItems(in: project.id).isEmpty {
                                    Text("· \(workspace.blockedItems(in: project.id).count) blocked").foregroundColor(.orange)
                                }
                            }
                            .font(DS.Font.caption).foregroundColor(.secondary)
                        }
                    }
                    .accessibilityLabel("\(project.name), \(workspace.openItems(in: project.id).count.pluralised("open item"))")
                }
            }
            .padding(DS.Space.s)
        }
        .background(DS.Surface.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedProjectID, let project = workspace.project(id) {
            ProjectDetailView(workspace: workspace, project: project)
        } else {
            EmptyStateView(icon: "sidebar.left", title: "Select a project",
                           message: "Choose a project to see its work, decisions and history.")
        }
    }
}

// MARK: - Project detail

struct ProjectDetailView: View {
    @ObservedObject var workspace: WorkspaceModel
    let project: Project

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", work = "Work", decisions = "Decisions", timeline = "Timeline", people = "People"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .overview
    @State private var selectedItemID: UUID?
    @State private var selectedDecisionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            Divider()
            content
        }
        .background(DS.Surface.canvas)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top) {
                Text(project.name).font(DS.Font.title).fixedSize(horizontal: false, vertical: true)
                Spacer()
                StatusBadge(text: project.status.rawValue, tint: project.status == .active ? .accentColor : .secondary)
            }
            HStack(spacing: DS.Space.l) {
                Text(workspace.items(in: project.id).count.pluralised("work item"))
                Text(workspace.decisions(in: project.id).count.pluralised("decision"))
                Text("\(workspace.openItems(in: project.id).count) open")
                Text("Updated \(workspace.lastActivity(for: project.id).formatted(date: .abbreviated, time: .omitted))")
            }
            .font(DS.Font.caption).foregroundColor(.secondary)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview: overview
        case .work: WorkList(workspace: workspace, items: workspace.items(in: project.id), selectedItemID: $selectedItemID)
        case .decisions: DecisionList(workspace: workspace, decisions: workspace.decisions(in: project.id), selectedDecisionID: $selectedDecisionID)
        case .timeline: TimelineList(events: workspace.timeline(for: project.id))
        case .people: peopleTab
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                let open = workspace.openItems(in: project.id)
                let blocked = workspace.blockedItems(in: project.id)
                let done = workspace.items(in: project.id).filter { !DS.isOpen($0.status) }

                if !blocked.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionHeader("Blocked")
                        ForEach(blocked) { item in WorkRowCard(workspace: workspace, item: item) }
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SectionHeader("Current focus", subtitle: "Open work, most recently updated")
                    if open.isEmpty {
                        Card { Text("Nothing open in this project.").font(DS.Font.callout).foregroundColor(.secondary) }
                    } else {
                        ForEach(open.prefix(5)) { item in WorkRowCard(workspace: workspace, item: item) }
                    }
                }
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    SectionHeader("Recent decisions")
                    let decisions = workspace.decisions(in: project.id)
                    if decisions.isEmpty {
                        Card { Text("No decisions captured yet.").font(DS.Font.callout).foregroundColor(.secondary) }
                    } else {
                        ForEach(decisions.prefix(4)) { decision in
                            DecisionRowCard(workspace: workspace, decision: decision)
                        }
                    }
                }
                if !done.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        SectionHeader("Completed", subtitle: done.count.pluralised("item"))
                        ForEach(done.prefix(4)) { item in WorkRowCard(workspace: workspace, item: item) }
                    }
                }
            }
            .padding(DS.Space.l)
        }
    }

    private var peopleTab: some View {
        // People are derived from real relationships only - who made a decision, who a work item
        // is assigned to. Nobody is listed because they merely appeared in a transcript.
        let decisionPeople = workspace.decisions(in: project.id).flatMap(\.madeBy)
        let itemPeople = workspace.items(in: project.id).compactMap(\.assignedTo)
        let ids = Array(Set(decisionPeople + itemPeople))
        return Group {
            if ids.isEmpty {
                EmptyStateView(icon: "person.2", title: "No people linked yet",
                               message: "People appear here once they are recorded as making a decision or owning a piece of work.")
            } else {
                ScrollView {
                    VStack(spacing: DS.stackSpacing) {
                        ForEach(ids, id: \.self) { id in
                            Card {
                                HStack {
                                    Image(systemName: "person.circle").foregroundColor(.secondary)
                                    Text(workspace.personName(id) ?? "Unknown").font(DS.Font.body)
                                    Spacer()
                                    Text(decisionPeople.filter { $0 == id }.count.pluralised("decision"))
                                        .font(DS.Font.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(DS.Space.l)
                }
            }
        }
    }
}

// MARK: - Timeline

struct TimelineList: View {
    let events: [ProjectEvent]

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyStateView(icon: "clock", title: "No history yet",
                               message: "The timeline fills in as work is created, decisions are made and conversations are linked to this project.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                VStack(spacing: 0) {
                                    Circle().fill(tint(event.eventType)).frame(width: 8, height: 8)
                                    Rectangle().fill(DS.Surface.hairline).frame(width: 1)
                                }
                                .frame(width: 8)
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(label(event.eventType)).font(DS.Font.metadata).foregroundColor(.secondary)
                                    Text(event.description).font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                                    Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DS.Font.caption).foregroundColor(.secondary)
                                }
                                .padding(.bottom, DS.Space.l)
                                Spacer()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(DS.Space.l)
                }
            }
        }
    }

    private func label(_ type: ProjectEvent.EventType) -> String {
        switch type {
        case .itemCreated: return "WORK CREATED"
        case .statusChanged: return "STATUS CHANGED"
        case .decisionMade: return "DECISION"
        case .decisionSuperseded: return "DECISION SUPERSEDED"
        case .meetingOccurred: return "MEETING"
        case .sessionAssigned: return "CONVERSATION LINKED"
        case .sessionReassigned: return "CONVERSATION MOVED"
        }
    }

    private func tint(_ type: ProjectEvent.EventType) -> Color {
        switch type {
        case .decisionMade, .decisionSuperseded: return .accentColor
        default: return .secondary.opacity(0.6)
        }
    }
}
