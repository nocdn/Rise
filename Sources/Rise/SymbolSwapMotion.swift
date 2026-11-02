import AppKit

/// The tab's play/pause swap: the old glyph shrinks while the new one springs in.
@MainActor enum SymbolSwapMotion {
    static let hiddenScale: CGFloat = 0.25
    static func show(_ incoming: CALayer, replacing outgoing: CALayer, animated: Bool) {
        let incomingScale = incoming.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? hiddenScale
        let incomingOpacity = incoming.presentation()?.opacity ?? 0
        let outgoingScale = outgoing.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        let outgoingOpacity = outgoing.presentation()?.opacity ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        incoming.removeAllAnimations(); outgoing.removeAllAnimations()
        incoming.opacity = 1; incoming.transform = CATransform3DIdentity
        outgoing.opacity = 0; outgoing.transform = CATransform3DMakeScale(hiddenScale, hiddenScale, 1)
        CATransaction.commit()
        guard animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.mass = 1; grow.stiffness = 700; grow.damping = 2*0.55*sqrt(700)
        grow.fromValue = incomingScale; grow.toValue = 1; grow.duration = grow.settlingDuration
        incoming.add(grow, forKey: "swap.scale")
        incoming.add(fade(from: incomingOpacity, to: 1, duration: 0.08), forKey: "swap.opacity")
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = outgoingScale; shrink.toValue = hiddenScale; shrink.duration = 0.12
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        outgoing.add(shrink, forKey: "swap.scale")
        outgoing.add(fade(from: outgoingOpacity, to: 0, duration: 0.1), forKey: "swap.opacity")
    }
    private static func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = to; fade.duration = duration
        return fade
    }
}
