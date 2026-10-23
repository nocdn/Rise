import AppKit

/// A short pull beyond the sidebar or list frees a tab; a smaller return distance avoids chatter.
@MainActor enum TabDragMotion {
    static let releaseDistance: CGFloat = 48
    static let captureDistance: CGFloat = 18
    static let springKey = "Rise.TabDragSpring"
    static let shadowKey = "Rise.TabDragShadow"
    static let backgroundKey = "Rise.TabDragBackground"
    static let shadowInDuration: TimeInterval = 0.16
    static let shadowOutDuration: TimeInterval = 0.10
    static let liftedShadowOpacity: Float = 0.08
    static let detachedShadowOpacity: Float = 0.28
    static func showShadow(_ view: NSView) {
        guard let layer = view.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Use AppKit's setter too, so it does not reapply default clipping to a shadow-bearing view.
        let shadow = NSShadow()
        shadow.shadowColor = .black; shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: 2)
        view.shadow = shadow
        layer.shadowOpacity = 0
        view.clipsToBounds = false
        layer.masksToBounds = false
        // Explicitly shadow the card, rather than the text and icons in its backing image.
        layer.shadowPath = PageOutline.path(in: view.bounds, radius: TabAppearance.radius, continuous: true)
        CATransaction.commit()
        fadeShadow(view, to: liftedShadowOpacity, duration: shadowInDuration)
    }
    static func updateShadow(_ view: NSView, progress: CGFloat, animated: Bool = false) {
        guard let layer = view.layer else { return }
        let amount = min(1, max(0, progress))
        let eased = Float(amount * amount * (3 - 2 * amount))
        let opacity = liftedShadowOpacity + (detachedShadowOpacity-liftedShadowOpacity)*eased
        guard layer.shadowOpacity != opacity else { return }
        // Interactive changes follow the pull distance without waiting for a timed animation.
        if animated { fadeShadow(view, to: opacity, duration: shadowOutDuration) }
        else {
            layer.removeAnimation(forKey: shadowKey)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.shadowOpacity = opacity
            CATransaction.commit()
        }
    }
    static func fadeShadow(_ view: NSView, to opacity: Float, duration: TimeInterval) {
        guard let layer = view.layer else { return }
        let from = (layer.presentation() ?? layer).shadowOpacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.shadowOpacity = opacity
        CATransaction.commit()
        layer.removeAnimation(forKey: shadowKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = from; fade.toValue = opacity; fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: shadowKey)
    }
    static func fadeBackground(_ view: NSView, animated: Bool, change: () -> Void) {
        let layer = view.layer
        let from = (layer?.presentation() ?? layer)?.backgroundColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
        layer?.removeAnimation(forKey: backgroundKey)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer, let from, let to = layer.backgroundColor, from != to else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = from; fade.toValue = to; fade.duration = shadowOutDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: backgroundKey)
    }
    static func resistedOffset(_ distance: CGFloat) -> CGFloat {
        let pull = max(0, distance)
        return pull * 0.3 / (1 + pull / 96)
    }
    static var spring: CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform.translation")
        spring.mass = 1; spring.stiffness = 520; spring.damping = 2 * 0.68 * sqrt(520)
        spring.duration = spring.settlingDuration
        return spring
    }
    /// The spring is an offset from the live frame, so the cursor can keep moving during the bounce.
    static func move(_ view: NSView, to frame: NSRect, spring: Bool = false) {
        let layer = view.layer
        let visible = layer?.presentation() ?? layer
        let shown = visible.map { NSPoint(x: $0.position.x+$0.transform.m41, y: $0.position.y+$0.transform.m42) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
        guard spring, let layer, let shown else { return }
        layer.removeAnimation(forKey: springKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = Self.spring
        animation.fromValue = NSValue(point: NSPoint(x: shown.x-layer.position.x, y: shown.y-layer.position.y))
        animation.toValue = NSValue(point: .zero)
        layer.add(animation, forKey: springKey)
    }
}

/// Lifts a real row above the page without letting a transparent host consume page clicks.
final class TabDragOverlay: FlippedView {
    // AppKit's button backing layers clip their shadows. A sibling surface keeps the card shadow visible.
    let shadowView = Surface(radius: TabAppearance.radius)
    var onPointerMove: ((NSEvent) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); clipsToBounds = false
        addSubview(shadowView)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { onPointerMove?(event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === shadowView ? nil : hit
    }
}
