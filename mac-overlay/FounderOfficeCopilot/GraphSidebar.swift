import SwiftUI

// MARK: - Graph Sidebar
/// Search, filters, and the ACCESSIBLE NODE BROWSER.
///
/// The browser is not a convenience list bolted on beside the canvas - it is the accessibility
/// story for this whole feature. A node-link diagram conveys its meaning through position and
/// shape, neither of which VoiceOver can read, so the canvas is marked
/// `.accessibilityHidden(true)` and this list is the supported route through exactly the same
/// filtered data. Selecting here selects there and vice versa, so nothing is reachable only by
/// pointing at pixels.
struct GraphSidebar: View {
    @ObservedObject var model: GraphViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filters
            Divider()
            browser
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            labelled("Project") {
                Picker("Project", selection: projectBinding) {
                    Text("All projects").tag(UUID?.none)
                    ForEach(model.projectsForFilter, id: \.id) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Filter by project")
            }

            labelled("Show") {
                ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                    Toggle(kind.displayName, isOn: kindBinding(kind))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                }
            }

            labelled("Work item status") {
                ForEach(ProjectItem.Status.allCases, id: \.self) { status in
                    Toggle(status.rawValue, isOn: lifecycleBinding(status.rawValue))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                }
            }

            if model.criteria.isActive {
                Button("Clear all filters") { model.criteria = .unfiltered }
                    .font(.system(size: 11))
            }
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
            TextField("Search", text: Binding(
                get: { model.criteria.searchText },
                set: { model.criteria.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .accessibilityLabel("Search the graph")
            if !model.criteria.searchText.isEmpty {
                Button { model.criteria.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundColor(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    // MARK: Bindings
    //
    // The toggle sets are stored as "which are ON", but an EMPTY set means "all" (see
    // `GraphFilterCriteria`). These bindings translate between the two so an untouched filter
    // panel shows every box ticked while still filtering nothing.

    private var projectBinding: Binding<UUID?> {
        Binding(get: { model.criteria.projectID }, set: { model.criteria.projectID = $0 })
    }

    private func kindBinding(_ kind: GraphNodeKind) -> Binding<Bool> {
        Binding(
            get: { model.criteria.nodeKinds.isEmpty || model.criteria.nodeKinds.contains(kind) },
            set: { isOn in
                var kinds = model.criteria.nodeKinds.isEmpty ? Set(GraphNodeKind.allCases) : model.criteria.nodeKinds
                if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
                model.criteria.nodeKinds = kinds == Set(GraphNodeKind.allCases) ? [] : kinds
            }
        )
    }

    private func lifecycleBinding(_ status: String) -> Binding<Bool> {
        let all = Set(ProjectItem.Status.allCases.map(\.rawValue))
        return Binding(
            get: { model.criteria.lifecycleStatuses.isEmpty || model.criteria.lifecycleStatuses.contains(status) },
            set: { isOn in
                var statuses = model.criteria.lifecycleStatuses.isEmpty ? all : model.criteria.lifecycleStatuses
                if isOn { statuses.insert(status) } else { statuses.remove(status) }
                model.criteria.lifecycleStatuses = statuses == all ? [] : statuses
            }
        )
    }

    // MARK: Accessible node browser

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NODES")
                .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            // A real `List` with a selection binding, so arrow-key navigation, type-select and
            // VoiceOver all work the way they do everywhere else in macOS - none of which a
            // Canvas can provide.
            List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
                ForEach(GraphNodeKind.allCases, id: \.self) { kind in
                    let nodes = model.visibleSnapshot.nodes.filter { $0.kind == kind }
                    if !nodes.isEmpty {
                        Section(header: Text("\(kind.displayName) (\(nodes.count))").font(.system(size: 10, weight: .semibold))) {
                            ForEach(nodes) { node in
                                row(node).tag(node.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Graph nodes")
        }
    }

    private func row(_ node: GraphNode) -> some View {
        let degree = model.visibleSnapshot.degree(of: node.id)
        return VStack(alignment: .leading, spacing: 1) {
            Text(node.title).font(.system(size: 11)).lineLimit(1)
            HStack(spacing: 4) {
                if let status = node.lifecycleStatus {
                    Text(status).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                }
                Text("\(degree) link\(degree == 1 ? "" : "s")").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        // Everything a sighted user reads from position, shape and highlight, said explicitly.
        .accessibilityLabel(accessibilityLabel(for: node, degree: degree))
        .accessibilityAddTraits(model.selection == node.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Select to inspect this \(node.kind.displayName.lowercased())")
    }

    private func accessibilityLabel(for node: GraphNode, degree: Int) -> String {
        var parts = ["\(node.kind.displayName): \(node.title)"]
        if let status = node.lifecycleStatus { parts.append("status \(status)") }
        if let project = model.projectName(node.projectID) { parts.append("in \(project)") }
        parts.append("\(degree) relationship\(degree == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }
}
