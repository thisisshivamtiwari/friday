import XCTest
import CoreGraphics
@testable import FounderOfficeCopilotCore

/// Covers the zoom/pan/hit-test maths. This lives in `GraphViewport` rather than inside the
/// SwiftUI view precisely so it can be asserted here - "clicking a node selects that node" is a
/// behaviour, not a rendering detail, and it should not need a window to verify.
final class GraphViewportTests: XCTestCase {
    private let size = CGSize(width: 800, height: 600)

    // MARK: Coordinate mapping

    func testWorldOriginMapsToTheCanvasCentreWhenUnpanned() {
        let viewport = GraphViewport()
        XCTAssertEqual(viewport.screenPosition(of: .zero, in: size), CGPoint(x: 400, y: 300))
    }

    func testScreenAndWorldConversionsAreExactInverses() {
        let viewport = GraphViewport(scale: 1.7, offset: CGSize(width: -120, height: 64))
        for world in [CGPoint(x: 0, y: 0), CGPoint(x: 250, y: -80), CGPoint(x: -940, y: 512)] {
            let roundTripped = viewport.worldPosition(of: viewport.screenPosition(of: world, in: size), in: size)
            XCTAssertEqual(roundTripped.x, world.x, accuracy: 0.0001)
            XCTAssertEqual(roundTripped.y, world.y, accuracy: 0.0001)
        }
    }

    func testScaleIsClampedToAUsableRange() {
        XCTAssertEqual(GraphViewport.clampScale(1000), GraphViewport.maximumScale)
        XCTAssertEqual(GraphViewport.clampScale(0.0001), GraphViewport.minimumScale)
        XCTAssertEqual(GraphViewport.clampScale(1.5), 1.5)
    }

    // MARK: Hit testing

    private func nodeID(_ kind: GraphNodeKind = .projectItem) -> GraphNodeID {
        GraphNodeID(kind: kind, entityID: UUID())
    }

    func testClickingOnANodeSelectsIt() {
        let target = nodeID()
        let positions = [target: CGPoint(x: 100, y: 50)]
        let viewport = GraphViewport()
        let screen = viewport.screenPosition(of: CGPoint(x: 100, y: 50), in: size)
        XCTAssertEqual(viewport.hitTest(screen: screen, in: size, positions: positions, radius: 26), target)
    }

    func testClickingEmptySpaceSelectsNothing() {
        let positions = [nodeID(): CGPoint(x: 100, y: 50)]
        let viewport = GraphViewport()
        let far = viewport.screenPosition(of: CGPoint(x: 900, y: 900), in: size)
        XCTAssertNil(viewport.hitTest(screen: far, in: size, positions: positions, radius: 26))
    }

    /// Overlapping nodes must resolve to the CLOSEST one, not whichever the dictionary happened
    /// to yield first - otherwise the same click selects different nodes on different runs.
    func testOverlappingNodesResolveToTheClosestAndDoSoDeterministically() {
        let near = nodeID(), far = nodeID()
        let positions = [near: CGPoint(x: 100, y: 100), far: CGPoint(x: 118, y: 100)]
        let viewport = GraphViewport()
        let screen = viewport.screenPosition(of: CGPoint(x: 102, y: 100), in: size)
        let first = viewport.hitTest(screen: screen, in: size, positions: positions, radius: 40)
        XCTAssertEqual(first, near)
        for _ in 0..<20 {
            XCTAssertEqual(viewport.hitTest(screen: screen, in: size, positions: positions, radius: 40), first)
        }
    }

    /// The click tolerance is specified in SCREEN points, so it must stay constant on screen as
    /// the user zooms - a zoomed-out graph should not become impossible to click.
    func testHitToleranceIsConstantOnScreenAcrossZoomLevels() {
        let target = nodeID()
        let world = CGPoint(x: 200, y: 120)
        let positions = [target: world]
        for scale in [0.25, 0.5, 1.0, 2.0, 3.0] as [CGFloat] {
            let viewport = GraphViewport(scale: scale, offset: .zero)
            let centre = viewport.screenPosition(of: world, in: size)
            // 20 screen points away, comfortably inside a 26-point radius at every zoom level.
            let nearby = CGPoint(x: centre.x + 20, y: centre.y)
            XCTAssertEqual(viewport.hitTest(screen: nearby, in: size, positions: positions, radius: 26), target,
                           "a click 20pt from the node must hit it at scale \(scale)")
        }
    }

    func testHitTestingAnEmptyGraphIsSafe() {
        XCTAssertNil(GraphViewport().hitTest(screen: CGPoint(x: 10, y: 10), in: size, positions: [:], radius: 26))
    }

    // MARK: Fit and focus

    func testFittingCentresTheGraphAndKeepsEveryNodeOnScreen() {
        let bounds = CGRect(x: -500, y: -250, width: 1000, height: 500)
        let viewport = GraphViewport.fitting(bounds, in: size)

        let centre = viewport.screenPosition(of: CGPoint(x: bounds.midX, y: bounds.midY), in: size)
        XCTAssertEqual(centre.x, size.width / 2, accuracy: 0.001)
        XCTAssertEqual(centre.y, size.height / 2, accuracy: 0.001)

        for corner in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
            let point = viewport.screenPosition(of: corner, in: size)
            XCTAssertTrue((0...size.width).contains(point.x), "x \(point.x) off screen")
            XCTAssertTrue((0...size.height).contains(point.y), "y \(point.y) off screen")
        }
    }

    func testFittingAVeryLargeGraphStaysWithinTheScaleClamp() {
        let viewport = GraphViewport.fitting(CGRect(x: 0, y: 0, width: 500_000, height: 500_000), in: size)
        XCTAssertGreaterThanOrEqual(viewport.scale, GraphViewport.minimumScale)
    }

    func testFittingATinyGraphDoesNotZoomBeyondTheMaximum() {
        let viewport = GraphViewport.fitting(CGRect(x: 0, y: 0, width: 1, height: 1), in: size)
        XCTAssertLessThanOrEqual(viewport.scale, GraphViewport.maximumScale)
    }

    /// Focus centres the node and deliberately PRESERVES zoom - changing both at once is
    /// disorienting, and the user's chosen zoom is information.
    func testFocusCentresTheNodeWithoutChangingZoom() {
        let viewport = GraphViewport(scale: 1.8, offset: CGSize(width: 300, height: -90))
        let world = CGPoint(x: -420, y: 260)
        let focused = viewport.focused(on: world)

        XCTAssertEqual(focused.scale, viewport.scale)
        let centre = focused.screenPosition(of: world, in: size)
        XCTAssertEqual(centre.x, size.width / 2, accuracy: 0.001)
        XCTAssertEqual(centre.y, size.height / 2, accuracy: 0.001)
    }

    /// Fit must work off the layout the engine actually produces, not just synthetic rectangles.
    func testFittingARealLayoutKeepsEveryNodeOnScreen() {
        let project = Project(name: "Research")
        let sessionID = UUID()
        let items = (0..<9).map { ProjectItem(projectID: project.id, kind: .task, name: "Item \($0)", sourceSessionID: sessionID) }
        let decisions = (0..<6).map { Decision(projectID: project.id, statement: "Decision \($0)", sourceSessionID: sessionID) }
        let snapshot = GraphSnapshotBuilder.build(
            projects: [project], items: items, decisions: decisions,
            sessionLinks: [ProjectSessionLink(sessionID: sessionID, projectID: project.id)],
            people: [], sessionTitles: [sessionID: "Meeting"], sessionDates: [:]
        )
        let positions = GraphLayoutEngine.layout(snapshot)
        let bounds = GraphLayoutEngine.bounds(of: positions)
        XCTAssertNotNil(bounds)

        let viewport = GraphViewport.fitting(bounds!, in: size)
        for point in positions.values {
            let screen = viewport.screenPosition(of: point, in: size)
            XCTAssertTrue((-1...size.width + 1).contains(screen.x))
            XCTAssertTrue((-1...size.height + 1).contains(screen.y))
        }
    }
}
