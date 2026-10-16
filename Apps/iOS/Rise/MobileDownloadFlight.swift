import UIKit

/// Dia's recorded row emerges near the click, then accelerates round a shallow curve
/// and collapses at the destination. The desktop flight supplies the easing, late
/// shrink and direction-aware spring kick; the mobile flight carries a real list row.
@MainActor struct MobileDownloadFlightPath {
    static let cardSize = CGSize(width: 232, height: DownloadsPanel.rowHeight)
    static let reactionDuration = 0.55
    private static let ease = CubicEasing(0.42, 0, 0.72, 0.19)
    private static let pop = SummariseSpring(2 * .pi/0.24, 0.78)
    private static let reaction = SummariseSpring(2 * .pi/0.34, 0.6)
    let origin: CGPoint, destination: CGPoint, control: CGPoint
    let duration: Double
    var totalDuration: Double { duration+Self.reactionDuration }

    init(from origin: CGPoint, to destination: CGPoint, within bounds: CGRect) {
        self.origin = origin; self.destination = destination
        let dx = destination.x-origin.x, dy = destination.y-origin.y
        let distance = hypot(dx, dy), length = max(1, distance)
        var normal = CGVector(dx: -dy/length, dy: dx/length)
        if normal.dy < 0 { normal = CGVector(dx: -normal.dx, dy: -normal.dy) }
        // The slight dip is visible in the reference before the row sweeps away.
        let x = origin.x+dx*0.35+normal.dx*distance*0.36
        let y = origin.y+dy*0.35+normal.dy*distance*0.36
        control = CGPoint(x: min(bounds.maxX-12, max(bounds.minX+12, x)),
                          y: min(bounds.maxY-12, max(bounds.minY+12, y)))
        duration = min(0.54, max(0.34, 0.44*pow(Double(distance)/600, 0.2)))
    }

    struct Pose { let position: CGPoint; let scale: CGFloat; let rotation: CGFloat; let opacity: Float }
    func pose(at time: Double) -> Pose {
        let u = min(1, max(0, time/duration)), p = Self.ease(u), q = 1-p
        let position = CGPoint(x: q*q*origin.x+2*q*p*control.x+p*p*destination.x,
                               y: q*q*origin.y+2*q*p*control.y+p*p*destination.y)
        let shrink = pow(max(0, (p-0.6)/0.4), 1.6)
        let pop = 0.42+0.58*Self.pop(max(0, time))
        let scale = (0.86+(0.025-0.86)*shrink)*pop
        let direction = destination.x >= origin.x ? 1.0 : -1.0
        return Pose(position: position, scale: scale, rotation: direction*0.055*sin(.pi*p),
                    opacity: Float(1-max(0, (p-0.9)/0.1)))
    }

    /// A velocity impulse, as in the desktop archive: about 2 points along the incoming
    /// tangent, a small tilt and squeeze, then a damped return through rest.
    func impact(at time: Double) -> CATransform3D {
        guard time > 0, time < Self.reactionDuration else { return CATransform3DIdentity }
        let dx = destination.x-control.x, dy = destination.y-control.y, length = max(1, hypot(dx, dy))
        let k = Self.reaction.value(from: 0, to: 0, velocity: 46, at: time)
        var result = CATransform3DMakeTranslation(dx/length*2.2*k, dy/length*2.2*k, 0)
        result = CATransform3DRotate(result, dx/length*0.035*k, 0, 0, 1)
        return CATransform3DScale(result, 1+0.025*k, 1-0.04*k, 1)
    }
}

/// Render-server keyframes keep the throw moving while WebKit starts writing the file.
/// This overlay never intercepts a touch; each transfer has its own flight and additive
/// impact, so rapid successive downloads don't replace one another's animation.
@MainActor final class MobileDownloadFlight: UIView {
    let path: MobileDownloadFlightPath
    let card: DownloadsPanel.Row
    private weak var landing: UIView?
    private var rate: CADisplayLink?
    private let impactKey = "download-impact-\(UUID())"
    private var background: NSObjectProtocol?
    private var feedback: UIImpactFeedbackGenerator?
    private(set) var startTime: CFTimeInterval = 0
    private var didImpact = false
    #if DEBUG
    private(set) var impactFeedbackTime: CFTimeInterval?
    private(set) var impactFeedbackCount = 0
    #endif

    init(item: MobileDownloads.Item, origin: CGPoint, landing: UIView, window: UIWindow) {
        self.landing = landing
        let target = landing.convert(CGPoint(x: landing.bounds.midX, y: landing.bounds.midY), to: window)
        path = MobileDownloadFlightPath(from: origin, to: target, within: window.bounds)
        card = DownloadsPanel.Row(item: item)
        super.init(frame: window.bounds)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        card.isUserInteractionEnabled = false
        card.moreButton.isHidden = true
        card.layer.cornerRadius = MenuPanel.cornerRadius
        card.bounds = CGRect(origin: .zero, size: MobileDownloadFlightPath.cardSize)
        card.center = origin
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 10
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: MenuPanel.cornerRadius).cgPath
        addSubview(card)
        card.layoutIfNeeded()
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { removeFromSuperview(); return }
        background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.removeFromSuperview() } }
        let count = Int(ceil(path.totalDuration*120))
        var positions: [NSValue] = [], transforms: [NSValue] = [], opacity: [Float] = [], impacts: [NSValue] = []
        for index in 0...count {
            let time = path.totalDuration*Double(index)/Double(count), pose = path.pose(at: time)
            positions.append(NSValue(cgPoint: pose.position)); opacity.append(pose.opacity)
            var transform = CATransform3DMakeRotation(pose.rotation, 0, 0, 1)
            transform = CATransform3DScale(transform, pose.scale, pose.scale, 1)
            transforms.append(NSValue(caTransform3D: transform))
            impacts.append(NSValue(caTransform3D: path.impact(at: time-path.duration)))
        }
        feedback = UIImpactFeedbackGenerator(style: .rigid)
        feedback?.prepare()
        startTime = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        card.layer.position = path.destination
        card.layer.opacity = 0
        func animate(_ layer: CALayer, _ key: String, _ values: [Any], additive: Bool = false) {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values; animation.duration = path.totalDuration
            animation.beginTime = layer.convertTime(startTime, from: nil)
            animation.calculationMode = .linear
            animation.isAdditive = additive
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            layer.add(animation, forKey: additive ? impactKey : "download.\(key)")
        }
        animate(card.layer, "position", positions)
        animate(card.layer, "transform", transforms)
        animate(card.layer, "opacity", opacity)
        if let landing { animate(landing.layer, "transform", impacts, additive: true) }
        CATransaction.commit()
        // iOS otherwise drops a lone keyframe animation to 60 Hz near its tail.
        let rate = CADisplayLink(target: FrameRateKeeper { [weak self] in self?.receiveImpact() },
                                 selector: #selector(FrameRateKeeper.tick))
        rate.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        rate.add(to: .main, forMode: .common); self.rate = rate
        CATransaction.flush()
    }

    /// Use the same clock as the render-server flight, firing once as the row arrives.
    /// The existing rate link also means an interrupted/removed flight cannot tap later.
    private func receiveImpact() {
        guard !didImpact, window != nil, CACurrentMediaTime() >= startTime+path.duration else { return }
        didImpact = true
        feedback?.impactOccurred(intensity: 1)
        feedback = nil
        #if DEBUG
        impactFeedbackTime = CACurrentMediaTime()
        impactFeedbackCount += 1
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        rate?.invalidate(); rate = nil
        feedback = nil
        if let background { NotificationCenter.default.removeObserver(background); self.background = nil }
        landing?.layer.removeAnimation(forKey: impactKey)
        card.layer.removeAllAnimations()
    }

    private final class FrameRateKeeper: NSObject {
        let tickAction: () -> Void
        init(_ tick: @escaping () -> Void) { tickAction = tick }
        @objc func tick() { tickAction() }
    }
}
