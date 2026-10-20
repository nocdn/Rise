import UIKit

/// The surviving cards move towards their post-close layout under the finger.
/// Capture presentation poses so a new drag can also catch an unfinished reflow.
@MainActor final class TabDeckDismissal {
    private struct Pose {
        var bounds: CGRect
        var centre: CGPoint
        var transform: CGAffineTransform
        var radius: CGFloat
        var shade: CGFloat
        var title: CGFloat

        init(cell: TabCell) {
            let shown = cell.layer.presentation() ?? cell.layer
            bounds = shown.bounds
            centre = shown.position
            transform = CATransform3DGetAffineTransform(shown.transform)
            radius = cell.card.layer.presentation()?.cornerRadius ?? cell.card.layer.cornerRadius
            shade = cell.shownShadeAmount
            title = CGFloat(cell.title.layer.presentation()?.opacity ?? cell.title.layer.opacity)
        }

        init(frame: CGRect, radius: CGFloat, shade: CGFloat, title: CGFloat) {
            bounds = CGRect(origin: .zero, size: frame.size)
            centre = CGPoint(x: frame.midX, y: frame.midY)
            transform = .identity
            self.radius = radius; self.shade = shade; self.title = title
        }

        func towards(_ target: Pose, by p: CGFloat) -> Pose {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a+(b-a)*p }
            var pose = self
            pose.bounds.size = CGSize(width: mix(bounds.width, target.bounds.width), height: mix(bounds.height, target.bounds.height))
            pose.centre = CGPoint(x: mix(centre.x, target.centre.x), y: mix(centre.y, target.centre.y))
            pose.transform = CGAffineTransform(a: mix(transform.a, target.transform.a), b: mix(transform.b, target.transform.b),
                c: mix(transform.c, target.transform.c), d: mix(transform.d, target.transform.d),
                tx: mix(transform.tx, target.transform.tx), ty: mix(transform.ty, target.transform.ty))
            pose.radius = mix(radius, target.radius)
            pose.shade = max(0, mix(shade, target.shade))
            // Keep the deck's one-title-at-a-time rule while focus passes behind the closing page.
            // A pull down (p below 0) leaves the titles as they are.
            let titleProgress = title > target.title ? min(1, max(0, p*2)) : max(0, p*2-1)
            pose.title = title+(target.title-title)*titleProgress
            return pose
        }
    }

    let cell: TabCell
    let nextFocus: CGFloat
    private let poses: [(cell: TabCell, from: Pose, to: Pose)]
    /// How far up the finger goes for the others to make most of their way, and how far down
    /// the card is pulled for them to lean half their most away.
    private let travel: CGFloat
    private let pullTravel: CGFloat
    /// Under the finger, the others go only this far towards their new places; letting go
    /// finishes the rest.
    static let heldProgress: CGFloat = 0.85
    /// Pulled down, the others lean at most this far the other way, back from their new places.
    static let pullProgress: CGFloat = 0.45
    private(set) var progress: CGFloat = 0
    private(set) var committed = false

    init(cells: [TabCell], order: [Int], closing index: Int, layout: TabDeckLayout) {
        cell = cells[index]
        let closingSlot = order.firstIndex(of: index)!
        nextFocus = Self.focusAfterRemoving(slot: closingSlot, from: layout)
        let target = TabDeckLayout(size: layout.size, stripHeight: layout.stripHeight,
            topInset: layout.topInset, bottomInset: layout.bottomInset, count: cells.count-1, focus: nextFocus)
        travel = max(1, cell.bounds.height*0.5)
        pullTravel = max(1, cell.bounds.height*0.1)
        poses = order.enumerated().compactMap { slot, index -> (cell: TabCell, from: Pose, to: Pose)? in
            let cell = cells[index]
            let nextSlot = slot-(slot > closingSlot ? 1 : 0)
            let distance = CGFloat(nextSlot)-target.focus
            guard !cell.isHidden || (distance >= -5 && distance <= 2.2) else { return nil }
            let frame = layout.frame(at: slot)
            let from = cell.isHidden ? Pose(frame: frame, radius: TabSwitcherView.cornerRadius*frame.width/layout.cardSize.width,
                shade: layout.shadeOpacity(at: slot), title: layout.titleOpacity(at: slot)) : Pose(cell: cell)
            var to: Pose
            if slot == closingSlot {
                to = from
                to.title = 0
            } else {
                let frame = target.frame(at: nextSlot)
                to = Pose(frame: frame, radius: TabSwitcherView.cornerRadius*frame.width/target.cardSize.width,
                          shade: target.shadeOpacity(at: nextSlot), title: target.titleOpacity(at: nextSlot))
            }
            return (cell, from, to)
        }
    }

    static func focusAfterRemoving(slot: Int, from layout: TabDeckLayout) -> CGFloat {
        // Closing the focused card brings its predecessor forward. Closing elsewhere
        // preserves the focused tab's identity, including fractional scroll positions.
        let shift: CGFloat = CGFloat(slot) <= layout.focus+0.5 ? 1 : 0
        return min(CGFloat(max(0, layout.count-2)), max(0, layout.focus-shift))
    }

    /// Follows the card's shown offset. Going up, the others start gently and ease towards
    /// `heldProgress`, so even far up they haven't quite arrived. Pulled down, they lean back
    /// the other way, the opposite of making room, as far as `pullProgress`.
    func follow(offset: CGFloat) {
        if offset <= 0 {
            progress = Self.heldProgress*(1-exp(offset/travel))
        } else {
            progress = -Self.pullProgress*offset/(offset+pullTravel)
        }
        apply()
    }

    /// Normalised spring velocity carries the drag's speed into the remaining distance.
    func releaseVelocity(_ velocity: CGFloat) -> CGFloat {
        let rate = progress >= 0 ? (Self.heldProgress-progress)/travel : 0
        return min(12, max(-8, -velocity*rate/max(0.01, 1-progress)))
    }

    func commit() { committed = true; progress = 1; apply() }

    func catchMotion() {
        for (view, _, _) in poses { Self.stopMotion(view.layer) }
        apply()
    }

    static func stopMotion(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(stopMotion)
    }

    func apply() {
        for (view, from, to) in poses {
            let pose = from.towards(to, by: progress)
            if view.isHidden && progress > 0 { view.isHidden = false }
            view.bounds = pose.bounds
            view.center = pose.centre
            // The swiped card owns its vertical translation and stays opaque.
            if view !== cell { view.transform = pose.transform }
            view.card.layer.cornerRadius = pose.radius
            view.shadeAmount = pose.shade
            view.title.alpha = pose.title
            view.setNeedsLayout(); view.layoutIfNeeded()
        }
    }
}
