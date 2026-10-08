import AppKit
import QuartzCore

@MainActor enum TabListMotion {
    static let duration = 0.18
    static let movementKey = "Rise.TabMovement"
    static func move(_ view: NSView, to frame: NSRect, animated: Bool, at time: CFTimeInterval) {
        guard view.frame != frame else { return }
        let canAnimate = animated && view.frame.size == frame.size && view.frame.minX == frame.minX
        let layer = view.layer
        let old = layer?.presentation()?.position ?? layer?.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
        guard canAnimate, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer, let old, old != layer.position else {
            layer?.removeAnimation(forKey: movementKey); return
        }
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = old; movement.toValue = layer.position
        movement.duration = duration; movement.beginTime = layer.convertTime(time, from: nil)
        movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(movement, forKey: movementKey)
    }
    static let slideKey = "Rise.TabSlide"
    /// Moves a view sideways at once and animates its picture from where it
    /// was shown, so a resize never makes it jump.
    static func slide(_ view: NSView, to frame: NSRect) {
        guard view.frame != frame, let layer = view.layer else { view.frame = frame; return }
        let offset = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        let shownX = view.frame.minX + offset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
        layer.removeAnimation(forKey: slideKey)
        guard shownX != frame.minX else { return }
        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.mass = 1; slide.stiffness = 420; slide.damping = 2*0.9*sqrt(420)
        slide.fromValue = shownX-frame.minX; slide.toValue = 0; slide.duration = slide.settlingDuration
        layer.add(slide, forKey: slideKey)
    }

}

@MainActor final class SidebarDrag {
    let view: NSView
    let id: UUID
    let originalOrder: [UUID]
    let grabOffset: CGFloat
    var event: NSEvent
    init(view: NSView, id: UUID, order: [UUID], grabOffset: CGFloat, event: NSEvent) {
        self.view = view; self.id = id; originalOrder = order; self.grabOffset = grabOffset; self.event = event
    }
}
