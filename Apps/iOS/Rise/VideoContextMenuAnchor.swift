import UIKit

/// Gives UIKit a content-free target at the finger. The page is never a preview:
/// its renderer, scrolling, and videos stay in their original view hierarchy.
@MainActor final class VideoContextMenuAnchor {
    let targeted: UITargetedPreview
    private let anchor: UIView

    init?(page: UIView, point: CGPoint) {
        guard page.window != nil, let parent = page.superview,
              point.x.isFinite, point.y.isFinite, page.bounds.contains(point) else { return nil }
        let center = page.convert(point, to: parent)
        let anchor = UIView(frame: CGRect(x: center.x-0.5, y: center.y-0.5, width: 1, height: 1))
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .clear
        parent.addSubview(anchor)
        self.anchor = anchor

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.shadowPath = UIBezierPath()
        parameters.visiblePath = UIBezierPath(rect: anchor.bounds)
        targeted = UITargetedPreview(view: anchor, parameters: parameters)
    }

    func finish() { anchor.removeFromSuperview() }
}
