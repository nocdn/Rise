import UIKit

/// Desktop's loading hairline, reflected onto the toolbar's top edge so its glow
/// blooms down into the bar. The path, spring, colours and fade come from shared code.
@MainActor final class PageLoadingLine: UIView {
    static let fadeKey = "Rise.PageLoadFade"
    let progressLine = CAShapeLayer()
    private let style = PageLoadProgress.Style()
    private(set) var progress: CGFloat?
    private(set) var isLoading = false
    private var target: CGFloat = 0, speed: CGFloat = 0
    private var finishing = false, revision = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.addSublayer(progressLine)
        progressLine.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(loading: Bool, progress value: Double, hard: Bool = false, reset: Bool = false) {
        if reset {
            stopFollowing(); revision += 1; isLoading = false; finishing = false
            progressLine.removeAnimation(forKey: Self.fadeKey)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            progressLine.opacity = 1; CATransaction.commit()
            showProgress(nil)
        }
        if loading {
            if !isLoading {
                revision += 1; isLoading = true; finishing = false; target = 0; speed = 0
                progressLine.removeAnimation(forKey: Self.fadeKey)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.progressLine.opacity = 1; CATransaction.commit()
                showProgress(0)
            }
            let rgb = hard ? PageLoadProgress.hardReloadColor : PageLoadProgress.color
            let color = UIColor(red: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255,
                                blue: CGFloat(rgb & 255)/255, alpha: 1).cgColor
            CATransaction.begin(); CATransaction.setDisableActions(true)
            progressLine.fillColor = color; progressLine.shadowColor = color
            CATransaction.commit()
            target = max(target, PageLoadProgress.target(value))
            if reset { showProgress(target) }
            follow()
        } else if isLoading {
            isLoading = false; finishing = true
            target = 1+PageLoadProgress.overrun/max(1, bounds.width)
            follow()
        }
    }
    private func showProgress(_ value: CGFloat?) { progress = value; layoutLine() }
    private func follow() {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            showProgress(min(1, target)); if finishing { finish() }; return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link; lastTick = CACurrentMediaTime()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = CGFloat(min(1.0/30, max(0, now-lastTick))); lastTick = now
        let step = PageLoadProgress.step(front: progress ?? 0, target: target, speed: speed, dt: dt)
        speed = step.speed; showProgress(step.front)
        if finishing, step.front >= 1 { showProgress(1); stopFollowing(); finish(); return }
        if abs(step.front-target) < 0.0005 {
            showProgress(target); stopFollowing()
            if finishing { finish() }
        }
    }
    private func stopFollowing() { link?.invalidate(); link = nil }
    private func finish() {
        finishing = false
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { showProgress(nil); return }
        let current = revision
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.revision == current, !self.isLoading, !self.finishing else { return }
                self.showProgress(nil)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.progressLine.opacity = 1; CATransaction.commit()
            }
        }
        progressLine.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = PageLoadProgress.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        progressLine.add(fade, forKey: Self.fadeKey)
        CATransaction.commit()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopFollowing(); showProgress(isLoading ? target : nil) }
        else if isLoading || finishing { follow() }
    }
    override func layoutSubviews() { super.layoutSubviews(); layoutLine() }
    private func layoutLine() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let progress, bounds.width > 0 else { progressLine.isHidden = true; return }
        let scale = max(1, traitCollection.displayScale)
        let path = PageLoadProgress.path(front: bounds.width*min(1, max(0, progress)), centre: 0.5/scale, style: style)
        progressLine.frame = bounds; progressLine.path = path; progressLine.shadowPath = path
        progressLine.shadowOffset = .zero
        progressLine.shadowRadius = style.glow; progressLine.shadowOpacity = style.glowOpacity
        progressLine.isHidden = false
    }
}
