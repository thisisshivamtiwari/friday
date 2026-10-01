import SwiftUI

/// Jarvis-style animated avatar: a glowing amber energy core, rotating broken rings, an
/// outer tick dial, and flickering radiating lines - replaces the plain status dot as the
/// primary "is it listening / thinking" indicator. Driven entirely by Canvas + TimelineView,
/// so animation is continuous and smooth without a Timer or stored animation state.
///
/// The redraw rate is NOT fixed at the display's max refresh rate - it adapts to how much
/// motion is actually worth paying for: full rate only while a response is actively
/// streaming (the one moment fluid motion matters), a modest rate while idly listening, a
/// slow ambient rate while stopped, and effectively paused while the overlay window isn't
/// even visible (covered by another window, minimized, or explicitly hidden) - a fixed
/// `.animation` schedule keeps firing every frame forever regardless of any of that, which
/// was found to be a real, continuous main-thread CPU cost for as long as the app runs.
struct AvatarBlobView: View {
    /// Overall on/off state - dim and near-static when false (Stop listening / no session)
    var isActive: Bool
    /// True while a suggestion/reply is actively streaming in - speeds up and brightens,
    /// so the blob visibly reacts the instant Gemini starts responding
    var isStreaming: Bool
    /// True when the overlay window isn't actually on screen right now - see
    /// OverlayVisibilityState. Collapses the redraw rate to effectively nothing rather than
    /// continuing to animate a view nobody could possibly be seeing.
    var isPaused: Bool = false

    /// PeriodicTimelineSchedule rather than `.animation` specifically so the rate can vary
    /// by state without an opaque-return-type branching problem (`.animation` and
    /// `.periodic` are different concrete Schedule types, and TimelineView is generic over
    /// one fixed type) - only the `by:` interval changes, the schedule TYPE stays constant.
    private var refreshInterval: TimeInterval {
        if isPaused { return 30 }
        if isStreaming { return 1.0 / 60.0 }
        if isActive { return 1.0 / 20.0 }
        return 1.0 / 8.0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: refreshInterval)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let t = timeline.date.timeIntervalSinceReferenceDate

                let speed = isStreaming ? 2.2 : (isActive ? 1.0 : 0.35)
                let brightness = isStreaming ? 1.0 : (isActive ? 0.75 : 0.4)
                let coreColor = Color(red: 1.0, green: 0.72, blue: 0.28)
                let pulse = 0.85 + 0.15 * sin(t * speed * 2.4)

                drawTickDial(context: context, center: center, radius: radius, t: t, speed: speed, brightness: brightness, color: coreColor)
                drawRotatingRings(context: context, center: center, radius: radius, t: t, speed: speed, brightness: brightness, color: coreColor)
                drawRadiatingLines(context: context, center: center, radius: radius, t: t, speed: speed, brightness: brightness, color: coreColor)
                drawGlowHalo(context: context, center: center, radius: radius, pulse: pulse, brightness: brightness, color: coreColor)
                drawCore(context: context, center: center, radius: radius, pulse: pulse, color: coreColor)
            }
        }
        .drawingGroup()
    }

    /// Batches all 48 ticks into two Paths (major/minor) and two stroke() calls instead of
    /// 48 separate ones - same visual result, far fewer discrete graphics-context calls per
    /// frame on whatever frames still render at full rate.
    private func drawTickDial(context: GraphicsContext, center: CGPoint, radius: Double, t: Double, speed: Double, brightness: Double, color: Color) {
        var majorPath = Path()
        var minorPath = Path()
        for i in 0..<48 {
            let angle = Angle(degrees: Double(i) / 48 * 360 + t * speed * 6)
            let isMajor = i % 4 == 0
            let inner = radius * (isMajor ? 0.86 : 0.90)
            let outer = radius * 0.96
            let start = point(center: center, radius: inner, angle: angle)
            let end = point(center: center, radius: outer, angle: angle)
            if isMajor {
                majorPath.move(to: start)
                majorPath.addLine(to: end)
            } else {
                minorPath.move(to: start)
                minorPath.addLine(to: end)
            }
        }
        context.stroke(majorPath, with: .color(color.opacity(brightness * 0.55)), lineWidth: 1.4)
        context.stroke(minorPath, with: .color(color.opacity(brightness * 0.25)), lineWidth: 0.8)
    }

    private func drawRotatingRings(context: GraphicsContext, center: CGPoint, radius: Double, t: Double, speed: Double, brightness: Double, color: Color) {
        for ringIndex in 0..<2 {
            let ringRadius = radius * (0.62 + Double(ringIndex) * 0.16)
            let direction: Double = ringIndex.isMultiple(of: 2) ? 1 : -1
            let rotation = t * speed * 18 * direction
            var path = Path()
            let segmentCount = 5
            for s in 0..<segmentCount {
                let start = Double(s) / Double(segmentCount) * 360 + rotation
                path.addArc(center: center, radius: ringRadius, startAngle: .degrees(start), endAngle: .degrees(start + 40), clockwise: false)
            }
            context.stroke(path, with: .color(color.opacity(brightness * 0.5)), lineWidth: 1.6)
        }
    }

    private func drawRadiatingLines(context: GraphicsContext, center: CGPoint, radius: Double, t: Double, speed: Double, brightness: Double, color: Color) {
        for i in 0..<24 {
            let seed = Double(i) * 12.9898
            let angle = Angle(degrees: Double(i) / 24 * 360 + sin(t * 0.6 + seed) * 4)
            let flicker = (sin(t * speed * 2 + seed) + 1) / 2
            let length = radius * (0.22 + 0.3 * flicker)
            var path = Path()
            path.move(to: center)
            path.addLine(to: point(center: center, radius: length, angle: angle))
            context.stroke(path, with: .color(color.opacity(brightness * 0.35 * flicker)), lineWidth: 1)
        }
    }

    private func drawGlowHalo(context: GraphicsContext, center: CGPoint, radius: Double, pulse: Double, brightness: Double, color: Color) {
        let haloRadius = radius * 0.62 * pulse
        let gradient = Gradient(colors: [color.opacity(brightness * 0.28), color.opacity(0)])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: haloRadius)
        )
    }

    private func drawCore(context: GraphicsContext, center: CGPoint, radius: Double, pulse: Double, color: Color) {
        let coreRadius = radius * 0.30 * pulse
        let gradient = Gradient(colors: [.white, color, color.opacity(0)])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)),
            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: coreRadius)
        )
    }

    private func point(center: CGPoint, radius: Double, angle: Angle) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle.radians), y: center.y + radius * sin(angle.radians))
    }
}
