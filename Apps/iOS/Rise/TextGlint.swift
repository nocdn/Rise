import UIKit

/// A band of the accent colour that crosses a label's text once, masked to its glyphs, leaving
/// the text as it was. Archived Tabs picks out with it the tabs its toast named. With Reduce
/// Motion the text takes the colour and lets it go, without moving.
@MainActor final class TextGlint {
    static let color = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 112/255, green: 142/255, blue: 1, alpha: 1) : UIColor(red: 42/255, green: 48/255, blue: 1, alpha: 1) }
    /// The band's width, and how fast it crosses: the same pace on every row, however long its text.
    static let band: CGFloat = 70, speed: CGFloat = 420, shortest: CFTimeInterval = 0.55

    private let overlay = CALayer()
    private let gradient = CAGradientLayer()
    private var pending: Task<Void, Never>?
    /// A crossing stopped early never ends the one after it.
    private var generation = 0
    /// What it was asked to pick out, and when, in media time, it starts or started.
    private(set) var key: String?
    private(set) var start: CFTimeInterval = 0
    var isCrossing: Bool { overlay.superlayer != nil }

    init() {
        overlay.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.5, 1]
    }

    /// Crosses `label` at `start`, laid out as the label is then rather than as it is now.
    func run(on label: UILabel, key: String, at start: CFTimeInterval) {
        stop()
        self.key = key; self.start = start
        pending = Task { [weak self, weak label] in
            let wait = start-CACurrentMediaTime()
            if wait > 0 { do { try await Task.sleep(for: .seconds(wait)) } catch { return } }
            guard let self, let label else { return }
            begin(on: label)
        }
    }

    func stop() {
        pending?.cancel(); pending = nil
        generation += 1
        gradient.removeAllAnimations(); overlay.removeAllAnimations()
        overlay.removeFromSuperlayer()
        key = nil
    }

    private func begin(on label: UILabel) {
        pending = nil
        let text = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
        guard label.window != nil, text.width > 1, label.bounds.height > 1 else { return }
        // The glyphs as drawn, truncation and all, are the band's mask.
        let format = UIGraphicsImageRendererFormat(for: label.traitCollection)
        let glyphs = UIGraphicsImageRenderer(bounds: label.bounds, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }
        let mask = CALayer()
        mask.frame = label.bounds; mask.contents = glyphs.cgImage; mask.contentsScale = glyphs.scale
        let color = Self.color.resolvedColor(with: label.traitCollection)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.frame = label.bounds
        overlay.mask = mask
        label.layer.addSublayer(overlay)
        let rate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        let crossing = generation
        let done = GlintCompletion { [weak self] in if self?.generation == crossing { self?.finish() } }
        if UIAccessibility.isReduceMotionEnabled {
            gradient.isHidden = true
            overlay.backgroundColor = color.cgColor
            overlay.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.3, 0.55, 1]
            fade.duration = 0.8
            fade.delegate = done; fade.preferredFrameRateRange = rate
            overlay.add(fade, forKey: "glint")
        } else {
            gradient.isHidden = false
            overlay.backgroundColor = nil
            overlay.opacity = 1
            gradient.colors = [color.withAlphaComponent(0), color, color.withAlphaComponent(0)].map(\.cgColor)
            // Waiting off the text's left, then off its right once across.
            gradient.frame = CGRect(x: text.minX-Self.band, y: 0, width: Self.band, height: label.bounds.height)
            let travel = text.width+Self.band
            let sweep = CABasicAnimation(keyPath: "transform.translation.x")
            sweep.fromValue = 0; sweep.toValue = travel
            sweep.duration = max(Self.shortest, travel/Self.speed)
            sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.65, 1)
            sweep.delegate = done; sweep.preferredFrameRateRange = rate
            gradient.add(sweep, forKey: "glint")
        }
        CATransaction.commit()
    }

    private func finish() {
        overlay.removeFromSuperlayer()
        overlay.mask = nil
    }
}

@MainActor private final class GlintCompletion: NSObject, CAAnimationDelegate {
    private let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished else { return }
        Task { @MainActor [self] in done() }
    }
}
