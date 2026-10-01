import Foundation
import CoreGraphics

// MARK: - Graph Layout
/// Deterministic positions for a snapshot. Pure: same snapshot in, byte-identical positions out,
/// every time and in every process. No randomness, no simulation, no animation state, no clock.
///
/// WHY NOT FORCE-DIRECTED. A force simulation is the reflex choice for graph drawing, and it is
/// the wrong one here for three concrete reasons:
///
/// 1. This graph is not general. It is strongly PARTITIONED BY PROJECT - project isolation is a
///    structural invariant of the whole codebase, so almost every edge is intra-project and the
///    components are known in advance. A layout that discovers that structure by relaxation is
///    rediscovering something the data already states.
/// 2. Force layouts are iterative and seed-dependent, so "same database, same picture" needs a
///    pinned seed AND a pinned iteration count AND identical floating-point accumulation order.
///    That is a lot of machinery to buy determinism that a closed-form layout simply has.
/// 3. Cost. This is O(n) in one pass; a force layout is O(n^2) per iteration times dozens of
///    iterations, which is what turns "select a node" into a visible stall.
///
/// THE LAYOUT. Each project is a hub. Its own nodes orbit it in concentric rings, one ring per
/// node kind, so kind is readable from radius alone before any colour or label is processed.
/// Project hubs are themselves placed on a ring, and shared people go in an outer band since
/// they belong to no single project. Disconnected/unowned nodes get their own trailing cluster
/// rather than being dropped or piled at the origin.
enum GraphLayoutEngine {
    /// Ring radius per node kind, measured from the owning project hub. Ordered so the types
    /// that describe WORK sit closest to the project and provenance sits further out.
    private static func ringRadius(for kind: GraphNodeKind) -> CGFloat {
        switch kind {
        case .project: return 0
        case .projectItem: return 95
        case .decision: return 160
        case .session: return 215
        case .person: return 265
        }
    }

    /// Spacing that keeps a dense ring from collapsing into overlap: a ring grows outward when
    /// it holds more nodes than its circumference can seat at `minimumArcSpacing`.
    private static let minimumArcSpacing: CGFloat = 96
    /// These radii are deliberately tuned against NODE SIZE, not chosen for aesthetics in the
    /// abstract. Nodes draw at a radius of roughly 13-30 world units, so a diagram that spans
    /// ~1800 units fits a typical canvas at around 0.5 scale - which is where labels become
    /// legible (`GraphCanvas` hides them below 0.45). An earlier, airier version spanned ~2600
    /// units, fit at ~0.2, and rendered as unlabelled dots: correct, and unreadable.
    private static let projectHubRadius: CGFloat = 330
    /// How far beyond the project hubs the shared/unowned band sits.
    private static let unownedBandGap: CGFloat = 150

    /// Positions for every node in `snapshot`, keyed by node id. Nodes absent from the snapshot
    /// are absent from the result - the renderer treats a missing position as "do not draw",
    /// which is what keeps a stale layout from painting a node that filtering removed.
    static func layout(_ snapshot: GraphSnapshot) -> [GraphNodeID: CGPoint] {
        var positions: [GraphNodeID: CGPoint] = [:]

        // Deterministic project order. `projectNames` is a dictionary, so its iteration order is
        // unspecified - sorting by id is what makes hub placement reproducible.
        let projectNodes = snapshot.nodes.filter { $0.kind == .project }.sorted { $0.id < $1.id }
        let hubCentres = hubCentres(count: projectNodes.count)

        for (index, project) in projectNodes.enumerated() {
            let centre = hubCentres[index]
            positions[project.id] = centre

            let owned = snapshot.nodes.filter { $0.projectID == project.id.entityID && $0.kind != .project }
            for kind in GraphNodeKind.allCases where kind != .project {
                let ring = owned.filter { $0.kind == kind }.sorted { $0.id < $1.id }
                place(ring, around: centre, kind: kind, into: &positions)
            }
        }

        // Shared people, and anything else with no project of its own, sit outside every hub.
        // They are laid out relative to the whole diagram's centre so they read as belonging to
        // all of it rather than to whichever project happens to be nearest.
        let unowned = snapshot.nodes
            .filter { $0.projectID == nil && $0.kind != .project }
            .sorted { $0.id < $1.id }
        if !unowned.isEmpty {
            let diagramCentre = centroid(of: hubCentres)
            let radius = max(projectHubRadius + unownedBandGap, requiredRadius(for: unowned.count, minimum: 380))
            place(unowned, around: diagramCentre, explicitRadius: radius, into: &positions)
        }

        return positions
    }

    // MARK: Placement

    private static func place(
        _ nodes: [GraphNode],
        around centre: CGPoint,
        kind: GraphNodeKind,
        into positions: inout [GraphNodeID: CGPoint]
    ) {
        guard !nodes.isEmpty else { return }
        let radius = requiredRadius(for: nodes.count, minimum: ringRadius(for: kind))
        place(nodes, around: centre, explicitRadius: radius, into: &positions)
    }

    private static func place(
        _ nodes: [GraphNode],
        around centre: CGPoint,
        explicitRadius radius: CGFloat,
        into positions: inout [GraphNodeID: CGPoint]
    ) {
        guard !nodes.isEmpty else { return }
        // A single node on a ring is placed on the ring, not at the centre - otherwise it would
        // land exactly on top of the project hub.
        let step = (2 * CGFloat.pi) / CGFloat(nodes.count)
        // Quarter-turn offset so the first node of every ring starts at the top, which makes
        // rings visually comparable between projects instead of arbitrarily rotated.
        let startAngle = -CGFloat.pi / 2
        for (index, node) in nodes.enumerated() {
            let angle = startAngle + step * CGFloat(index)
            positions[node.id] = CGPoint(
                x: centre.x + radius * cos(angle),
                y: centre.y + radius * sin(angle)
            )
        }
    }

    /// Grows a ring so `count` nodes can sit on it without crowding: circumference must seat
    /// every node at `minimumArcSpacing`.
    private static func requiredRadius(for count: Int, minimum: CGFloat) -> CGFloat {
        guard count > 1 else { return minimum }
        let needed = (minimumArcSpacing * CGFloat(count)) / (2 * .pi)
        return max(minimum, needed)
    }

    /// Project hubs on their own ring. One project sits at the origin rather than being pushed
    /// out to an arbitrary point on a circle, which is what makes the extremely common
    /// single-project case look deliberate instead of off-centre.
    private static func hubCentres(count: Int) -> [CGPoint] {
        guard count > 1 else { return count == 1 ? [.zero] : [] }
        let radius = requiredRadius(for: count, minimum: projectHubRadius)
        let step = (2 * CGFloat.pi) / CGFloat(count)
        return (0..<count).map { index in
            let angle = -CGFloat.pi / 2 + step * CGFloat(index)
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// The tight bounding box of a laid-out graph, used by "fit to window" and by the initial
    /// zoom. Returns nil for an empty layout so callers show an empty state rather than fitting
    /// a degenerate rectangle.
    static func bounds(of positions: [GraphNodeID: CGPoint]) -> CGRect? {
        guard !positions.isEmpty else { return nil }
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }
}

// MARK: - Graph Viewport
/// Zoom/pan state and the world <-> screen maths, as a pure value. This lives here rather than
/// inside the SwiftUI view for the same reason the builder and the filter do: hit testing,
/// fit-to-window and focus are all behaviours worth asserting directly, and none of them need a
/// window to be correct. The view owns an instance and does nothing but render it.
struct GraphViewport: Equatable {
    var scale: CGFloat = 1
    /// Pan offset in SCREEN points, applied after scaling.
    var offset: CGSize = .zero

    /// Deliberately clamped. Below the minimum the graph is unreadable dust; above the maximum a
    /// drag moves the content further than the trackpad gesture suggests and feels broken.
    static let minimumScale: CGFloat = 0.1
    static let maximumScale: CGFloat = 3.0

    static func clampScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    /// World -> screen. The canvas centre is the origin of world space, so an empty pan shows
    /// the middle of the diagram rather than its top-left corner.
    func screenPosition(of world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: world.x * scale + offset.width + size.width / 2,
            y: world.y * scale + offset.height + size.height / 2
        )
    }

    /// Screen -> world, the exact inverse of `screenPosition(of:in:)`.
    func worldPosition(of screen: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (screen.x - offset.width - size.width / 2) / scale,
            y: (screen.y - offset.height - size.height / 2) / scale
        )
    }

    /// The node under a click, or nil. Picks the CLOSEST node within `radius` rather than the
    /// first one found, so overlapping nodes select predictably; ties break on node id so the
    /// result stays deterministic.
    func hitTest(
        screen point: CGPoint,
        in size: CGSize,
        positions: [GraphNodeID: CGPoint],
        radius: CGFloat
    ) -> GraphNodeID? {
        let world = worldPosition(of: point, in: size)
        // Compare in WORLD units so the tolerance is constant on screen at any zoom level.
        let worldRadius = radius / max(scale, 0.0001)
        return positions
            .compactMap { id, position -> (GraphNodeID, CGFloat)? in
                let distance = hypot(position.x - world.x, position.y - world.y)
                return distance <= worldRadius ? (id, distance) : nil
            }
            .min { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }?
            .0
    }

    /// Scales and centres so the whole graph is visible with a margin. `padding` is in screen
    /// points and keeps node labels from being clipped at the edges.
    static func fitting(_ bounds: CGRect, in size: CGSize, padding: CGFloat = 60) -> GraphViewport {
        let usableWidth = max(size.width - padding * 2, 1)
        let usableHeight = max(size.height - padding * 2, 1)
        let scale = clampScale(min(usableWidth / bounds.width, usableHeight / bounds.height))
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // Cancel the graph's own centre so it lands on the canvas centre.
        return GraphViewport(scale: scale, offset: CGSize(width: -centre.x * scale, height: -centre.y * scale))
    }

    /// Centres one world point without changing zoom - what "focus selected node" does. Zoom is
    /// preserved deliberately: yanking the zoom level around on selection is disorienting.
    func focused(on world: CGPoint) -> GraphViewport {
        GraphViewport(scale: scale, offset: CGSize(width: -world.x * scale, height: -world.y * scale))
    }
}
