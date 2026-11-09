import AppKit
import QuartzCore

@MainActor enum TabListMotion {
    static let duration = 0.18
    /// A closed tab's row fades in about half the slide, gone before the rows below settle.
    static let fadeOutDuration = 0.1
    static let movementKey = "Rise.TabMovement"
    /// Slides `view` to `frame`. It starts when the frame it's in reaches the screen, so work done
    /// before then, such as showing the next tab's page after a close, can't eat into the slide;
    /// everything moved in the same frame still starts together.
    /// `shift` moves where it starts by that much, as the list scrolling under it by that much at
    /// once would, so it stays where it was on screen and slides from there.
    static func move(_ view: NSView, to frame: NSRect, animated: Bool, shift: CGFloat = 0) {
        guard view.frame != frame || shift != 0 else { return }
        let canAnimate = animated && view.frame.size == frame.size && view.frame.minX == frame.minX
        let layer = view.layer
        var old = layer?.presentation()?.position ?? layer?.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if shift != 0, let layer, let start = old {
            // The same offset in the layer's own terms, whichever way up its geometry is.
            let model = layer.position
            view.frame = view.frame.offsetBy(dx: 0, dy: shift)
            old = CGPoint(x: start.x+layer.position.x-model.x, y: start.y+layer.position.y-model.y)
        }
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
    /// The shared media/Peek accessory entry and exit: a quick fade, leaving their
    /// movement to `slide` so the row's controls can exchange places smoothly.
    static func fadeAccessory(_ view: NSView, visible: Bool, animated: Bool, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? (visible ? 0.18 : 0.12) : 0
            view.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { MainActor.assumeIsolated { completion() } }
    }
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
    /// Above New Tab: the grid slot it would be pinned in, and the tile it shows as meanwhile.
    var pinSlot: Int?
    var ghost: PinnedTabTile?
    var grab = NSPoint.zero
    init(view: NSView, id: UUID, order: [UUID], startPoint: NSPoint, event: NSEvent) {
        self.view = view; self.id = id; originalOrder = order; self.startPoint = startPoint; self.event = event
        grabOffset = NSPoint(x: startPoint.x-view.frame.minX, y: startPoint.y-view.frame.minY)
    }
}
