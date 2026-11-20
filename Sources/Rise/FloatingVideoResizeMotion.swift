import Foundation
import CoreGraphics

/// Pinch directly follows the fingers inside its limits. Beyond either limit,
/// a short rubber band provides resistance and a spring restores the size.
struct FloatingVideoResizeMotion {
    enum Phase { case idle, pinching, settling }
    private(set) var phase = Phase.idle
    private(set) var width: CGFloat
    private(set) var velocity: CGFloat = 0
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    private let aspect: CGFloat
    private let visibleFrame: CGRect
    private let anchor: CGPoint
    private let anchorFraction: CGPoint
    private let initialWidth: CGFloat
    private var requestedWidth: CGFloat
    private var target: CGFloat

    /// `maximumSize` is the source page's viewport, which holds the canvas.
    init(videoFrame: CGRect, visibleFrame: CGRect, maximumSize: CGSize? = nil) {
        let aspect = videoFrame.width/videoFrame.height
        self.aspect = aspect; self.visibleFrame = visibleFrame
        let available = visibleFrame.insetBy(dx: FloatingVideoMotion.edgeInset, dy: FloatingVideoMotion.edgeInset)
        let viewport = maximumSize.map { min($0.width, $0.height*aspect) } ?? .infinity
        maximumWidth = max(1, min(760, available.width*0.65, available.height*0.70*aspect, viewport))
        minimumWidth = min(180, maximumWidth)
        width = videoFrame.width; initialWidth = width; target = width
        let boundary = min(maximumWidth, max(minimumWidth, width))
        let give = min(19.999, max(-19.999, width-boundary))
        // Invert the rubber band when grabbing an unfinished bounce, so the
        // first pinch event keeps the picture exactly where it already is.
        requestedWidth = boundary + give/(0.18*(1-abs(give)/20))
        let x: CGFloat = abs(videoFrame.minX-available.minX) < 16 ? 0 : abs(videoFrame.maxX-available.maxX) < 16 ? 1 : 0.5
        let y: CGFloat = abs(videoFrame.minY-available.minY) < 16 ? 0 : abs(videoFrame.maxY-available.maxY) < 16 ? 1 : 0.5
        anchorFraction = CGPoint(x: x, y: y)
        anchor = CGPoint(x: videoFrame.minX+videoFrame.width*x, y: videoFrame.minY+videoFrame.height*y)
    }

    var videoFrame: CGRect {
        let size = CGSize(width: width, height: width/aspect)
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: visibleFrame)
        let origin = CGPoint(x: min(limits.maxX, max(limits.minX, anchor.x-size.width*anchorFraction.x)),
                             y: min(limits.maxY, max(limits.minY, anchor.y-size.height*anchorFraction.y)))
        return CGRect(origin: origin, size: size)
    }

    mutating func begin() { phase = .pinching }
    mutating func magnify(by delta: CGFloat) {
        guard phase == .pinching, delta.isFinite else { return }
        requestedWidth = min(maximumWidth*100, max(-maximumWidth*100, requestedWidth+initialWidth*delta))
        let boundary = min(maximumWidth, max(minimumWidth, requestedWidth))
        let overshoot = requestedWidth-boundary
        // Only 18% of motion crosses the boundary, with at most 20pt of give.
        width = boundary + overshoot*0.18/(1+abs(overshoot)*0.18/20)
    }
    mutating func end(reduceMotion: Bool = false) {
        target = min(maximumWidth, max(minimumWidth, width)); velocity = 0
        if reduceMotion || target == width { width = target; phase = .idle }
        else { phase = .settling }
    }
    mutating func finish() {
        width = min(maximumWidth, max(minimumWidth, width)); velocity = 0; phase = .idle
    }
    mutating func step(elapsed: TimeInterval, reduceMotion: Bool = false) {
        guard phase == .settling else { return }
        if reduceMotion { finish(); return }
        let elapsed = max(0, min(1.0/30, elapsed))
        let steps = max(1, Int(ceil(elapsed*120)))
        let dt = CGFloat(elapsed/Double(steps))
        for _ in 0..<steps {
            velocity += (320*(target-width)-2*0.82*sqrt(320)*velocity)*dt
            width += velocity*dt
        }
        if abs(target-width) < 0.04 && abs(velocity) < 0.4 { width = target; velocity = 0; phase = .idle }
    }
}

/// Dragging one of the video's edges or corners resizes it about the opposite one, keeping its
/// shape: the pointer's way across that edge, or along a corner's diagonal, sets its size, within
/// the pinch's limits and the room the screen leaves. The other way, it keeps its middle, or the
/// side of the screen it's against.
struct FloatingVideoEdgeResize {
    /// The sides being pulled: x is -1 for the left and 1 for the right, y -1 for the bottom and
    /// 1 for the top (in screen coordinates), 0 for neither.
    struct Handle: Equatable { var x: Int; var y: Int }
    let handle: Handle
    private let start: CGRect, pointer: CGPoint, visibleFrame: CGRect
    private let minimumWidth: CGFloat, maximumWidth: CGFloat
    /// How far an edge takes the pointer: a little outside the video and a little in, and further
    /// along its sides from each corner.
    static let outside: CGFloat = 4, inside: CGFloat = 5, corner: CGFloat = 16

    init(handle: Handle, videoFrame: CGRect, pointer: CGPoint, visibleFrame: CGRect, minimumWidth: CGFloat, maximumWidth: CGFloat) {
        self.handle = handle; start = videoFrame; self.pointer = pointer; self.visibleFrame = visibleFrame
        self.minimumWidth = minimumWidth; self.maximumWidth = max(minimumWidth, maximumWidth)
    }

    /// The edge or corner `point` would pull, if any.
    static func handle(at point: CGPoint, in video: CGRect) -> Handle? {
        guard video.width > 2*corner, video.height > 2*corner,
              video.insetBy(dx: -outside, dy: -outside).contains(point) else { return nil }
        let left = point.x < video.minX+inside, right = point.x > video.maxX-inside
        let bottom = point.y < video.minY+inside, top = point.y > video.maxY-inside
        guard left || right || bottom || top else { return nil }
        let nearLeft = point.x < video.minX+corner, nearRight = point.x > video.maxX-corner
        let nearBottom = point.y < video.minY+corner, nearTop = point.y > video.maxY-corner
        let x = left || (bottom || top) && nearLeft ? -1 : right || (bottom || top) && nearRight ? 1 : 0
        let y = bottom || (left || right) && nearBottom ? -1 : top || (left || right) && nearTop ? 1 : 0
        return Handle(x: x, y: y)
    }

    /// The video's frame with the pointer at `now`.
    func videoFrame(pointer now: CGPoint) -> CGRect {
        let w = start.width, h = start.height, aspect = w/h
        let dx = (now.x-pointer.x)*CGFloat(handle.x), dy = (now.y-pointer.y)*CGFloat(handle.y)
        var width: CGFloat
        switch (handle.x != 0, handle.y != 0) {
        case (true, true): width = w*((w+dx)*w+(h+dy)*h)/(w*w+h*h)
        case (true, false): width = w+dx
        default: width = (h+dy)*aspect
        }
        // The sides being pulled go as far as the screen's edges; the opposite ones stay.
        let available = visibleFrame.insetBy(dx: FloatingVideoMotion.edgeInset, dy: FloatingVideoMotion.edgeInset)
        var room = min(maximumWidth, available.width, available.height*aspect)
        if handle.x == 1 { room = min(room, available.maxX-start.minX) } else if handle.x == -1 { room = min(room, start.maxX-available.minX) }
        if handle.y == 1 { room = min(room, (available.maxY-start.minY)*aspect) } else if handle.y == -1 { room = min(room, (start.maxY-available.minY)*aspect) }
        width = max(minimumWidth, min(width, room))
        let size = CGSize(width: width, height: width/aspect)
        func fraction(_ pulled: Int, _ low: CGFloat, _ high: CGFloat, _ lowEdge: CGFloat, _ highEdge: CGFloat) -> CGFloat {
            if pulled != 0 { return pulled == 1 ? 0 : 1 }
            return abs(low-lowEdge) < 16 ? 0 : abs(high-highEdge) < 16 ? 1 : 0.5
        }
        let fx = fraction(handle.x, start.minX, start.maxX, available.minX, available.maxX)
        let fy = fraction(handle.y, start.minY, start.maxY, available.minY, available.maxY)
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: visibleFrame)
        let x = start.minX+w*fx-size.width*fx, y = start.minY+h*fy-size.height*fy
        return CGRect(x: min(limits.maxX, max(limits.minX, x)), y: min(limits.maxY, max(limits.minY, y)), width: size.width, height: size.height)
    }
}
