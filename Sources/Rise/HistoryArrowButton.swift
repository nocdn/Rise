import AppKit
import QuartzCore

/// The demo's anchored-tail shape, scaled to the existing 16 pt regular toolbar
/// glyph. Only the head/shaft compress; neither the button nor its center moves.
/// It's always this drawn arrow, never AppKit's image: turning on and off only fades its
/// colour, at once, where AppKit's disabled image redrew late and a hair off.
final class HistoryArrowButton: ChromeButton {
    let direction: HistoryDirection
    private let arrow = CAShapeLayer()
    /// The 16 pt toolbar arrow's canvas, which the drawn arrow's ink matches.
    private let glyphSize: NSSize
    private var returnTimer: Timer?
    private var isDragging = false
    private var crossedThreshold = false
    private(set) var pull = 0.0
    private(set) var armed = false
    var isReturning: Bool { returnTimer != nil }
    /// Dia's chevron, as the Plain theme's page bar draws it: the arrow's head alone, 6.5 by
    /// 11.5 pt of ink, its tip pulling in the same way.
    var chevron = false { didSet { if chevron != oldValue { updatePath() } } }
    override var contentTintColor: NSColor? {
        didSet { if !armed { setStrokeColor(restingColor) } }
    }
    /// Unavailable, the arrow fades to half, as AppKit draws a disabled button.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue, !armed, !isDragging else { return }
            fadeStroke(to: restingColor, duration: 0.15)
        }
    }
    private var restingColor: NSColor {
        let tint = contentTintColor ?? .secondaryLabelColor
        return isEnabled ? tint : tint.withAlphaComponent(tint.alphaComponent*0.5)
    }
    init(direction: HistoryDirection, title: String, action: @escaping () -> Void) {
        self.direction = direction
        glyphSize = NSImage(systemSymbolName: direction == .back ? "arrow.left" : "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?.size ?? NSSize(width: 16, height: 14)
        super.init(symbol: direction == .back ? "arrow.left" : "arrow.right", size: 16, title: title, action: action)
        image = nil
        arrow.fillColor = nil; arrow.lineCap = .round; arrow.lineJoin = .round
        arrow.lineWidth = 1.40
        layer?.addSublayer(arrow)
        setStrokeColor(restingColor)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updatePath() }
    func drag(pull: Double, armed: Bool) {
        if !isDragging { crossedThreshold = false; isDragging = true }
        crossedThreshold = crossedThreshold || armed
        returnTimer?.invalidate(); returnTimer = nil; arrow.removeAllAnimations()
        self.pull = pull; self.armed = armed
        arrow.opacity = 1
        setStrokeColor(armed ? NSColor(hex: 0x007AFF) : restingColor)
        updatePath()
    }
    func release(committed: Bool) {
        let from = pull
        armed = false; isDragging = false
        fadeStroke(to: restingColor, duration: 0.18)
        let spring = (committed || crossedThreshold) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A swipe that reached the threshold springs home even when reversed
        // to cancel. Earlier releases retain the demo's short ease-out.
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
        if chevron { updateChevronPath(); return }
        let size = glyphSize
        let facing = direction == .back ? -1.0 : 1.0
        // SF Symbols include optical whitespace. Keep the regular arrow's ink
        // size rather than enlarging the replacement to its full image canvas.
        let half = Double(size.width - 5 - arrow.lineWidth) / 2
        let wing = Double(size.height - 3 - arrow.lineWidth) / 2
        let tip = CGPoint(x: bounds.midX + facing * (half - pull * half * 32/36), y: bounds.midY)
        let tail = CGPoint(x: bounds.midX - facing * half, y: bounds.midY)
        // The head's two points shorten with the pull too, about a third at the threshold,
        // visible at toolbar scale without changing the resting size or stroke weight.
        let arm = wing * (1 - pull * 0.35)
        let path = CGMutablePath()
        path.move(to: tip); path.addLine(to: tail)
        path.move(to: CGPoint(x: tip.x - facing * arm, y: tip.y - arm))
        path.addLine(to: tip); path.addLine(to: CGPoint(x: tip.x - facing * arm, y: tip.y + arm))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.frame = bounds; arrow.path = path
        CATransaction.commit()
    }
    private func updateChevronPath() {
        let facing = direction == .back ? -1.0 : 1.0
        let width = 6.5-Double(arrow.lineWidth), height = 11.5-Double(arrow.lineWidth)
        let tip = CGPoint(x: bounds.midX + facing * (width/2 - pull * width * 0.8), y: bounds.midY)
        let arm = height/2 * (1 - pull * 0.35)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tip.x - facing * width, y: tip.y - arm))
        path.addLine(to: tip); path.addLine(to: CGPoint(x: tip.x - facing * width, y: tip.y + arm))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.frame = bounds; arrow.path = path
        CATransaction.commit()
    }
    /// The arrow's colour as drawn now, for checks.
    var shownColor: CGColor? { arrow.presentation()?.strokeColor ?? arrow.strokeColor }
    /// One fade for every colour change, under one key, so a later one (the swipe's page turning
    /// the button off as the arrow lets go of its blue) takes over from where the colour is,
    /// rather than an earlier one showing again once the later ends.
    private func fadeStroke(to color: NSColor, duration: CFTimeInterval) {
        let from = arrow.presentation()?.strokeColor ?? arrow.strokeColor
        setStrokeColor(color)
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { arrow.removeAnimation(forKey: "color"); return }
        let fade = CABasicAnimation(keyPath: "strokeColor")
        fade.fromValue = from; fade.toValue = color.cgColor; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        arrow.add(fade, forKey: "color")
    }
    private func setStrokeColor(_ color: NSColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.strokeColor = color.cgColor
        CATransaction.commit()
    }
    func restore() {
        returnTimer?.invalidate(); returnTimer = nil
        // A colour fade still under way finishes: it already ends at the resting colour.
        pull = 0; armed = false; isDragging = false; crossedThreshold = false
        setStrokeColor(restingColor); updatePath()
    }
}
