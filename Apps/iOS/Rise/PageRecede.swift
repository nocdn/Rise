import UIKit

/// Sets a page back behind a sheet, as iOS does: a little smaller and lower, with rounded corners.
enum PageRecede {
    /// Insets the page about 20 points per side on an iPhone, and lowers it a little.
    static let scale: CGFloat = 0.9
    static let drop: CGFloat = 16
    static let cornerRadius: CGFloat = 32

    /// 0 leaves the page at full size and 1 sets it back behind a sheet; beyond 1 it carries on
    /// shrinking at the same rate, as behind a sheet that keeps growing. Reduce Motion keeps it in
    /// place. The page should clip to its bounds, so its corners round.
    @MainActor static func apply(_ amount: CGFloat, to page: UIView) {
        let amount = UIAccessibility.isReduceMotionEnabled ? 0 : max(0, amount)
        let scale = 1-(1-Self.scale)*amount
        page.transform = CGAffineTransform(translationX: 0, y: drop*amount).scaledBy(x: scale, y: scale)
        page.layer.cornerCurve = .continuous
        page.layer.cornerRadius = cornerRadius*min(1, amount)
    }
}
