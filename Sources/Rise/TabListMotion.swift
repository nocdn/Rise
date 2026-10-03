import AppKit
import QuartzCore

@MainActor enum TabListMotion {
    static let duration = 0.18
    static let movementKey = "Rise.TabMovement"
    static let pressKey = "Rise.TabPress"
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
    static func press(_ view: NSView, down: Bool, animated: Bool = true) {
        guard let layer = view.layer else { return }
        let scale: CGFloat = down ? 0.99 : 1
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: (1-scale)*view.bounds.width*(0.5-layer.anchorPoint.x),
            ty: (1-scale)*view.bounds.height*(0.5-layer.anchorPoint.y))
        if layer.affineTransform() == transform && layer.animation(forKey: pressKey) == nil { return }
        let old = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { layer.removeAnimation(forKey: pressKey); return }
        let spring = CASpringAnimation(perceptualDuration: 0.12, bounce: 0)
        spring.keyPath = "transform"; spring.fromValue = NSValue(caTransform3D: old); spring.toValue = NSValue(caTransform3D: layer.transform)
        spring.duration = spring.settlingDuration
        spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.add(spring, forKey: pressKey)
    }
    static func mirrorPress(from source: NSView, to destination: NSView) {
        guard let sourceLayer = source.layer, let target = destination.layer else { return }
        func transform(_ scale: CGFloat) -> CATransform3D {
            CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: (1-scale)*destination.bounds.width*(0.5-target.anchorPoint.x),
                ty: (1-scale)*destination.bounds.height*(0.5-target.anchorPoint.y)))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        target.transform = transform(sourceLayer.affineTransform().a)
        CATransaction.commit()
        if let spring = sourceLayer.animation(forKey: pressKey) as? CASpringAnimation,
           let from = spring.fromValue as? NSValue {
            let copy = spring.copy() as! CASpringAnimation
            copy.fromValue = NSValue(caTransform3D: transform(from.caTransform3DValue.m11))
            copy.toValue = NSValue(caTransform3D: target.transform)
            copy.beginTime = target.convertTime(sourceLayer.convertTime(spring.beginTime, to: nil), from: nil)
            target.add(copy, forKey: pressKey)
        } else { target.removeAnimation(forKey: pressKey) }
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
