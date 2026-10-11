import UIKit

/// Seven fully rounded red bars that rise and fall smoothly with the voice, tallest in the middle,
/// each wandering a little on its own so they move like speech rather than in step.
final class VoiceWaveform: UIView {
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2.5
    static let maximumHeight: CGFloat = 20
    /// The bars' share of the level, peaking in the middle.
    private static let shape: [Float] = [0.5, 0.72, 0.9, 1, 0.9, 0.72, 0.5]
    private var bars: [CALayer] = []
    private var heights = [Float](repeating: 0, count: VoiceInput.barCount)
    private var link: CADisplayLink?
    private var start = CACurrentMediaTime()
    /// Where the level comes from, while listening.
    var level: (() -> Float)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for _ in 0..<VoiceInput.barCount {
            let bar = CALayer()
            bar.backgroundColor = UIColor.systemRed.cgColor
            bar.cornerRadius = Self.barWidth/2
            bar.cornerCurve = .circular
            layer.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(VoiceInput.barCount)
        return CGSize(width: count*Self.barWidth+(count-1)*Self.spacing, height: Self.maximumHeight)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        bars.forEach { $0.backgroundColor = UIColor.systemRed.resolvedColor(with: traitCollection).cgColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    /// Follows the level until stopped, the bars settling back to dots.
    func listen(_ listening: Bool) {
        link?.invalidate()
        link = nil
        guard listening else { return }
        heights = heights.map { _ in 0 }
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        place()
    }

    @objc private func step(_ link: CADisplayLink) {
        let level = level?() ?? 0, time = Float(CACurrentMediaTime()-start)
        for index in heights.indices {
            // Each bar wanders at its own pace, so they don't move in step.
            let wander = 0.7+0.3*sin(time*(5.3+Float(index)*1.7)+Float(index)*2.1)
            let target = min(1, level*Self.shape[index]*wander*1.5)
            // Quick to rise with the voice, slower to fall back.
            let rate: Float = target > heights[index] ? 0.35 : 0.14
            heights[index] += (target-heights[index])*rate
        }
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = intrinsicContentSize, width = Self.barWidth
        let left = bounds.midX-size.width/2
        for (index, bar) in bars.enumerated() {
            let height = width+(Self.maximumHeight-width)*CGFloat(heights[index])
            bar.frame = CGRect(x: left+CGFloat(index)*(width+Self.spacing), y: bounds.midY-height/2, width: width, height: height)
        }
        CATransaction.commit()
    }

    /// The display link holds the view, so it stops with the window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { listen(false) }
    }
}
