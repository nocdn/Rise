import AppKit

@MainActor extension BrowserController {
    /// Transform the card and its controls together without resizing the live page.
    func dragPeek(pull: Double) {
        guard peekCard != nil else { return }
        hideLinkStatus()
        peekSwipePull = pull
        applyPeekSwipeTransform()
    }

    private var peekSwipeViews: [NSView] {
        [peekCard].compactMap { $0 } + peekControls + peekGhosts.filter { $0.phase == .opening }
    }

    /// The incoming pull already tapers smoothly beyond the threshold. Use it
    /// directly so the card does not compound the gesture's resistance.
    nonisolated static func peekVisualProgress(for pull: Double) -> Double {
        max(0, pull)
    }

    var peekRecededPageScale: CGFloat {
        // The background grows at half the previous rate.
        // Behind a second Peek, the page sits a little further back.
        (parkedPeek == nil ? Self.peekPageScale : Self.deepPageScale) + 0.005 * CGFloat(Self.peekVisualProgress(for: peekSwipePull))
    }

    func applyPeekSwipeTransform() {
        guard peekMotionAllowed else { return }
        let progress = CGFloat(Self.peekVisualProgress(for: peekSwipePull))
        let scale = 1 - 0.03 * progress, shift = 20 * progress
        let pivot = NSPoint(x: peekCardFrame.midX, y: peekCardFrame.midY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for view in peekSwipeViews {
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: "peek.swipeReturn")
            // Each layer has its own anchor, but all move around the card's center.
            let dx = shift + (pivot.x - layer.position.x) * (1 - scale)
            let dy = (pivot.y - layer.position.y) * (1 - scale)
            layer.transform = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                                 CATransform3DMakeTranslation(dx, dy, 0))
        }
        CATransaction.commit()
        recedePage(true, along: nil)
    }

    func returnPeekFromSwipe() {
        guard peekSwipePull != 0 else { return }
        peekSwipePull = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for view in peekSwipeViews {
            guard let layer = view.layer else { continue }
            let from = layer.presentation()?.transform ?? layer.transform
            layer.transform = CATransform3DIdentity
            if peekMotionAllowed {
                let spring = CASpringAnimation(perceptualDuration: 0.18, bounce: 0.08)
                spring.keyPath = "transform"; spring.fromValue = NSValue(caTransform3D: from)
                spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                spring.duration = spring.settlingDuration
                layer.add(spring, forKey: "peek.swipeReturn")
            }
        }
        CATransaction.commit()
        let spring = peekMotionAllowed ? CASpringAnimation(perceptualDuration: 0.18, bounce: 0.08) : nil
        recedePage(true, along: spring)
    }

    /// Includes both the live drag transform and any ongoing opening/return spring.
    func visiblePeekFrame(_ view: NSView) -> NSRect {
        view.layer?.presentation()?.frame ?? view.layer?.frame ?? view.frame
    }
}
