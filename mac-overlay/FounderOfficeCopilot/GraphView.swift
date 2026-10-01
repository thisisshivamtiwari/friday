import SwiftUI
import AppKit

// MARK: - Graph View Model
/// Owns the graph's presentation state and nothing else. All the real logic lives in the pure
/// layers (`GraphSnapshotBuilder`, `GraphFilter`, `GraphLayoutEngine`, `GraphViewport`), which
/// is why this file has no algorithms in it worth testing separately - it wires published state
/// to those functions.
///
/// PERFORMANCE CONTRACT: `positions` is recomputed ONLY when the filtered snapshot actually
/// changes. Selecting a node, hovering, panning and zooming all leave the layout untouched -
/// they only change `viewport`/`selection`, so the Canvas redraws but no node is repositioned.
@MainActor
final class GraphViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var fullSnapshot: GraphSnapshot = .empty
    @Published private(set) var visibleSnapshot: GraphSnapshot = .empty
    @Published private(set) var positions: [GraphNodeID: CGPoint] = [:]
    @Published var viewport = GraphViewport()
    @Published var selection: GraphNodeID?

    @Published var criteria: GraphFilterCriteria = .unfiltered {
        didSet { guard criteria != oldValue else { return }; recomputeVisible() }
    }

    private let projectManager: ProjectManager
    private let memoryManager: MemoryManager
    private let chatSessionManager: ChatSessionManager

    init(projectManager: ProjectManager, memoryManager: MemoryManager, chatSessionManager: ChatSessionManager) {
        self.projectManager = projectManager
        self.memoryManager = memoryManager
        self.chatSessionManager = chatSessionManager
    }

    /// Rebuilds from the managers' in-memory arrays. They are already loaded at init (see
    /// `ProjectManager`'s doc comment), so this is a projection of memory, not a store read -
    /// which is why it is fast enough to run synchronously on the main actor and does not need
    /// its own background queue.
    func reload() {
        state = .loading
        let sessions = chatSessionManager.sessions
        let snapshot = GraphSnapshotBuilder.build(
            projects: projectManager.projects,
            items: projectManager.items,
            decisions: projectManager.decisions,
            sessionLinks: projectManager.sessionLinks,
            people: memoryManager.entities.filter { $0.kind == .person || $0.kind == .`self` },
            sessionTitles: Dictionary(sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }),
            sessionDates: Dictionary(sessions.map { ($0.id, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
        )
        fullSnapshot = snapshot
        recomputeVisible()
        state = .loaded
    }

    private func recomputeVisible() {
        visibleSnapshot = GraphFilter.apply(criteria, to: fullSnapshot)
        positions = GraphLayoutEngine.layout(visibleSnapshot)
        // A selection that filtering hid must be dropped, or the inspector would keep describing
        // something no longer on screen.
        if let selection, visibleSnapshot.node(selection) == nil { self.selection = nil }
    }

    // MARK: Viewport actions

    /// True once the user has zoomed, panned or focused. Until then the view is free to re-fit
    /// itself as the window lays out or the filters change; afterwards it never moves the camera
    /// on its own, because silently re-framing a graph someone has positioned by hand is worse
    /// than leaving it slightly off.
    @Published private(set) var userHasAdjustedViewport = false

    /// `size` can legitimately be nonsense on the first pass - an `HSplitView` reports a narrow
    /// intermediate width before its panes settle, and fitting to that produced a graph pinned
    /// at the 10% minimum scale with every label suppressed. Sizes too small to be a real canvas
    /// are ignored rather than fitted to, and the caller re-fits when a genuine size arrives.
    func fit(in size: CGSize) {
        guard size.width > 200, size.height > 200 else { return }
        guard let bounds = GraphLayoutEngine.bounds(of: positions) else {
            viewport = GraphViewport()
            return
        }
        viewport = .fitting(bounds, in: size)
        userHasAdjustedViewport = false
    }

    /// A fit the user did NOT ask for - used while the window is still settling and after a
    /// filter change. Never overrides a camera the user has positioned themselves.
    func fitAutomatically(in size: CGSize) {
        guard !userHasAdjustedViewport else { return }
        fit(in: size)
    }

    func noteUserAdjustedViewport() {
        userHasAdjustedViewport = true
    }

    func focusSelection() {
        guard let selection, let world = positions[selection] else { return }
        viewport = viewport.focused(on: world)
        userHasAdjustedViewport = true
    }

    func zoom(by factor: CGFloat) {
        viewport.scale = GraphViewport.clampScale(viewport.scale * factor)
        userHasAdjustedViewport = true
    }

    // MARK: Derived detail

    var projectsForFilter: [(id: UUID, name: String)] {
        fullSnapshot.projectNames
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func projectName(_ id: UUID?) -> String? { id.flatMap { fullSnapshot.projectNames[$0] } }

    /// Timeline entries for a project, newest first - the "recent activity" the inspector shows
    /// instead of giving every `ProjectEvent` its own node.
    func recentEvents(forProject projectID: UUID, limit: Int = 6) -> [ProjectEvent] {
        projectManager.events(forProject: projectID)
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    func decision(_ id: UUID) -> Decision? { projectManager.decision(id: id) }
    func projectItem(_ id: UUID) -> ProjectItem? { projectManager.projectItem(id: id) }
    func personName(_ id: UUID) -> String? { memoryManager.entities.first { $0.id == id }?.name }
    func messageCount(forSession id: UUID) -> Int? { chatSessionManager.sessions.first { $0.id == id }?.messages.count }
}

// MARK: - Graph View

/// The Graph window's root. Three regions: filters on the left (with the accessible node
/// browser beneath them), the canvas in the middle, the inspector on the right.
struct GraphView: View {
    @ObservedObject var model: GraphViewModel
    /// Raised when the user asks to inspect a node, so the workspace can show the same universal
    /// inspector every other surface uses. Optional so the graph still works standalone.
    var openEntity: ((EntityReference) -> Void)?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        HSplitView {
            GraphSidebar(model: model)
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)

            VStack(spacing: 0) {
                GraphToolbar(model: model, canvasSize: $canvasSize)
                Divider()
                content
            }
            .frame(minWidth: 420)

            GraphInspector(model: model, openEntity: openEntity)
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
        }
        .onAppear { model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            centered {
                ProgressView()
                Text("Loading project graph…").font(.system(size: 12)).foregroundColor(.secondary)
            }
        case .failed(let message):
            centered {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundColor(.secondary)
                Text("The graph could not be built").font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("Try again") { model.reload() }
            }
        case .loaded where model.fullSnapshot.isEmpty:
            centered {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26)).foregroundColor(.secondary)
                Text("No project state yet").font(.system(size: 13, weight: .semibold))
                Text("Projects, work items and decisions appear here as Friday extracts them from your conversations.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        case .loaded where model.visibleSnapshot.isEmpty:
            centered {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 26)).foregroundColor(.secondary)
                Text("Nothing matches these filters").font(.system(size: 13, weight: .semibold))
                Button("Clear filters") { model.criteria = .unfiltered }
            }
        case .loaded:
            GraphCanvas(model: model, canvasSize: $canvasSize)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Toolbar

private struct GraphToolbar: View {
    @ObservedObject var model: GraphViewModel
    @Binding var canvasSize: CGSize

    var body: some View {
        HStack(spacing: 10) {
            Text("\(model.visibleSnapshot.nodes.count) nodes · \(model.visibleSnapshot.edges.count) relationships")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .accessibilityLabel("\(model.visibleSnapshot.nodes.count) nodes and \(model.visibleSnapshot.edges.count) relationships shown")

            if !model.visibleSnapshot.integrityIssues.isEmpty {
                Label("\(model.visibleSnapshot.integrityIssues.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .help("Data-integrity problems found - see the inspector")
            }

            Spacer()

            Button { model.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out").accessibilityLabel("Zoom out")
            Text("\(Int(model.viewport.scale * 100))%")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                .frame(width: 44)
            Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in").accessibilityLabel("Zoom in")

            Divider().frame(height: 16)

            Button("Focus") { model.focusSelection() }
                .disabled(model.selection == nil)
                .help("Centre the selected node")
            Button("Reset view") { model.fit(in: canvasSize) }
                .help("Fit the whole graph in the window")
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rebuild from stored state").accessibilityLabel("Reload graph")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Canvas

/// Renders edges and nodes with a single `Canvas` rather than one SwiftUI view per node: at a
/// thousand nodes the view-per-node approach costs a thousand view identities, layout passes and
/// diffing operations per redraw, whereas this is one draw pass over cached positions.
private struct GraphCanvas: View {
    @ObservedObject var model: GraphViewModel
    @Binding var canvasSize: CGSize

    /// Node hit radius and drawing radius, in world units.
    private let nodeRadius: CGFloat = 26
    @State private var dragStart: CGSize?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? model.viewport.offset
                        if dragStart == nil { dragStart = start }
                        model.viewport.offset = CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height
                        )
                        model.noteUserAdjustedViewport()
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        model.viewport.scale = GraphViewport.clampScale(value)
                        model.noteUserAdjustedViewport()
                    }
            )
            .onTapGesture { location in
                model.selection = model.viewport.hitTest(
                    screen: location, in: geometry.size, positions: model.positions, radius: nodeRadius
                )
            }
            .onAppear {
                canvasSize = geometry.size
                model.fitAutomatically(in: geometry.size)
            }
            // The canvas keeps re-framing itself until the user takes the camera - which covers
            // the split pane settling to its real width, the window being resized, and the graph
            // changing shape under a filter. `fitAutomatically` is a no-op once the user has
            // panned, zoomed or focused.
            .onChange(of: geometry.size) { newSize in
                canvasSize = newSize
                model.fitAutomatically(in: newSize)
            }
            .onChange(of: model.positions.count) { _ in
                model.fitAutomatically(in: canvasSize)
            }
            // The canvas itself is not usefully describable to VoiceOver - the node browser in
            // the sidebar is the accessible route through the same data, and it is a real list
            // rather than a spatial surface.
            .accessibilityHidden(true)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let viewport = model.viewport
        let snapshot = model.visibleSnapshot
        let positions = model.positions
        let selection = model.selection
        let neighbours: Set<GraphNodeID> = selection.map { id in
            Set(snapshot.edges(touching: id).flatMap { [$0.source, $0.destination] })
        } ?? []

        // Edges first, so nodes always paint over them.
        for edge in snapshot.edges {
            guard let from = positions[edge.source], let to = positions[edge.destination] else { continue }
            let start = viewport.screenPosition(of: from, in: size)
            let end = viewport.screenPosition(of: to, in: size)

            let touchesSelection = selection == edge.source || selection == edge.destination
            // Restrained by default, emphasised on selection: with everything drawn at full
            // strength the diagram reads as a hairball where "contains" looks as important as
            // "this decision is about that work item".
            let opacity: Double = {
                if selection == nil { return edge.kind.isStructural ? 0.16 : 0.34 }
                return touchesSelection ? 0.85 : 0.06
            }()

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(edgeColour(edge).opacity(opacity)),
                style: StrokeStyle(
                    lineWidth: touchesSelection ? 2 : 1,
                    dash: edge.kind == .decisionSupersedesDecision ? [4, 3] : []
                )
            )
        }

        // Nodes.
        //
        // LABEL DECLUTTERING. Drawing a label under every node produced genuinely unreadable
        // output on the real corpus - "Set up 5-agent gridworld…" printed straight through
        // "Test temperature scaling versus M…", and a person's name through a work item's. Rings
        // are sized so the NODES never overlap, but a label is far wider than the node it
        // belongs to, so node spacing alone cannot prevent it.
        //
        // So labels are placed greedily in priority order and any label that would collide with
        // one already placed is dropped. Priority is: the selected node and its neighbours first
        // (what the user is actually looking at must always be readable), then projects (the
        // structural anchors), then everything else. Ties break on node id, so which labels
        // survive is deterministic for a given viewport rather than dependent on iteration
        // order. Zooming in reveals the dropped ones, which is the normal contract for a
        // decluttered graph.
        var placedLabelFrames: [CGRect] = []
        let labelPriority: (GraphNode) -> Int = { node in
            if selection == node.id { return 0 }
            if neighbours.contains(node.id) { return 1 }
            return node.kind == .project ? 2 : 3
        }
        let orderedForLabels = snapshot.nodes.sorted { lhs, rhs in
            let (lp, rp) = (labelPriority(lhs), labelPriority(rhs))
            return lp == rp ? lhs.id < rhs.id : lp < rp
        }
        var labelledNodes: Set<GraphNodeID> = []
        if viewport.scale > 0.40 {
            for node in orderedForLabels {
                guard let world = positions[node.id] else { continue }
                let point = viewport.screenPosition(of: world, in: size)
                let radius = displayRadius(for: node.kind) * max(viewport.scale, 0.5)
                let text = truncated(node.title)
                // Approximate metrics - exact text measurement per frame would cost more than
                // the whole draw pass, and a slightly conservative box is the safe error here.
                let width = CGFloat(text.count) * 5.4 + 8
                let height: CGFloat = node.lifecycleStatus != nil && viewport.scale > 0.62 ? 25 : 13
                let frame = CGRect(x: point.x - width / 2, y: point.y + radius + 6, width: width, height: height)
                guard !placedLabelFrames.contains(where: { $0.intersects(frame) }) else { continue }
                placedLabelFrames.append(frame)
                labelledNodes.insert(node.id)
            }
        }

        for node in snapshot.nodes {
            guard let world = positions[node.id] else { continue }
            let point = viewport.screenPosition(of: world, in: size)
            let radius = displayRadius(for: node.kind) * max(viewport.scale, 0.5)
            let isSelected = selection == node.id
            let isDimmed = selection != nil && !isSelected && !neighbours.contains(node.id)

            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let shape = shapePath(for: node.kind, in: rect)

            context.fill(shape, with: .color(fillColour(for: node).opacity(isDimmed ? 0.25 : 1)))
            context.stroke(
                shape,
                with: .color(isSelected ? Color.accentColor : Color.primary.opacity(isDimmed ? 0.1 : 0.35)),
                lineWidth: isSelected ? 3 : 1
            )

            // Labels are dropped when zoomed far out, and when decluttering could not find room.
            guard labelledNodes.contains(node.id) else { continue }
            let label = Text(truncated(node.title))
                .font(.system(size: 10, weight: node.kind == .project ? .semibold : .regular))
                .foregroundColor(.primary.opacity(isDimmed ? 0.3 : 0.9))
            context.draw(context.resolve(label), at: CGPoint(x: point.x, y: point.y + radius + 11), anchor: .top)

            if let status = node.lifecycleStatus, viewport.scale > 0.62 {
                let statusLabel = Text(status).font(.system(size: 9)).foregroundColor(.secondary.opacity(isDimmed ? 0.3 : 1))
                context.draw(context.resolve(statusLabel), at: CGPoint(x: point.x, y: point.y + radius + 24), anchor: .top)
            }
        }
    }

    private func truncated(_ title: String) -> String {
        title.count <= 34 ? title : String(title.prefix(33)) + "…"
    }

    private func displayRadius(for kind: GraphNodeKind) -> CGFloat {
        switch kind {
        case .project: return 30
        case .projectItem: return 19
        case .decision: return 19
        case .session: return 15
        case .person: return 13
        }
    }

    /// SHAPE encodes type, not colour - so the graph stays readable in both themes, survives
    /// colour-blindness, and never becomes a rainbow.
    private func shapePath(for kind: GraphNodeKind, in rect: CGRect) -> Path {
        switch kind {
        case .project, .person:
            return Path(ellipseIn: rect)
        case .projectItem:
            return Path(roundedRect: rect, cornerRadius: 5)
        case .session:
            return Path(roundedRect: rect.insetBy(dx: 0, dy: rect.height * 0.22), cornerRadius: rect.height / 2)
        case .decision:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }

    /// One accent hue plus neutrals, at different weights - deliberately not a per-type palette.
    private func fillColour(for node: GraphNode) -> Color {
        switch node.kind {
        case .project: return Color.accentColor.opacity(0.85)
        case .decision: return Color.accentColor.opacity(0.45)
        case .projectItem: return lifecycleFill(node.lifecycleStatus)
        case .session: return Color.secondary.opacity(0.30)
        case .person: return Color.secondary.opacity(0.55)
        }
    }

    /// Lifecycle is visible on the canvas itself, not only in the inspector - the Phase 4.5
    /// state made legible spatially. Finished work reads as solid, unstarted work as faint,
    /// stalled work as the one thing that stands out.
    private func lifecycleFill(_ status: String?) -> Color {
        switch status {
        case ProjectItem.Status.completed.rawValue,
             ProjectItem.Status.achieved.rawValue,
             ProjectItem.Status.resolved.rawValue:
            return Color.secondary.opacity(0.75)
        case ProjectItem.Status.blocked.rawValue:
            return Color.orange.opacity(0.75)
        case ProjectItem.Status.abandoned.rawValue:
            return Color.secondary.opacity(0.18)
        case ProjectItem.Status.active.rawValue, ProjectItem.Status.inProgress.rawValue:
            return Color.accentColor.opacity(0.3)
        default:
            return Color.secondary.opacity(0.35)
        }
    }

    private func edgeColour(_ edge: GraphEdge) -> Color {
        edge.kind == .decisionRelatesToItem ? Color.accentColor : Color.primary
    }
}
