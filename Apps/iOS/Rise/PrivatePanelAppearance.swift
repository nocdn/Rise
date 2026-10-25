import UIKit

/// Change to the private colours, and back, as one: the old colours fade quickly off the whole
/// panel over the new live ones, starting at once. Text and controls keep their geometry, and a
/// quick reversal starts from what's shown.
@MainActor final class PrivatePanelAppearance {
    static let background = UIColor(red: 34/255, green: 26/255, blue: 49/255, alpha: 1)
    static let duration: CFTimeInterval = 0.14
    private var outgoing: UIView?
    private var eyeTint: UIViewPropertyAnimator?
    /// Controls lifted above the old colours, so their own motion shows from the start, and
    /// where they came from.
    private var lifted: [(view: UIView, home: UIView)] = []
    #if DEBUG
    /// How much of the old colours still shows, while they fade.
    var shownFade: Float? { outgoing?.layer.presentation()?.opacity }
    #endif

    func finish(on bar: BottomBar) {
        if eyeTint?.state == .active { eyeTint?.stopAnimation(true) }
        eyeTint = nil
        outgoing?.removeFromSuperview()
        outgoing = nil
        for (view, home) in lifted where view.superview === bar {
            let center = home.convert(view.center, from: bar)
            home.addSubview(view)
            view.center = center
            view.overrideUserInterfaceStyle = .unspecified
        }
        lifted = []
        bar.search.privateButton.tintColor = .label
    }

    func apply(_ enabled: Bool, to bar: BottomBar, animated: Bool) {
        let button = bar.search.privateButton
        let previousStyle = button.traitCollection.userInterfaceStyle
        let previousTint = button.tintColor.resolvedColor(with: button.traitCollection)
        // What's on screen now, without waiting for another frame to be drawn.
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
        // The control that was tapped keeps moving above the old colours: the eye's symbol swap,
        // or Incognito mode's switch, which shows through a hole in them. Moved out of its row, the
        // switch's glass thumb would be drawn away from its track.
        if bar.panel == .search, !button.isHidden, bar.shown === bar.search {
            lift(button, in: bar)
            // The eye changes colour with everything under it.
            button.overrideUserInterfaceStyle = previousStyle
            button.tintColor = previousTint
            let tint = UIColor.label.resolvedColor(with: bar.traitCollection)
            let animator = UIViewPropertyAnimator(duration: Self.duration, curve: .easeOut) { button.tintColor = tint }
            eyeTint = animator
            animator.startAnimation()
        } else if bar.panel == .tabMenu, bar.shown === bar.tabMenu {
            let toggle = bar.tabMenu.incognitoRow.toggle
            let frame = bar.convert(toggle.bounds, from: toggle).insetBy(dx: -1, dy: -1)
            let path = UIBezierPath(rect: previous.bounds)
            path.append(UIBezierPath(roundedRect: frame, cornerRadius: frame.height/2))
            let hole = CAShapeLayer()
            hole.frame = previous.bounds
            hole.path = path.cgPath
            hole.fillRule = .evenOdd
            previous.layer.mask = hole
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previous.layer.opacity = 0
        CATransaction.setCompletionBlock { [weak self, weak previous, weak bar] in
            guard let self, let previous, self.outgoing === previous else { return }
            if let bar { self.finish(on: bar) }
            else { previous.removeFromSuperview(); self.outgoing = nil }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.duration = Self.duration
        // Changing visibly from the first frame, rather than easing in.
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let rate = Float(min(120, bar.window?.screen.maximumFramesPerSecond ?? 60))
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
        previous.layer.add(fade, forKey: "private-colours")
        CATransaction.commit()
        CATransaction.flush()
    }

    private func lift(_ view: UIView, in bar: BottomBar) {
        guard let home = view.superview, home !== bar else { return }
        let center = bar.convert(view.center, from: home)
        bar.addSubview(view)
        view.center = center
        lifted.append((view, home))
    }
}
