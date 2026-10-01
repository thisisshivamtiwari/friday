import SwiftUI

// MARK: - Home
/// The command centre. It answers exactly one question - "what is happening right now?" - and
/// is deliberately built from FOUR sections rather than twelve tiles: attention, active
/// projects, recent decisions, recent conversations. Everything shown is real persisted state;
/// nothing here is inferred, scored or AI-generated, so what the founder reads is what the
/// workspace actually contains.
struct HomeView: View {
    @ObservedObject var workspace: WorkspaceModel
    let openProject: (UUID) -> Void
    /// Opens any entity in the universal inspector. Home surfaces decisions and conversations,
    /// and a card that looks tappable must BE tappable - a dead-end card is worse than a plain
    /// list, because it silently teaches the user that the app ignores them.
    let openEntity: (EntityReference) -> Void
    /// Offered when there is nothing to file conversations into - see `needsFirstProject`.
    var createProject: (() -> Void)?

    var body: some View {
        Group {
            if workspace.isEmptyWorkspace {
                EmptyStateView(
                    icon: "sparkles",
                    title: "Your workspace is quiet",
                    message: "Founder Office Copilot listens to your meetings and turns them into projects, work and decisions you can ask questions about. Create a project, and what you say in it starts being filed.",
                    actionTitle: createProject == nil ? nil : "New project"
                ) { createProject?() }
            } else if workspace.needsFirstProject {
                // The state a real install actually reached: plenty of conversation, nothing
                // extracted, because there was no project to extract into. Say so plainly rather
                // than showing an empty dashboard with no explanation.
                EmptyStateView(
                    icon: "folder.badge.plus",
                    title: "Nothing is being filed yet",
                    message: "You've had \(workspace.recentSessions.count.pluralised("conversation")), but the assistant only records work, decisions and people against a project — and there aren't any yet. Create your first project and it will start filling in.",
                    actionTitle: createProject == nil ? nil : "Create your first project"
                ) { createProject?() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.section) {
                        header
                        if !attentionItems.isEmpty { attention }
                        projects
                        HStack(alignment: .top, spacing: DS.Space.xl) {
                            decisions.frame(maxWidth: .infinity, alignment: .leading)
                            conversations.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(DS.Space.xl)
                    .frame(maxWidth: 1100, alignment: .leading)
                }
                .background(DS.Surface.canvas)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(greeting).font(DS.Font.display)
                Text("Here is where everything stands.").font(DS.Font.body).foregroundColor(.secondary)
            }
            HStack(spacing: DS.Space.l) {
                StatTile(value: "\(workspace.activeProjects.count)", caption: "active projects")
                StatTile(value: "\(workspace.allOpenWork.count)", caption: "open work")
                StatTile(value: "\(workspace.blockedWork.count)", caption: "blocked",
                         tint: workspace.blockedWork.isEmpty ? .primary : .orange)
                StatTile(value: "\(workspace.allDecisions.count)", caption: "decisions")
            }
            .padding(DS.Space.l)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large).fill(DS.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).stroke(DS.Surface.hairline))
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: Needs attention

    /// Blocked work only. "Needs attention" must mean something specific or it becomes noise -
    /// a section that lights up for everything is a section people learn to ignore.
    private var attentionItems: [ProjectItem] { workspace.blockedWork }

    private var attention: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader("Needs attention", subtitle: "Work that is blocked")
            VStack(spacing: DS.Space.xs) {
                ForEach(attentionItems.prefix(4)) { item in
                    Button {
                        openEntity(EntityReference(kind: .workItem(item.id)))
                    } label: {
                    Card {
                        HStack(spacing: DS.Space.m) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(item.name).font(DS.Font.body).lineLimit(2)
                                if let project = workspace.projectName(item.projectID) {
                                    Text(project).font(DS.Font.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(DS.Font.caption).foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel("Blocked: \(item.name)")
                    .accessibilityHint("Open this work item")
                }
            }
        }
    }

    // MARK: Projects

    private var projects: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader("Projects", subtitle: "Most recently active first")
            if workspace.allProjectsByActivity.isEmpty {
                Card { Text("No projects yet.").font(DS.Font.callout).foregroundColor(.secondary) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: DS.Space.m)], spacing: DS.Space.m) {
                    ForEach(workspace.allProjectsByActivity.prefix(6)) { project in
                        Button { openProject(project.id) } label: {
                            ProjectSummaryCard(workspace: workspace, project: project)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Decisions and conversations

    private var decisions: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader("Recent decisions")
            if workspace.allDecisions.isEmpty {
                Card { Text("No decisions captured yet.").font(DS.Font.callout).foregroundColor(.secondary) }
            } else {
                VStack(spacing: DS.stackSpacing) {
                    ForEach(workspace.allDecisions.prefix(4)) { decision in
                        Button {
                            openEntity(EntityReference(kind: .decision(decision.id)))
                        } label: {
                            Card(padding: DS.cardPadding) {
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(decision.statement).font(DS.Font.body).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: DS.Space.s) {
                                        if let project = workspace.projectName(decision.projectID) {
                                            Text(project).font(DS.Font.caption).foregroundColor(.secondary)
                                        }
                                        Text(decision.decidedAt.formatted(date: .abbreviated, time: .omitted))
                                            .font(DS.Font.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("Decision: \(decision.statement)")
                        .accessibilityHint("Open this decision")
                    }
                }
            }
        }
    }

    private var conversations: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader("Recent conversations")
            if workspace.recentSessions.isEmpty {
                Card { Text("No conversations yet.").font(DS.Font.callout).foregroundColor(.secondary) }
            } else {
                VStack(spacing: DS.stackSpacing) {
                    ForEach(workspace.recentSessions.prefix(4)) { session in
                        Button {
                            openEntity(EntityReference(kind: .conversation(session.id)))
                        } label: {
                            Card(padding: DS.cardPadding) {
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(session.title).font(DS.Font.body).lineLimit(1)
                                    Text("\(session.messages.count.pluralised("message")) · \((session.lastMessageAt ?? session.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                                        .font(DS.Font.caption).foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("Conversation: \(session.title), \(session.messages.count.pluralised("message"))")
                        .accessibilityHint("Open this conversation")
                    }
                }
            }
        }
    }
}

// MARK: - Project summary card

struct ProjectSummaryCard: View {
    @ObservedObject var workspace: WorkspaceModel
    let project: Project

    var body: some View {
        let open = workspace.openItems(in: project.id)
        let blocked = workspace.blockedItems(in: project.id)
        let decisions = workspace.decisions(in: project.id)

        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text(project.name).font(DS.Font.headline).lineLimit(2)
                    Spacer()
                    StatusBadge(text: project.status.rawValue,
                                tint: project.status == .active ? .accentColor : .secondary)
                }
                HStack(spacing: DS.Space.m) {
                    Label("\(open.count) open", systemImage: "circle.dashed")
                    Label(decisions.count.pluralised("decision"), systemImage: "checkmark.seal")
                    if !blocked.isEmpty {
                        Label("\(blocked.count) blocked", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                }
                .font(DS.Font.caption)
                .foregroundColor(.secondary)
                .labelStyle(.titleAndIcon)

                if let focus = open.first {
                    Divider().padding(.vertical, DS.Space.xxs)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("CURRENT FOCUS").font(DS.Font.metadata).foregroundColor(.secondary)
                        Text(focus.name).font(DS.Font.callout).lineLimit(2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name), \(project.status.rawValue), \(open.count.pluralised("open item")), \(decisions.count.pluralised("decision"))")
    }
}
