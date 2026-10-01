import SwiftUI

// MARK: - Global Activity Timeline
//
// NAMED `ActivityTimelineView`, not `TimelineView`: SwiftUI ships its own `TimelineView` (used by
// `AvatarBlobView` to drive its animation), and shadowing it silently rebound that call to this
// type. The compiler caught it, but the lesson generalises - a top-level view type sharing a name
// with a SwiftUI primitive will hijack it somewhere unrelated.
/// "What happened, and when" across every project.
///
/// It is built from `ProjectEvent` rows only - the append-only history the domain already
/// records. It is deliberately NOT a database audit log: nothing is synthesised from row
/// timestamps, and no event is invented for a write that the domain did not consider
/// noteworthy. If an event is here, the application recorded it as something that happened.
struct ActivityTimelineView: View {
    @ObservedObject var workspace: WorkspaceModel
    /// Opening an entry shows the thing it happened to.
    let openEntity: (EntityReference) -> Void

    @State private var projectFilter: UUID?
    @State private var typeFilter: Set<ProjectEvent.EventType> = []

    private var entries: [Entry] {
        let projects = projectFilter.map { [$0] } ?? workspace.projects.projects.map(\.id)
        return projects
            .flatMap { projectID in
                workspace.timeline(for: projectID).map { Entry(event: $0, projectID: projectID) }
            }
            .filter { typeFilter.isEmpty || typeFilter.contains($0.event.eventType) }
            .sorted { $0.event.occurredAt > $1.event.occurredAt }
    }

    struct Entry: Identifiable {
        let event: ProjectEvent
        let projectID: UUID
        var id: UUID { event.id }
    }

    var body: some View {
        Group {
            if workspace.projects.events.isEmpty {
                EmptyStateView(
                    icon: "clock",
                    title: "Nothing has happened yet",
                    message: "Your timeline fills in as work is created, decisions are made and conversations are linked to projects."
                )
            } else {
                VStack(spacing: 0) {
                    filters
                    Divider()
                    if entries.isEmpty {
                        EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: "Nothing matches these filters",
                                       message: "Try a different project or event type.",
                                       actionTitle: "Clear filters") { projectFilter = nil; typeFilter = [] }
                    } else {
                        list
                    }
                }
                .background(DS.Surface.canvas)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: DS.Space.m) {
            Picker("Project", selection: $projectFilter) {
                Text("All projects").tag(UUID?.none)
                ForEach(workspace.allProjectsByActivity) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }
            .labelsHidden().frame(maxWidth: 260)
            .accessibilityLabel("Filter timeline by project")

            // Grouped rather than one toggle per raw event type: a founder thinks in "decisions"
            // and "work", not in seven persistence event names.
            ForEach(TimelineGroup.allCases, id: \.self) { group in
                let isOn = typeFilter.isEmpty || group.types.allSatisfy(typeFilter.contains)
                Button {
                    if typeFilter.isEmpty { typeFilter = Set(ProjectEvent.EventType.allCases) }
                    if group.types.allSatisfy(typeFilter.contains) {
                        group.types.forEach { typeFilter.remove($0) }
                    } else {
                        group.types.forEach { typeFilter.insert($0) }
                    }
                    if typeFilter == Set(ProjectEvent.EventType.allCases) { typeFilter = [] }
                } label: {
                    Text(group.title).font(DS.Font.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(isOn ? .accentColor : .secondary)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Spacer()
            Text(entries.count.pluralised("event")).font(DS.Font.caption).foregroundColor(.secondary)
        }
        .padding(DS.Space.l)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedByDay, id: \.0) { day, dayEntries in
                    Section {
                        ForEach(dayEntries) { entry in row(entry) }
                    } header: {
                        HStack {
                            Text(day).font(DS.Font.metadata).foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.top, DS.Space.m).padding(.bottom, DS.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var groupedByDay: [(String, [Entry])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        for entry in entries {
            let key = formatter.string(from: entry.event.occurredAt)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            if let target = target(for: entry) { openEntity(target) }
        } label: {
            HStack(alignment: .top, spacing: DS.Space.m) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(TimelineGroup.of(entry.event.eventType).tint)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    Rectangle().fill(DS.Surface.hairline).frame(width: 1)
                }
                .frame(width: 7)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(TimelineGroup.of(entry.event.eventType).title.uppercased())
                        .font(DS.Font.metadata).foregroundColor(.secondary)
                    Text(entry.event.description)
                        .font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.s) {
                        if let name = workspace.projectName(entry.projectID) {
                            Text(name).font(DS.Font.caption).foregroundColor(.secondary)
                        }
                        Text(entry.event.occurredAt.formatted(date: .omitted, time: .shortened))
                            .font(DS.Font.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.bottom, DS.Space.l)
                Spacer(minLength: 0)
                if target(for: entry) != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(TimelineGroup.of(entry.event.eventType).title): \(entry.event.description)")
    }

    /// `ProjectEvent.relatedItemID` means different things per event type (see its doc comment),
    /// so this resolves it rather than assuming. An id that no longer resolves yields no target
    /// and the row is simply not clickable - never a link to the wrong thing.
    private func target(for entry: Entry) -> EntityReference? {
        let id = entry.event.relatedItemID
        switch entry.event.eventType {
        case .decisionMade, .decisionSuperseded:
            return workspace.projects.decision(id: id).map { .init(kind: .decision($0.id)) }
        case .itemCreated, .statusChanged:
            return workspace.projects.projectItem(id: id).map { .init(kind: .workItem($0.id)) }
        case .sessionAssigned, .sessionReassigned:
            return workspace.sessions.sessions.contains { $0.id == id } ? .init(kind: .conversation(id)) : nil
        case .meetingOccurred:
            return nil
        }
    }
}

// MARK: - Grouping

/// Raw `ProjectEvent.EventType` values are persistence vocabulary. These are the three things a
/// founder actually distinguishes on a timeline.
enum TimelineGroup: CaseIterable {
    case decisions, work, conversations

    var title: String {
        switch self {
        case .decisions: return "Decisions"
        case .work: return "Work"
        case .conversations: return "Conversations"
        }
    }

    var tint: Color {
        switch self {
        case .decisions: return .accentColor
        case .work: return .secondary
        case .conversations: return .secondary.opacity(0.6)
        }
    }

    var types: [ProjectEvent.EventType] {
        switch self {
        case .decisions: return [.decisionMade, .decisionSuperseded]
        case .work: return [.itemCreated, .statusChanged, .meetingOccurred]
        case .conversations: return [.sessionAssigned, .sessionReassigned]
        }
    }

    static func of(_ type: ProjectEvent.EventType) -> TimelineGroup {
        allCases.first { $0.types.contains(type) } ?? .work
    }
}
