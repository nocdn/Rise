import Foundation
import CoreGraphics

/// Adapted from Snap's ScreenshotPreviewController and ScreenshotFeedbackStyle.
/// Slow releases keep their placement; flicks use its velocity projection and corner spring.
/// Where Snap's preview would be flicked off the screen's side and dismissed, a floating window
/// is tucked instead: all but a tenth of it past that side, until it's brought back. Flicks off
/// the top or bottom go to a corner as any other.
struct FloatingVideoMotion {
    enum Phase { case idle, dragging, settling }
    enum Edge { case left, right }
    private(set) var phase = Phase.idle
    private(set) var frame: CGRect
    private(set) var velocity = CGVector.zero
    /// The side it's tucked past, or on its way to.
    private(set) var tucked: Edge?
    private var limits: CGRect
    private let area: CGRect
    private let contentInset: CGFloat
    /// The sides it may tuck past: not one another display carries on from.
    private let tuckable: Set<Edge>
    private var unconstrained: CGPoint
    private var target: CGPoint
    private var inputVelocity = CGVector.zero
    private var lastInput: TimeInterval?
    static let edgeInset: CGFloat = 8
    /// Screen points per second at lift-off, after accounting for a pause before release.
    static let flickSpeed: CGFloat = 650
    /// Snap's dismissal: a flick at least this fast whose projection crosses the side.
    static let tuckSpeed: CGFloat = 900
    static let projectionTime: CGFloat = 0.22
    /// How much of the window stays on the screen tucked.
    static let tuckedShowing: CGFloat = 0.1

    init(frame: CGRect, visibleFrame: CGRect, contentInset: CGFloat = 0, tucked: Edge? = nil, tuckable: Set<Edge> = [.left, .right]) {
        self.frame = frame; self.tucked = tucked; self.tuckable = tuckable
        area = visibleFrame; self.contentInset = contentInset
        limits = Self.originBounds(size: frame.size, visibleFrame: visibleFrame, contentInset: contentInset)
        unconstrained = frame.origin; target = frame.origin
    }

    /// Where the window's origin sits tucked past `edge`.
    static func tuckedX(_ edge: Edge, width: CGFloat, visibleFrame: CGRect, contentInset: CGFloat = 0) -> CGFloat {
        let content = width-2*contentInset
        switch edge {
        case .left: return visibleFrame.minX-content*(1-tuckedShowing)-contentInset
        case .right: return visibleFrame.maxX-content*tuckedShowing-contentInset
        }
    }
    func tuckedX(_ edge: Edge) -> CGFloat { Self.tuckedX(edge, width: frame.width, visibleFrame: area, contentInset: contentInset) }
    /// How far a window showing `content` is tucked: 0 on the screen, 1 tucked, by how much of it is past a side.
    static func tuckProgress(content: CGRect, visibleFrame: CGRect) -> CGFloat {
        let past = max(visibleFrame.minX-content.minX, content.maxX-visibleFrame.maxX, 0)
        return min(1, past/max(1, content.width*(1-tuckedShowing)))
    }
    private func tuckProgress(at origin: CGPoint) -> CGFloat {
        Self.tuckProgress(content: CGRect(origin: origin, size: frame.size).insetBy(dx: contentInset, dy: contentInset), visibleFrame: area)
    }
    /// Where it's coming to rest.
    var restingOrigin: CGPoint { phase == .idle ? frame.origin : target }
    /// Tucked, it may go as far as its tucked place on that side.
    private var minX: CGFloat { tucked == .left ? tuckedX(.left) : limits.minX }
    private var maxX: CGFloat { tucked == .right ? tuckedX(.right) : limits.maxX }
    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(maxX, max(minX, point.x)), y: min(limits.maxY, max(limits.minY, point.y)))
    }

    /// Back onto the screen from wherever it is on the way, keeping its height on the screen.
    mutating func untuck() {
        guard tucked != nil else { return }
        tucked = nil
        target = clamped(phase == .idle ? frame.origin : target)
        phase = .settling; lastInput = nil; inputVelocity = .zero
    }

    static func originBounds(size: CGSize, visibleFrame: CGRect, contentInset: CGFloat = 0) -> CGRect {
        let available = visibleFrame.insetBy(dx: edgeInset-contentInset, dy: edgeInset-contentInset)
        return CGRect(x: available.minX, y: available.minY,
                      width: max(0, available.width-size.width), height: max(0, available.height-size.height))
    }

    /// A nearly maximized browser can still be inset a few points from the
    /// display. Match its visible edges in that case; smaller browser windows
    /// keep PiP free to use the full screen's work area.
    static func placementArea(visibleFrame: CGRect, browserFrame: CGRect?) -> CGRect {
        guard let browserFrame else { return visibleFrame }
        let intersection = visibleFrame.intersection(browserFrame)
        guard !intersection.isNull, intersection.width >= visibleFrame.width*0.9,
              intersection.height >= visibleFrame.height*0.9 else { return visibleFrame }
        return intersection
    }

    mutating func begin(at timestamp: TimeInterval) {
        unconstrained = frame.origin; target = frame.origin
        inputVelocity = .zero; velocity = .zero; lastInput = timestamp; phase = .dragging
    }

    mutating func drag(by translation: CGVector, at timestamp: TimeInterval) {
        guard phase == .dragging else { return }
        unconstrained.x += translation.dx; unconstrained.y += translation.dy
        target = CGPoint(x: Self.rubberBand(unconstrained.x, min: minX, max: maxX),
                         y: Self.rubberBand(unconstrained.y, min: limits.minY, max: limits.maxY))
        if let lastInput {
            let elapsed = max(1.0/240, min(0.1, timestamp-lastInput))
            let response = CGFloat(1-exp(-elapsed/0.045))
            inputVelocity.dx += (translation.dx/elapsed-inputVelocity.dx)*response
            inputVelocity.dy += (translation.dy/elapsed-inputVelocity.dy)*response
        }
        lastInput = timestamp
    }

    mutating func end(at timestamp: TimeInterval, cancelled: Bool = false, reduceMotion: Bool = false) {
        guard phase == .dragging else { return }
        let decay = CGFloat(exp(-max(0, timestamp-(lastInput ?? timestamp))/0.045))
        let release = CGVector(dx: inputVelocity.dx*decay, dy: inputVelocity.dy*decay)
        let speed = hypot(release.dx, release.dy)
        let flick = !cancelled && speed >= Self.flickSpeed
        velocity = !flick || reduceMotion ? .zero : release
        if !cancelled, speed >= Self.tuckSpeed, let edge = tuckEdge(for: release) {
            // Keeps on its way, out to its tucked place at that height.
            let y = target.y+release.dy*(reduceMotion ? 0 : Self.projectionTime)
            tucked = edge
            target = CGPoint(x: tuckedX(edge), y: min(limits.maxY, max(limits.minY, y)))
            glideIn()
            phase = .settling; lastInput = nil; inputVelocity = .zero
            return
        }
        if let tucked {
            // Pushed back towards its side, or let go still mostly tucked, it stays tucked.
            let toward = tucked == .left ? release.dx < 0 : release.dx > 0
            if flick ? toward : tuckProgress(at: cancelled ? frame.origin : target) > 0.5 {
                target = CGPoint(x: tuckedX(tucked), y: clamped(cancelled ? frame.origin : target).y)
                glideIn()
                phase = .settling; lastInput = nil; inputVelocity = .zero
                return
            }
            self.tucked = nil
        }
        if !flick {
            target = clamped(cancelled ? frame.origin : target)
            phase = .settling; lastInput = nil; inputVelocity = .zero
            return
        }
        let flickSpeed = hypot(velocity.dx, velocity.dy)
        if flickSpeed > 5_000 { velocity.dx *= 5_000/flickSpeed; velocity.dy *= 5_000/flickSpeed }
        // Remove outward momentum at an edge, just as Snap does before settling.
        if frame.minX <= limits.minX && velocity.dx < 0 || frame.minX >= limits.maxX && velocity.dx > 0 { velocity.dx = 0 }
        if frame.minY <= limits.minY && velocity.dy < 0 || frame.minY >= limits.maxY && velocity.dy > 0 { velocity.dy = 0 }
        let projection: CGFloat = reduceMotion ? 0 : Self.projectionTime
        let center = CGPoint(x: target.x+frame.width/2+velocity.dx*projection,
                             y: target.y+frame.height/2+velocity.dy*projection)
        let corners = [CGPoint(x: limits.minX, y: limits.minY), CGPoint(x: limits.maxX, y: limits.minY),
                       CGPoint(x: limits.minX, y: limits.maxY), CGPoint(x: limits.maxX, y: limits.maxY)]
        target = corners.min {
            hypot($0.x+frame.width/2-center.x, $0.y+frame.height/2-center.y)
                < hypot($1.x+frame.width/2-center.x, $1.y+frame.height/2-center.y)
        } ?? frame.origin
        phase = .settling; lastInput = nil; inputVelocity = .zero
    }

    /// Display-link driven, with Snap's bounds on the integration time step.
    mutating func step(elapsed: TimeInterval, reduceMotion: Bool = false) {
        let dt = max(1.0/240, min(1.0/30, elapsed))
        switch phase {
        case .idle: return
        case .dragging:
            let response = CGFloat(1-exp(-dt/0.025))
            frame.origin.x += (target.x-frame.minX)*response
            frame.origin.y += (target.y-frame.minY)*response
        case .settling:
            let stiffness: CGFloat = reduceMotion ? 700 : 340
            let damping = 2*0.90*sqrt(stiffness)
            velocity.dx += (stiffness*(target.x-frame.minX)-damping*velocity.dx)*dt
            velocity.dy += (stiffness*(target.y-frame.minY)-damping*velocity.dy)*dt
            var next = CGPoint(x: frame.minX+velocity.dx*dt, y: frame.minY+velocity.dy*dt)
            Self.constrain(&next.x, velocity: &velocity.dx, previous: frame.minX, min: min(minX, target.x), max: max(maxX, target.x))
            Self.constrain(&next.y, velocity: &velocity.dy, previous: frame.minY, min: limits.minY, max: limits.maxY)
            frame.origin = next
            if hypot(target.x-next.x, target.y-next.y) <= 0.45 && hypot(velocity.dx, velocity.dy) <= 7 {
                frame.origin = target; velocity = .zero; phase = .idle
            }
        }
    }

    /// Its tucked place is a hard stop, so a flick is slowed just enough that the settling spring
    /// comes to it rather than striking it: a nearly critical spring passes its target only when
    /// it's moving faster than its frequency times the distance left.
    private mutating func glideIn() {
        let limit = 0.9*sqrt(340)*abs(target.x-frame.minX)
        velocity.dx = min(limit, max(-limit, velocity.dx))
        let speed = hypot(velocity.dx, velocity.dy)
        if speed > 5_000 { velocity.dx *= 5_000/speed; velocity.dy *= 5_000/speed }
    }

    /// The side a release would have thrown Snap's preview off: its projection past that side,
    /// further than past the top or bottom.
    private func tuckEdge(for velocity: CGVector) -> Edge? {
        let center = CGPoint(x: target.x+frame.width/2+velocity.dx*Self.projectionTime,
                             y: target.y+frame.height/2+velocity.dy*Self.projectionTime)
        let left = velocity.dx < 0 ? area.minX-center.x : 0, right = velocity.dx > 0 ? center.x-area.maxX : 0
        let vertical = max(velocity.dy < 0 ? area.minY-center.y : 0, velocity.dy > 0 ? center.y-area.maxY : 0, 0)
        if left > 0, left >= vertical, tuckable.contains(.left) { return .left }
        if right > 0, right >= vertical, tuckable.contains(.right) { return .right }
        return nil
    }

    private static func rubberBand(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let boundary = value < min ? min : max
        guard value < min || value > max else { return value }
        let overshoot = value-boundary
        return boundary+overshoot/(1+abs(overshoot)/34)
    }

    private static func constrain(_ value: inout CGFloat, velocity: inout CGFloat, previous: CGFloat, min: CGFloat, max: CGFloat) {
        if (previous >= min && value < min) || (previous < min && value >= min) { value = min; velocity = 0 }
        if (previous <= max && value > max) || (previous > max && value <= max) { value = max; velocity = 0 }
    }
}

/// A floating window grows a touch while two fingers move it: up with a light bounce as they
/// land, and back to its size on release, settled before a flick reaches its corner.
struct FloatingLift {
    static let scale: CGFloat = 1.02
    struct Spring { let response: Double, bounce: Double }
    static let up = Spring(response: 0.32, bounce: 0.35), down = Spring(response: 0.26, bounce: 0.12)
    private(set) var value: CGFloat = 1
    private(set) var velocity: CGFloat = 0
    private(set) var lifted = false
    var isResting: Bool { value == (lifted ? Self.scale : 1) && velocity == 0 }

    mutating func lift(_ lifted: Bool) { self.lifted = lifted }

    /// Display-link driven, in small steps so the stiff spring stays exact at any frame rate.
    mutating func step(elapsed: TimeInterval) {
        let spring = lifted ? Self.up : Self.down, target = lifted ? Self.scale : 1
        let stiffness = pow(2*Double.pi/spring.response, 2), damping = 4*Double.pi*(1-spring.bounce)/spring.response
        var remaining = max(0, min(1.0/30, elapsed))
        while remaining > 0 {
            let dt = min(1.0/480, remaining); remaining -= dt
            velocity += CGFloat(stiffness*Double(target-value)-damping*Double(velocity))*CGFloat(dt)
            value += velocity*CGFloat(dt)
        }
        if abs(value-target) < 0.0004 && abs(velocity) < 0.01 { value = target; velocity = 0 }
    }
}
