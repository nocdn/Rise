import AppKit
import QuartzCore

/// The demo's anchored-tail shape, scaled to the existing 16 pt regular toolbar
/// glyph. Only the head/shaft compress; neither the button nor its center moves.
final class HistoryArrowButton: ChromeButton {
    let direction: HistoryDirection
    private let arrow = CAShapeLayer()
    private var restingImage: NSImage?
    private var returnTimer: Timer?
    private var isDragging = false
    private var crossedThreshold = false
    private(set) var pull = 0.0
    private(set) var armed = false
    var isReturning: Bool { returnTimer != nil }
    override var contentTintColor: NSColor? {
        didSet { if !armed { setStrokeColor(contentTintColor ?? .secondaryLabelColor) } }
    }
    init(direction: HistoryDirection, title: String, action: @escaping () -> Void) {
        self.direction = direction
        super.init(symbol: direction == .back ? "arrow.left" : "arrow.right", size: 16, title: title, action: action)
        restingImage = image
        arrow.fillColor = nil; arrow.lineCap = .round; arrow.lineJoin = .round
        arrow.lineWidth = 1.35; arrow.isHidden = true
        layer?.addSublayer(arrow)
        setStrokeColor(contentTintColor ?? .secondaryLabelColor)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updatePath() }
    func drag(pull: Double, armed: Bool) {
        if !isDragging { crossedThreshold = false; isDragging = true }
        crossedThreshold = crossedThreshold || armed
        returnTimer?.invalidate(); returnTimer = nil; arrow.removeAllAnimations()
        self.pull = pull; self.armed = armed
        image = nil; arrow.isHidden = false; arrow.opacity = 1
        setStrokeColor(armed ? NSColor(hex: 0x007AFF) : contentTintColor ?? .secondaryLabelColor)
        updatePath()
    }
    func release(committed: Bool) {
        let from = pull
        armed = false; isDragging = false
        let base = contentTintColor ?? .secondaryLabelColor
        let previousColor = arrow.presentation()?.strokeColor ?? arrow.strokeColor
        setStrokeColor(base)
        let spring = (committed || crossedThreshold) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A swipe that reached the threshold springs home even when reversed
        // to cancel. Earlier releases retain the demo's short ease-out.
        let color = CABasicAnimation(keyPath: "strokeColor")
        color.fromValue = previousColor; color.toValue = base.cgColor; color.duration = 0.18
        color.timingFunction = CAMediaTimingFunction(name: .easeOut)
        arrow.add(color, forKey: "releaseColor")
        returnTimer?.invalidate()
        let start = ProcessInfo.processInfo.systemUptime
        let duration = spring ? 0.55 : 0.16
        let timer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            self.pull = from * Self.returnFactor(elapsed: elapsed, committed: spring)
            self.updatePath()
            if elapsed >= duration { self.restore() }
        }
        returnTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    // Unit mass and zero initial velocity: the exact underdamped solution for
    // the demo's spring (600 stiffness, 30 damping). Negative pull is overshoot.
    static func returnFactor(elapsed: Double, committed: Bool) -> Double {
        if committed {
            let decay = 15.0, frequency = sqrt(600.0 - decay * decay)
            return exp(-decay * elapsed) * (cos(frequency * elapsed) + decay / frequency * sin(frequency * elapsed))
        }
        // CSS/AppKit easeOut cubic Bezier (0,0,0.58,1), lasting 160 ms.
        let time = min(1, max(0, elapsed / 0.16))
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let t = (low + high) / 2
            let x = 3 * (1-t) * t*t * 0.58 + t*t*t
            if x < time { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 1 - (3 * (1-t) * t*t + t*t*t)
    }
    private func updatePath() {
        let size = restingImage?.size ?? NSSize(width: 16, height: 14)
        let facing = direction == .back ? -1.0 : 1.0
        // SF Symbols include optical whitespace. Keep the regular arrow's ink
        // size rather than enlarging the replacement to its full image canvas.
        let half = Double(size.width - 5 - arrow.lineWidth) / 2
        let wing = Double(size.height - 3 - arrow.lineWidth) / 2
        let tip = CGPoint(x: bounds.midX + facing * (half - pull * half * 32/36), y: bounds.midY)
        let tail = CGPoint(x: bounds.midX - facing * half, y: bounds.midY)
        // At toolbar scale, a quarter shorter makes the demo's wing compression
        // visible without changing the resting size or stroke weight.
        let arm = wing * (1 - pull * 0.25)
        let path = CGMutablePath()
        path.move(to: tip); path.addLine(to: tail)
        path.move(to: CGPoint(x: tip.x - facing * arm, y: tip.y - arm))
        path.addLine(to: tip); path.addLine(to: CGPoint(x: tip.x - facing * arm, y: tip.y + arm))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.frame = bounds; arrow.path = path
        CATransaction.commit()
    }
    private func setStrokeColor(_ color: NSColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.strokeColor = color.cgColor
        CATransaction.commit()
    }
    func restore() {
        returnTimer?.invalidate(); returnTimer = nil
        pull = 0; armed = false; isDragging = false; crossedThreshold = false; arrow.isHidden = true; arrow.removeAllAnimations()
        image = restingImage
    }
}
