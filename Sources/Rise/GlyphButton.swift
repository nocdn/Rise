import AppKit

/// A button drawn with layers, with a rounded background while the pointer
/// is over it when `hoverColor` is set, as on the tab rows' buttons.
@MainActor class GlyphButton: NSView {
    var action: (() -> Void)?
    var hoverColor: NSColor? { didSet { refreshHover() } }
    var acceptsFirstClick = true
    var isEnabled = true { didSet { setAccessibilityEnabled(isEnabled) } }
    private var hovering = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 6; layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        if hoverColor != nil {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        refreshHover()
    }
    /// Revealing or moving the button can leave its tracking state at the previous geometry.
    func refreshHover() {
        if let window, window.isVisible, !isHiddenOrHasHiddenAncestor, hoverColor != nil {
            // Without clipping, visibleRect alone can span the whole window.
            hovering = visibleRect.intersection(bounds).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else { hovering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = hovering ? hoverColor?.cgColor : nil
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; action?(); return true }
}

/// Shrinks a button's layer while it is pressed: quickly down on press, then a
/// slightly springy return on release.
@MainActor enum PressScale {
    static func set(_ layer: CALayer, to scale: CGFloat) {
        let current = layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "press")
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation: CABasicAnimation
        if scale < 1 {
            animation = CABasicAnimation(keyPath: "transform.scale")
            animation.duration = 0.08; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        } else {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.mass = 1; spring.stiffness = 520; spring.damping = 2*0.6*sqrt(520)
            spring.duration = spring.settlingDuration; animation = spring
        }
        animation.fromValue = current; animation.toValue = scale
        layer.add(animation, forKey: "press")
    }
}
