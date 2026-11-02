import AppKit

final class DownloadProgressRing: FlippedView {
    private let track = CAShapeLayer(), fill = CAShapeLayer()
    private(set) var fraction: Double?
    private var isPaused = false
    private var hasUpdated = false
    init() {
        super.init(frame: .zero); wantsLayer = true
        for shape in [track, fill] {
            shape.fillColor = nil; shape.lineWidth = 2.5; shape.lineCap = .round; layer?.addSublayer(shape)
        }
        fill.strokeEnd = 0
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(0, min(bounds.width, bounds.height)/2-4), startAngle: -.pi/2, endAngle: 3 * .pi/2, clockwise: false)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [track, fill] { shape.frame = bounds; shape.path = path }
        CATransaction.commit()
    }
    func update(fraction: Double?, paused: Bool) {
        let changed = !hasUpdated || fraction != self.fraction
        hasUpdated = true
        self.fraction = fraction
        if isPaused != paused { isPaused = paused; updateColors(animated: true) }
        let previous = fill.presentation()?.strokeEnd ?? fill.strokeEnd
        let value = CGFloat(fraction ?? 0.25)
        if changed { CATransaction.begin(); CATransaction.setDisableActions(true); fill.strokeEnd = value; CATransaction.commit() }
        if changed, fraction != nil, value != previous, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = previous; animation.toValue = value; animation.duration = 0.22
            fill.add(animation, forKey: "progress")
        }
        if fraction == nil, !paused, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if fill.animation(forKey: "indeterminate") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0; spin.toValue = 2 * Double.pi; spin.duration = 1.1; spin.repeatCount = .infinity
                fill.add(spin, forKey: "indeterminate")
            }
        } else { fill.removeAnimation(forKey: "indeterminate") }
    }
    private func updateColors(animated: Bool = false) {
        let previous = fill.presentation()?.strokeColor ?? fill.strokeColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
            fill.strokeColor = (isPaused ? NSColor.secondaryLabelColor : NSColor.systemBlue).cgColor
        }
        CATransaction.commit()
        fill.removeAnimation(forKey: "pauseColor")
        if animated, let previous, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = CABasicAnimation(keyPath: "strokeColor")
            animation.fromValue = previous; animation.toValue = fill.strokeColor; animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fill.add(animation, forKey: "pauseColor")
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
}
