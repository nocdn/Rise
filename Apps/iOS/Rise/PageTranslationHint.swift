import UIKit

/// A once-per-document discovery cue. It never translates, intercepts taps or plays a haptic.
@MainActor final class PageTranslationHint: UIView {
    static let revealDuration = 0.14
    static let flightDuration = 0.36
    static let arrival = revealDuration+flightDuration
    static let duration = arrival+ToolbarLandingImpact.duration
    private static let acceleration = CubicEasing(0.42, 0, 0.72, 0.19)
    let documentID: String
    let glyph = UIImageView(image: UIImage(named: "ToolbarTranslate"))
    let origin: CGPoint, destination: CGPoint
    private weak var landing: UIView?
    private let impactKey = "translation-impact-\(UUID())"
    private var rate: CADisplayLink?
    private var background: NSObjectProtocol?
    private var finished: (() -> Void)?
    private(set) var startTime: CFTimeInterval = 0

    struct Pose { let position: CGPoint; let scale: CGFloat; let opacity: Float }
    func pose(at time: Double) -> Pose {
        let p = Self.acceleration(min(1, max(0, (time-Self.revealDuration)/Self.flightDuration)))
        let u = min(1, max(0, time/Self.revealDuration))
        let reveal = u*u*(3-2*u)
        let alpha = reveal*(1-max(0, (p-0.72)/0.28))
        return Pose(position: CGPoint(x: origin.x+(destination.x-origin.x)*p, y: destination.y),
                    scale: (0.9+0.1*reveal)*(1-0.32*p), opacity: Float(alpha))
    }

    init(documentID: String, landing: UIView, in host: UIView) {
        self.documentID = documentID
        self.landing = landing
        destination = landing.convert(CGPoint(x: landing.bounds.midX, y: landing.bounds.midY), to: host)
        origin = CGPoint(x: destination.x-40, y: destination.y)
        super.init(frame: host.bounds)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        glyph.contentMode = .center
        glyph.tintColor = BottomBar.plusTint
        glyph.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        glyph.center = origin
        glyph.alpha = 0
        addSubview(glyph)
        // Enter behind the circular surface, including its translucent dark-mode fill.
        // Clipping the circle keeps the travelling glyph from crossing the dots themselves.
        let outsideButton = UIBezierPath(rect: bounds)
        outsideButton.append(UIBezierPath(ovalIn: landing.convert(landing.bounds, to: host)))
        let mask = CAShapeLayer()
        mask.path = outsideButton.cgPath
        mask.fillRule = .evenOdd
        layer.mask = mask
    }
    required init?(coder: NSCoder) { fatalError() }

    func start(completion: @escaping () -> Void) {
        finished = completion
        guard window != nil else { cancel(); return }
        background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        startTime = CACurrentMediaTime()
        // Accessibility keeps the cue's fade, without a moving glyph or landing kick.
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: Self.revealDuration, delay: 0, options: .curveEaseInOut,
                           animations: { self.glyph.alpha = 1 }) { _ in
                UIView.animate(withDuration: 0.15, delay: 0.35, animations: { self.glyph.alpha = 0 }) { _ in self.cancel() }
            }
            return
        }
        let count = Int(ceil(Self.duration*120))
        var positions: [NSValue] = [], scales: [CGFloat] = [], opacity: [Float] = [], impacts: [NSValue] = []
        for index in 0...count {
            let time = Self.duration*Double(index)/Double(count), pose = pose(at: time)
            positions.append(NSValue(cgPoint: pose.position)); scales.append(pose.scale); opacity.append(pose.opacity)
            impacts.append(NSValue(caTransform3D: ToolbarLandingImpact.transform(at: time-Self.arrival, direction: CGVector(dx: 1, dy: 0))))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.cancel() }
        glyph.layer.position = destination
        func animate(_ layer: CALayer, _ key: String, _ values: [Any], additive: Bool = false) {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values; animation.duration = Self.duration
            animation.beginTime = layer.convertTime(startTime, from: nil)
            animation.calculationMode = .linear
            animation.isAdditive = additive
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            layer.add(animation, forKey: additive ? impactKey : "translation.\(key)")
        }
        animate(glyph.layer, "position", positions)
        animate(glyph.layer, "transform.scale", scales)
        animate(glyph.layer, "opacity", opacity)
        if let landing { animate(landing.layer, "transform", impacts, additive: true) }
        CATransaction.commit()
        let rate = CADisplayLink(target: FrameTicker {}, selector: #selector(FrameTicker.tick))
        rate.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        rate.add(to: .main, forMode: .common); self.rate = rate
        CATransaction.flush()
    }

    func cancel() { removeFromSuperview() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        rate?.invalidate(); rate = nil
        if let background { NotificationCenter.default.removeObserver(background); self.background = nil }
        landing?.layer.removeAnimation(forKey: impactKey)
        glyph.layer.removeAllAnimations()
        let completion = finished; finished = nil; completion?()
    }
}
