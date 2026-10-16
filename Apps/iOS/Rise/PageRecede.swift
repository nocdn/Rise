import UIKit

/// Sets a page back behind a sheet, as iOS does: a little smaller and lower, with rounded corners.
enum PageRecede {
    /// Insets the page about 20 points per side on an iPhone, and lowers it a little.
    static let scale: CGFloat = 0.9
    static let drop: CGFloat = 16
    /// For screens with square corners, or if the screen's can't be read.
    static let cornerRadius: CGFloat = 32

    /// 0 leaves the page at full size and 1 sets it back behind a sheet; beyond 1 it carries on
    /// shrinking at the same rate, as behind a sheet that keeps growing. Reduce Motion keeps it in
    /// place. The page should clip to its bounds, so its corners round.
    @MainActor static func apply(_ amount: CGFloat, to page: UIView) {
        let amount = UIAccessibility.isReduceMotionEnabled ? 0 : max(0, amount)
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
        if page.transform == .identity { apply(0, to: page) }
    }

    /// The screen's own corner radius, which UIKit knows but doesn't make public.
    @MainActor static func screenCornerRadius(of view: UIView) -> CGFloat {
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        let key = "_displayCornerRadius"
        // Asking for a key it doesn't have would crash.
        guard screen.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (screen.value(forKey: key) as? CGFloat) ?? 0
    }
}
