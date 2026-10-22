import AppKit

/// macOS's small spinner, drawn by Rise so it takes the notice's ink in Light and Dark alike:
/// eight rounded blades around the centre, the leading one strongest and the ones behind it
/// fading, stepping round once every 0.8 s as the system's does.
final class InfoSpinnerView: NSView {
    private let replicator = CAReplicatorLayer(), blade = CALayer()
    static let blades = 8, period: CFTimeInterval = 0.8
    var color: NSColor = .labelColor { didSet { CATransaction.begin(); CATransaction.setDisableActions(true); blade.backgroundColor = color.cgColor; CATransaction.commit() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        replicator.instanceCount = Self.blades
        // Clockwise, as the system's turns, each blade's flare a step after the last.
        replicator.instanceTransform = CATransform3DMakeRotation(-2 * .pi/CGFloat(Self.blades), 0, 0, 1)
        replicator.instanceDelay = Self.period/Double(Self.blades)
        replicator.addSublayer(blade)
        layer?.addSublayer(replicator)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        replicator.frame = bounds
        // Blades as the system draws them: a fifth of the width long and a ninth wide, round-ended,
        // from a little out from the centre to the edge.
        let side = min(bounds.width, bounds.height), width = max(1, side/9), length = side*0.28
        blade.bounds = CGRect(x: 0, y: 0, width: width, height: length)
        blade.cornerRadius = width/2
        blade.position = CGPoint(x: bounds.midX, y: bounds.midY+side/2-length/2)
        CATransaction.commit()
        start()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); start() }

    /// Each blade flares as the lead passes it and fades over the turn behind it.
    private func start() {
        guard window != nil, blade.animation(forKey: "spin") == nil else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.duration = Self.period; fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        // The blades step, as the system's do, rather than sweep.
        fade.calculationMode = .discrete
        fade.values = (0..<Self.blades).map { 1-0.78*Double($0)/Double(Self.blades-1) }
        fade.keyTimes = (0..<Self.blades).map { NSNumber(value: Double($0)/Double(Self.blades)) }
        blade.opacity = 0.22
        blade.add(fade, forKey: "spin")
    }
}
