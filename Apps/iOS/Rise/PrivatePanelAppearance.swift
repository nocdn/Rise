import UIKit

/// Reveal the new live colours under a snapshot of the old ones. Only a wide gradient mask
/// moves: text and controls keep their geometry, and a quick reversal starts from what's shown.
@MainActor final class PrivatePanelAppearance {
    static let background = UIColor(red: 34/255, green: 26/255, blue: 49/255, alpha: 1)
    static let duration: CFTimeInterval = 0.28
    private var outgoing: UIView?
    private var eyeTint: UIViewPropertyAnimator?
    #if DEBUG
    var shownSweepY: CGFloat? { outgoing?.layer.mask?.presentation()?.position.y }
    #endif

    func finish(on bar: BottomBar) {
        if eyeTint?.state == .active { eyeTint?.stopAnimation(true) }
        eyeTint = nil
        outgoing?.removeFromSuperview()
        outgoing = nil
        let button = bar.search.privateButton
        if button.superview === bar {
            let center = bar.search.convert(button.center, from: bar)
            bar.search.addSubview(button)
            button.center = center
            button.overrideUserInterfaceStyle = .unspecified
            button.tintColor = .label
        }
    }

    func apply(_ enabled: Bool, to bar: BottomBar, animated: Bool) {
        // Keep the live eye above the colour snapshot, so its own symbol swap starts now.
        let button = bar.search.privateButton, hidden = button.isHidden
        let previousStyle = button.traitCollection.userInterfaceStyle
        let previousTint = button.tintColor.resolvedColor(with: button.traitCollection)
        button.isHidden = true
        let previous = animated && bar.window != nil && !UIAccessibility.isReduceMotionEnabled
            ? bar.snapshotView(afterScreenUpdates: true) : nil
        button.isHidden = hidden
        finish(on: bar)
        outgoing = previous
        UIView.performWithoutAnimation {
            bar.overrideUserInterfaceStyle = enabled ? .dark : .unspecified
            bar.backgroundColor = enabled ? Self.background : BottomBar.background
            bar.layoutIfNeeded()
        }
        guard let previous else { return }
        previous.isUserInteractionEnabled = false
        previous.accessibilityElementsHidden = true
        previous.frame = bar.bounds
        bar.addSubview(previous)
        if bar.panel == .search, !hidden, bar.shown === bar.search {
            let center = bar.convert(button.center, from: button.superview)
            bar.addSubview(button)
            button.center = center
            // The field under the eye still has its outgoing colour until the sweep reaches it.
            button.overrideUserInterfaceStyle = previousStyle
        }
        let height = max(1, bar.bounds.height), feather = min(220, height*0.55)
        let arc = min(72, bar.bounds.width*0.15)
        let travel = height+feather+arc
        if button.superview === bar {
            button.tintColor = previousTint
            let u = min(1, max(0, button.center.x/max(1, bar.bounds.width)))
            let edge = height+arc-arc*4*u*(1-u)
            let crossing = min(1, max(0, (edge+feather/2-button.center.y)/travel))
            let progress = enabled ? crossing : 1-crossing
            // Invert the ease-out curve to change the live eye's tint as the arc reaches it.
            var low: CGFloat = 0, high: CGFloat = 1
            for _ in 0..<12 {
                let t = (low+high)/2
                if t*t*(3-2*t) < progress { low = t } else { high = t }
            }
            let t = (low+high)/2, time = 3*0.58*(1-t)*t*t+t*t*t
            let tint = UIColor.label.resolvedColor(with: bar.traitCollection)
            let animator = UIViewPropertyAnimator(duration: 0.08, curve: .linear) { button.tintColor = tint }
            eyeTint = animator
            animator.startAnimation(afterDelay: max(0, Self.duration*Double(time)-0.04))
        }
        let mask = CALayer()
        mask.anchorPoint = .zero
        // The opaque tail also covers the page at the start of the reverse sweep.
        mask.bounds = CGRect(x: 0, y: 0, width: bar.bounds.width, height: travel+height)
        mask.contents = Self.curvedMask(height: height, feather: feather, arc: arc, enabled: enabled)
        let from: CGFloat = enabled ? 0 : -travel, to: CGFloat = enabled ? -travel : 0
        previous.layer.mask = mask
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.position = CGPoint(x: 0, y: to)
        CATransaction.setCompletionBlock { [weak self, weak previous, weak bar] in
            guard let self, let previous, self.outgoing === previous else { return }
            if let bar { self.finish(on: bar) }
            else { previous.removeFromSuperview(); self.outgoing = nil }
        }
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = from; sweep.toValue = to
        sweep.duration = Self.duration
        sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let rate = Float(min(120, bar.window?.screen.maximumFramesPerSecond ?? 60))
        sweep.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
        mask.add(sweep, forKey: "private-colours")
        CATransaction.commit()
        CATransaction.flush()
    }

    /// A shallow arch in the feathered front: its centre leads its edges. A small alpha
    /// texture is linearly sampled by Core Animation; only its position moves each frame.
    private static func curvedMask(height: CGFloat, feather: CGFloat, arc: CGFloat, enabled: Bool) -> CGImage? {
        let width = 128, rows = 512, extent = Double(2*height+feather+arc)
        let edges = (0..<width).map { x -> Double in
            let u = Double(x)/Double(width-1)
            return Double(height+arc)-Double(arc)*4*u*(1-u)
        }
        var pixels = [UInt8](repeating: 0, count: width*rows*4)
        for y in 0..<rows {
            let position = Double(y)/Double(rows-1)*extent
            for x in 0..<width {
                let opacity = min(1, max(0, (edges[x]+Double(feather)-position)/Double(feather)))
                pixels[(y*width+x)*4+3] = UInt8(((enabled ? opacity : 1-opacity)*255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
