import Foundation
import CoreGraphics

/// Adapted from Snap's ScreenshotPreviewController and ScreenshotFeedbackStyle.
/// Slow releases keep their placement; flicks use its velocity projection and corner spring.
/// A video never takes the preview's off-screen dismissal branch.
struct FloatingVideoMotion {
    enum Phase { case idle, dragging, settling }
    private(set) var phase = Phase.idle
    private(set) var frame: CGRect
    private(set) var velocity = CGVector.zero
    private var limits: CGRect
    private var unconstrained: CGPoint
    private var target: CGPoint
    private var inputVelocity = CGVector.zero
    private var lastInput: TimeInterval?
    static let edgeInset: CGFloat = 8
    /// Screen points per second at lift-off, after accounting for a pause before release.
    static let flickSpeed: CGFloat = 650

    init(frame: CGRect, visibleFrame: CGRect, contentInset: CGFloat = 0) {
        self.frame = frame
        limits = Self.originBounds(size: frame.size, visibleFrame: visibleFrame, contentInset: contentInset)
        unconstrained = frame.origin; target = frame.origin
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
        target = CGPoint(x: Self.rubberBand(unconstrained.x, min: limits.minX, max: limits.maxX),
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
        let flick = !cancelled && hypot(release.dx, release.dy) >= Self.flickSpeed
        velocity = !flick || reduceMotion ? .zero : release
        if !flick {
            let placement = cancelled ? frame.origin : target
            target = CGPoint(x: min(limits.maxX, max(limits.minX, placement.x)),
                             y: min(limits.maxY, max(limits.minY, placement.y)))
            phase = .settling; lastInput = nil; inputVelocity = .zero
            return
        }
        let speed = hypot(velocity.dx, velocity.dy)
        if speed > 5_000 { velocity.dx *= 5_000/speed; velocity.dy *= 5_000/speed }
        // Remove outward momentum at an edge, just as Snap does before settling.
        if frame.minX <= limits.minX && velocity.dx < 0 || frame.minX >= limits.maxX && velocity.dx > 0 { velocity.dx = 0 }
        if frame.minY <= limits.minY && velocity.dy < 0 || frame.minY >= limits.maxY && velocity.dy > 0 { velocity.dy = 0 }
        let projection: CGFloat = reduceMotion ? 0 : 0.22
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
            Self.constrain(&next.x, velocity: &velocity.dx, previous: frame.minX, min: limits.minX, max: limits.maxX)
            Self.constrain(&next.y, velocity: &velocity.dy, previous: frame.minY, min: limits.minY, max: limits.maxY)
            frame.origin = next
            if hypot(target.x-next.x, target.y-next.y) <= 0.45 && hypot(velocity.dx, velocity.dy) <= 7 {
                frame.origin = target; velocity = .zero; phase = .idle
            }
        }
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
