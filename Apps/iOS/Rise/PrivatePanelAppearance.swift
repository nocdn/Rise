import UIKit

/// Reveal the new live colours under a snapshot of the old ones. Only a wide gradient mask
/// moves: text and controls keep their geometry, and a quick reversal starts from what's shown.
@MainActor final class PrivatePanelAppearance {
    static let background = UIColor(red: 34/255, green: 26/255, blue: 49/255, alpha: 1)
    static let duration: CFTimeInterval = 0.28
    private var outgoing: UIView?
    #if DEBUG
    var shownSweepY: CGFloat? { outgoing?.layer.mask?.presentation()?.position.y }
    #endif

    func finish(on bar: BottomBar) {
        outgoing?.removeFromSuperview()
        outgoing = nil
        bar.layer.removeAnimation(forKey: "private-rubber-band")
    }

    func apply(_ enabled: Bool, to bar: BottomBar, animated: Bool) {
        let previous = animated && bar.window != nil && !UIAccessibility.isReduceMotionEnabled
            ? bar.snapshotView(afterScreenUpdates: false) : nil
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
        let height = max(1, bar.bounds.height), feather = min(220, height*0.55)
        let mask = CAGradientLayer()
        mask.anchorPoint = .zero
        mask.bounds = CGRect(x: 0, y: 0, width: bar.bounds.width, height: height+feather)
        mask.startPoint = CGPoint(x: 0.5, y: 0); mask.endPoint = CGPoint(x: 0.5, y: 1)
        let from: CGFloat, to: CGFloat
        if !enabled {
            mask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
            mask.locations = [0, NSNumber(value: Double(feather/(height+feather))), 1]
            from = -feather; to = height
        } else {
            mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: Double(height/(height+feather))), 1]
            from = 0; to = -height-feather
        }
        previous.layer.mask = mask
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.position = CGPoint(x: 0, y: to)
        CATransaction.setCompletionBlock { [weak self, weak previous, weak bar] in
            guard let self, let previous, self.outgoing === previous else { return }
            previous.removeFromSuperview(); self.outgoing = nil
            if enabled, let bar, bar.panel == .search, bar.isPrivateBrowsing {
                self.rubberBand(bar)
            }
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

    private func rubberBand(_ bar: BottomBar) {
        let height = max(1, bar.bounds.height)
        func pose(_ stretch: CGFloat) -> NSValue {
            var transform = CATransform3DMakeScale(1, 1+stretch/height, 1)
            // Scaling about the centre plus this translation keeps the bottom edge fixed.
            transform.m42 = -stretch/2
            return NSValue(caTransform3D: transform)
        }
        let pulse = CAKeyframeAnimation(keyPath: "transform")
        pulse.values = [pose(0), pose(6), pose(-1.5), pose(0)]
        pulse.keyTimes = [0, 0.25, 0.65, 1]
        pulse.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut), .init(name: .easeOut)]
        pulse.isAdditive = true
        pulse.duration = 0.28
        let rate = Float(min(120, bar.window?.screen.maximumFramesPerSecond ?? 60))
        pulse.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
        bar.layer.add(pulse, forKey: "private-rubber-band")
    }
}
