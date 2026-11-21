import Foundation
import CoreGraphics

/// Adapted from Snap's ScreenshotPreviewController and ScreenshotFeedbackStyle.
/// Slow releases keep their placement; flicks use its velocity projection and corner spring.
/// Where Snap's preview would be flicked off the screen's side and dismissed, a floating window
/// is tucked instead: all but a tenth of it past that side, until it's brought back, to where it
/// was before. Flicks off the top or bottom go to a corner as any other.
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
    /// Where it was when the fingers or the pointer took it, and whether it was tucked then.
    private var start = CGPoint.zero, startedTucked = false, grabbedX: CGFloat = 0
    /// Where the drag has taken it lately, so a flick off a side can come back to where the flick
    /// began, not where the drag did: moved down and flung away in one go, it comes back down there.
    private var trail: [(time: TimeInterval, origin: CGPoint)] = []
    /// The pace below which a drag toward a side isn't yet the flick that tucks it.
    static let flickStartSpeed: CGFloat = 300
    /// Where it was as the flick that tucked it began, and the height it was tucked at: brought
    /// back, it goes to that place, as far up or down as it was moved while tucked.
    struct Home: Equatable { var origin: CGPoint; var tuckedY: CGFloat }
    private(set) var home: Home?
    static let edgeInset: CGFloat = 8
    /// Screen points per second at lift-off, after accounting for a pause before release.
    static let flickSpeed: CGFloat = 650
    /// Snap's dismissal: a flick at least this fast whose projection crosses the side.
    static let tuckSpeed: CGFloat = 900
    static let projectionTime: CGFloat = 0.22
    /// How much of the window stays on the screen tucked.
    static let tuckedShowing: CGFloat = 0.1
    /// Tucked, flicks that move it up and down out of the way shouldn't bring it out: only one
    /// out from the side this fast, mostly sideways, after the fingers have gone this far does.
    static let untuckSpeed: CGFloat = 650, untuckTravel: CGFloat = 28, untuckSideways: CGFloat = 1.5

    init(frame: CGRect, visibleFrame: CGRect, contentInset: CGFloat = 0, tucked: Edge? = nil, tuckable: Set<Edge> = [.left, .right],
         home: Home? = nil) {
        self.frame = frame; self.tucked = tucked; self.tuckable = tuckable; self.home = tucked == nil ? nil : home
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

    /// Back onto the screen from wherever it is on the way, to where it was before it was tucked.
    mutating func untuck() {
        guard tucked != nil else { return }
        tucked = nil
        target = comingOut(from: phase == .idle ? frame.origin : target)
        phase = .settling; lastInput = nil; inputVelocity = .zero
    }
    /// Where an untucked window from `point` goes: its place before it was tucked, moved up or down
    /// as far as it was while tucked; or, not known, onto the screen at its height.
    private mutating func comingOut(from point: CGPoint) -> CGPoint {
        defer { home = nil }
        guard let home else { return clamped(point) }
        return clamped(CGPoint(x: home.origin.x, y: home.origin.y+point.y-home.tuckedY))
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
        // Caught on its way somewhere, that's where it was: where it goes back to, tucked now.
        start = phase == .settling ? target : frame.origin; startedTucked = tucked != nil; grabbedX = frame.minX
        trail = [(timestamp, start)]
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
        trail.append((timestamp, target))
        // Enough to look back past a flick, and no more.
        if let first = trail.first, timestamp-first.time > 1, trail.count > 2 { trail.removeFirst() }
    }
    /// Where it was as the flick off `edge` that ended the drag began: back along the drag for as
    /// long as it was heading fast for that side, to where it was going another way or slowly. On
    /// the screen, as it showed there.
    private func flickOrigin(toward edge: Edge) -> CGPoint {
        var origin = trail.first?.origin ?? start
        for index in trail.indices.dropFirst().reversed() {
            let from = trail[index-1], to = trail[index]
            let dx = to.origin.x-from.origin.x, dy = to.origin.y-from.origin.y
            let toward = edge == .left ? -dx : dx
            let speed = hypot(dx, dy)/CGFloat(max(1.0/240, to.time-from.time))
            guard toward > 0, toward >= abs(dy), speed >= Self.flickStartSpeed else { origin = to.origin; break }
        }
        return CGPoint(x: min(limits.maxX, max(limits.minX, origin.x)), y: min(limits.maxY, max(limits.minY, origin.y)))
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
            let y = min(limits.maxY, max(limits.minY, target.y+release.dy*(reduceMotion ? 0 : Self.projectionTime)))
            if !startedTucked { home = Home(origin: flickOrigin(toward: edge), tuckedY: y) }
            tucked = edge
            target = CGPoint(x: tuckedX(edge), y: y)
            glideIn()
            phase = .settling; lastInput = nil; inputVelocity = .zero
            return
        }
        if let tucked {
            // Flicked out from its side, it comes back to where it was; let go mostly out, it stays
            // there. Otherwise it stays tucked, flicked up or down as far as the flick throws it.
            let place = cancelled ? frame.origin : target
            let outward = tucked == .left ? release.dx : -release.dx
            let travelled = tucked == .left ? unconstrained.x-grabbedX : grabbedX-unconstrained.x
            let mostlyOut = tuckProgress(at: place) <= 0.5
            let deliberate = outward >= Self.untuckSpeed && outward >= Self.untuckSideways*abs(release.dy) && travelled >= Self.untuckTravel
            let flickedOut = flick && (deliberate || mostlyOut && outward >= 0)
            let draggedOut = !flick && mostlyOut
            guard flickedOut || draggedOut else {
                let y = place.y+(flick && !reduceMotion ? release.dy*Self.projectionTime : 0)
                target = CGPoint(x: tuckedX(tucked), y: min(limits.maxY, max(limits.minY, y)))
                glideIn()
                phase = .settling; lastInput = nil; inputVelocity = .zero
                return
            }
            self.tucked = nil
            if flickedOut {
                target = comingOut(from: place)
                arrive()
                phase = .settling; lastInput = nil; inputVelocity = .zero
                return
            }
            home = nil
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

    /// On its way back out, the flick carries it no further than it's going, as `glideIn` does.
    private mutating func arrive() {
        let rate = 0.9*sqrt(340)
        velocity.dx = min(rate*abs(target.x-frame.minX), max(-rate*abs(target.x-frame.minX), velocity.dx))
        velocity.dy = min(rate*abs(target.y-frame.minY), max(-rate*abs(target.y-frame.minY), velocity.dy))
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
