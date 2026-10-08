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
