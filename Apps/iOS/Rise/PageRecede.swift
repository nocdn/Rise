import UIKit

/// Sets a page back behind a sheet, as iOS does: a little smaller and lower, with rounded corners.
enum PageRecede {
    /// Insets the page about 20 points per side on an iPhone, and lowers it a little.
    static let scale: CGFloat = 0.9
    static let drop: CGFloat = 16
    /// Fallback for earlier iOS versions, detached views and square-cornered containers.
    static let cornerRadius: CGFloat = 32

    /// 0 leaves the page at full size and 1 sets it back behind a sheet; beyond 1 it carries on
    /// shrinking at the same rate, as behind a sheet that keeps growing, down to half its size: any
    /// further and its scale would cross zero and flip it, which an animation shows as a spin.
    /// Reduce Motion keeps it in place. The page should clip to its bounds, so its corners round.
    static let maximumAmount: CGFloat = 5
    @MainActor static func apply(_ amount: CGFloat, to page: UIView) {
        let amount = UIAccessibility.isReduceMotionEnabled ? 0 : min(Self.maximumAmount, max(0, amount))
        let scale = 1-(1-Self.scale)*amount, scaleBefore = page.transform.a
        page.transform = CGAffineTransform(translationX: 0, y: drop*amount).scaledBy(x: scale, y: scale)
        page.layer.cornerCurve = .continuous
        let screen = screenCornerRadius(of: page)
        guard screen > 0 else { page.layer.cornerRadius = cornerRadius*min(1, amount); return }
        let returning = UIView.inheritedAnimationDuration > 0 && page.layer.cornerRadius > 0
        // At full size, other than on its way back there, the corners are square: the screen's
        // already round them, and a rounded page costs more to draw as it scrolls.
        guard amount > 0 || returning else { page.layer.cornerRadius = 0; return }
        // Its corners follow the screen's, as far in as the page is from its sides, so it never
        // looks cut square into the screen's rounded corners. They round as soon as it starts to
        // go back, rather than growing from square, and stay round as it comes forward again.
        if page.layer.cornerRadius == 0 {
            UIView.performWithoutAnimation { page.layer.cornerRadius = screen/max(0.01, scaleBefore) }
        }
        let inset = page.bounds.width*(1-scale)/2
        // The radius is in the page's own points, before it's scaled down.
        page.layer.cornerRadius = max(0, screen-inset)/scale
    }

    /// Squares the page's corners once it's back at full size, after the move that brought it there.
    @MainActor static func settle(_ page: UIView) {
        if page.transform == .identity {
            UIView.performWithoutAnimation { page.layer.cornerRadius = 0 }
        }
    }

    /// Resolve the window's screen-concentric corners through public UIKit geometry. Keep
    /// the measuring view outside the page's transform so shrinking never feeds back into
    /// the next radius, and reuse it for the page and every tab-card flight in this window.
    @MainActor static func screenCornerRadius(of view: UIView) -> CGFloat {
        guard let window = view.window else { return cornerRadius }
        if #available(iOS 26, *) {
            let geometry = window.subviews.first { $0 is WindowCorners } as? WindowCorners ?? WindowCorners(window: window)
            if geometry.frame != window.bounds { geometry.frame = window.bounds }
            // UIKit resolves the concentric configuration during layout, including the
            // very first call made from an animation's opening frame.
            geometry.layoutIfNeeded()
            return geometry.effectiveRadius(corner: .allCorners)
        }
        return cornerRadius
    }
}

/// Transparent, noninteractive geometry only; it never clips or changes the window's content.
@available(iOS 26, *)
private final class WindowCorners: UIView {
    init(window: UIWindow) {
        super.init(frame: window.bounds)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        alpha = 0
        cornerConfiguration = .uniformCorners(radius: .containerConcentric(minimum: 0))
        window.insertSubview(self, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
}
