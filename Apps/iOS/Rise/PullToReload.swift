import UIKit
import WebKit

extension UIScrollView {
    /// How far the content is pulled down past its top, rubber-banding, ignoring rounding at rest.
    var topOverscroll: CGFloat {
        let pull = -(contentOffset.y+adjustedContentInset.top)
        return pull > 0.5 ? pull : 0
    }

    /// How far the content is pulled up past its bottom.
    var bottomOverscroll: CGFloat {
        let end = max(contentSize.height+adjustedContentInset.bottom-bounds.height, -adjustedContentInset.top)
        let pull = contentOffset.y-end
        return pull > 0.5 ? pull : 0
    }
}

/// Pulling a page down past its top reloads it on release, as with the system's refresh control.
/// A spinner charges up spoke by spoke in the gap above the page, complete at the threshold, and
/// spins in a gap held open until the page has loaded. Ticks of haptic feedback follow the pull
/// both ways, stronger the closer it gets to the threshold, and reaching it lands as one firm click.
@MainActor final class PullToReload: NSObject {
    static let threshold: CGFloat = 115
    /// One tick per this many points of pull.
    static let tickSpacing: CGFloat = 5
    /// How much of the gap stays open above the page while it reloads.
    static let heldGap: CGFloat = 56
    /// Spins at least this long, so a quick reload still reads as one.
    static let minimumSpin: TimeInterval = 0.5
    static let reloadTimeout: TimeInterval = 15

    /// Clips the spinner to the gap above the page. Sits above the page, below anything covering it.
    let overlay = UIView()
    let spinner = ReloadSpinner()
    /// Tells whoever colours the gap that it's open without the page being pulled.
    var onGapHeld: (@MainActor (Bool) -> Void)?
    private let onReload: @MainActor () -> Void
    private weak var webView: WKWebView?
    private var offsetObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private let tick = UIImpactFeedbackGenerator(style: .light)
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    private var lastStep = 0
    /// The part of the scroll view's top inset added to hold the gap open.
    private var heldInset: CGFloat = 0
    private var reloadStart: CFTimeInterval = 0
    private var reloadID = 0
    /// Whether letting go now reloads.
    private(set) var armed = false
    private(set) var isReloading = false
    private(set) var ticks = 0, clicks = 0

    init(onReload: @escaping @MainActor () -> Void) {
        self.onReload = onReload
        super.init()
        overlay.clipsToBounds = true
        overlay.isUserInteractionEnabled = false
        overlay.addSubview(spinner)
    }

    /// Follows the page's own scroll gesture, leaving WebKit's scroll handling untouched.
    func attach(to webView: WKWebView) {
        cancelReloading()
        self.webView?.scrollView.panGestureRecognizer.removeTarget(self, action: #selector(pan))
        self.webView = webView
        webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(pan))
        offsetObservation = webView.scrollView.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.layoutGap() }
        }
        layoutGap()
    }

    /// The gap's height: the pull past the page's top, plus any of it held open.
    var gap: CGFloat {
        guard let scrollView = webView?.scrollView else { return 0 }
        return max(0, -(scrollView.contentOffset.y+scrollView.adjustedContentInset.top-heldInset))
    }

    func layoutGap() {
        guard let webView, let host = overlay.superview else { return }
        let page = webView.convert(webView.bounds, to: host)
        let gap = gap
        overlay.frame = CGRect(x: page.minX, y: page.minY, width: page.width, height: gap)
        spinner.center = CGPoint(x: overlay.bounds.midX, y: gap/2)
        if !isReloading { spinner.setCharge(gap/Self.threshold) }
    }

    @objc private func pan(_ pan: UIPanGestureRecognizer) {
        guard let webView, !isReloading else { return }
        switch pan.state {
        case .began:
            armed = false; lastStep = 0
            tick.prepare(); click.prepare()
        case .changed:
            update(pull: webView.scrollView.topOverscroll)
        case .ended:
            finish()
        case .cancelled, .failed:
            armed = false; lastStep = 0
        default: break
        }
    }

    func update(pull: CGFloat) {
        let reached = pull >= Self.threshold
        if reached != armed {
            armed = reached
            // Ticks resume from the threshold if the pull eases back below it.
            lastStep = Int(Self.threshold/Self.tickSpacing)
            if reached {
                click.impactOccurred(intensity: 1)
                clicks += 1
                return
            }
        }
        guard !armed else { return }
        let step = Int(pull/Self.tickSpacing)
        guard step != lastStep else { return }
        lastStep = step
        guard step > 0 else { return }
        let progress = min(1, pull/Self.threshold)
        tick.impactOccurred(intensity: 0.15+0.6*progress*progress)
        tick.prepare()
        ticks += 1
    }

    /// The finger lifted: reloads if the pull was past the threshold.
    func finish() {
        let reload = armed
        armed = false; lastStep = 0
        if reload { beginReloading() }
    }

    /// Holds the gap open, as the page bounces back, and spins until the page has loaded.
    private func beginReloading() {
        guard let webView, !isReloading else { return }
        isReloading = true
        reloadStart = CACurrentMediaTime()
        reloadID += 1
        heldInset = Self.heldGap
        webView.scrollView.contentInset.top += heldInset
        onGapHeld?(true)
        spinner.setCharge(1)
        spinner.spin()
        onReload()
        var sawLoading = false
        let id = reloadID
        loadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                if webView.isLoading { sawLoading = true } else if sawLoading { self?.endReloading(id) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.reloadTimeout) { [weak self] in self?.endReloading(id) }
    }

    private func endReloading(_ id: Int) {
        guard isReloading, id == reloadID else { return }
        let wait = max(0, Self.minimumSpin-(CACurrentMediaTime()-reloadStart))
        DispatchQueue.main.asyncAfter(deadline: .now()+wait) { [weak self] in self?.retract(id) }
    }

    /// Lets the page slide back up over the gap as the spinner fades.
    private func retract(_ id: Int) {
        guard isReloading, id == reloadID, let scrollView = webView?.scrollView else { return }
        isReloading = false
        loadingObservation = nil
        UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            scrollView.contentInset.top -= self.heldInset
            self.heldInset = 0
            let top = -scrollView.adjustedContentInset.top
            if scrollView.contentOffset.y < top { scrollView.contentOffset.y = top }
            self.layoutGap()
            self.spinner.alpha = 0
        } completion: { [weak self] _ in
            guard let self, !isReloading else { return }
            spinner.stop()
            spinner.alpha = 1
            layoutGap()
            onGapHeld?(false)
        }
    }

    /// Drops a reload's held gap at once, as when another page takes this one's place.
    private func cancelReloading() {
        guard isReloading else { return }
        isReloading = false
        reloadID += 1
        loadingObservation = nil
        webView?.scrollView.contentInset.top -= heldInset
        heldInset = 0
        spinner.stop()
        onGapHeld?(false)
    }
}

/// The system's eight-spoke activity spinner, drawn so it can charge up one spoke at a time.
final class ReloadSpinner: UIView {
    static let spokeCount = 8
    static let size: CGFloat = 26
    private let wheel = CALayer()
    private let spokes: [CAShapeLayer]
    private(set) var shownSpokes = 0
    var isSpinning: Bool { wheel.animation(forKey: "spin") != nil }
    /// Light spokes over a dark gap, dark ones over a light gap.
    var onDarkBackground = false { didSet { updateColor() } }

    override init(frame: CGRect) {
        spokes = (0..<Self.spokeCount).map { index in
            let spoke = CAShapeLayer()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: -6))
            path.addLine(to: CGPoint(x: 0, y: -11.5))
            spoke.path = path.cgPath
            spoke.lineWidth = 2.6
            spoke.lineCap = .round
            spoke.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(index)*2*CGFloat.pi/CGFloat(Self.spokeCount)))
            spoke.opacity = 0
            return spoke
        }
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Reloading"
        wheel.position = CGPoint(x: Self.size/2, y: Self.size/2)
        spokes.forEach(wheel.addSublayer)
        layer.addSublayer(wheel)
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateColor() {
        let color = onDarkBackground ? UIColor(white: 1, alpha: 0.8) : UIColor(white: 0, alpha: 0.45)
        spokes.forEach { $0.strokeColor = color.cgColor }
    }

    /// Shows spokes clockwise from the top in proportion to `progress`, all of them at 1.
    func setCharge(_ progress: CGFloat) {
        guard !isSpinning else { return }
        let shown = progress <= 0 ? 0 : min(Self.spokeCount, Int((progress*CGFloat(Self.spokeCount)).rounded(.up)))
        guard shown != shownSpokes else { return }
        shownSpokes = shown
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, spoke) in spokes.enumerated() { spoke.opacity = index < shown ? 1 : 0 }
        CATransaction.commit()
    }

    /// Steps the wheel round an eighth at a time, its spokes fading behind the leading one.
    func spin() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, spoke) in spokes.enumerated() {
            let behind = (Self.spokeCount-index)%Self.spokeCount
            spoke.opacity = Float(1-0.8*CGFloat(behind)/CGFloat(Self.spokeCount-1))
        }
        CATransaction.commit()
        shownSpokes = Self.spokeCount
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = (0..<Self.spokeCount).map { CGFloat($0)*2*CGFloat.pi/CGFloat(Self.spokeCount) }
        spin.calculationMode = .discrete
        spin.duration = 0.8
        spin.repeatCount = .infinity
        wheel.add(spin, forKey: "spin")
    }

    func stop() {
        wheel.removeAnimation(forKey: "spin")
        shownSpokes = -1
        setCharge(0)
    }
}
