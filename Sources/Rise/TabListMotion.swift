import AppKit
import QuartzCore

@MainActor enum TabListMotion {
    static let duration = 0.18
    static let movementKey = "Rise.TabMovement"
    /// Slides `view` to `frame`. It starts when the frame it's in reaches the screen, so work done
    /// before then, such as showing the next tab's page after a close, can't eat into the slide;
    /// everything moved in the same frame still starts together.
    static func move(_ view: NSView, to frame: NSRect, animated: Bool) {
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
        movement.duration = duration
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
    let grabOffset: NSPoint
    let startPoint: NSPoint
    var isDetached = false
    var overlay: TabDragOverlay?
    var returnWork: DispatchWorkItem?
    var event: NSEvent
    init(view: NSView, id: UUID, order: [UUID], startPoint: NSPoint, event: NSEvent) {
        self.view = view; self.id = id; originalOrder = order; self.startPoint = startPoint; self.event = event
        grabOffset = NSPoint(x: startPoint.x-view.frame.minX, y: startPoint.y-view.frame.minY)
    }
}
