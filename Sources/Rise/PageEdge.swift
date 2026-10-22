import AppKit

/// Kero's lit edge on the page in Dark (github.com/egoist/kero, elevation.go):
/// a point of its text's colour around the page, brighter along the top than the bottom, as if
/// lit from above. It lies over the page, inside the clip that shapes it, following its outline.
final class PageEdge: FlippedView {
    /// Kero's dark text, and its edge's strength at the top and the bottom: Kero's 18% above, and
    /// 11% below, a little more than Kero's 6%, so the page's foot keeps its edge.
    static let colors = [NSColor(hex: 0xECECF0).withAlphaComponent(0.18), NSColor(hex: 0xECECF0).withAlphaComponent(0.11)]
    private let gradient = CAGradientLayer(), ring = CAShapeLayer()
    /// The page's outline, in this view's coordinates; nil for one page, a rounded rectangle.
    var outline: CGPath? { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.colors = Self.colors.map(\.cgColor)
        // Stroked twice as wide as the edge: the clip around the page keeps the inner half.
        ring.fillColor = nil; ring.strokeColor = NSColor.black.cgColor; ring.lineWidth = 2
        gradient.mask = ring
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds; ring.frame = bounds
        ring.path = outline ?? PageOutline.path(in: bounds, radius: PageAppearance.radius, continuous: true)
        CATransaction.commit()
    }
}
