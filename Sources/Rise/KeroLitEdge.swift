import AppKit

/// Kero's edges for the chosen tab (`PlainTabBackground`). In Dark, its lit edge: a point inside the
/// outline in Kero's text colour, brighter along the top than the bottom, as if lit from above,
/// which the hover cards wear too in place of a border (`KeroLitEdge.apply`). In Light, its ring:
/// half a point of faint black just outside.
enum KeroLitEdge {
    static let ringWidth: CGFloat = 0.5
    static var ringColor: CGColor { NSColor.black.withAlphaComponent(0.06).cgColor }
    static let text = NSColor(hex: 0xECECF0)
    static let width: CGFloat = 1
    static var colors: [CGColor] { [text.withAlphaComponent(0.18), text.withAlphaComponent(0.06)].map(\.cgColor) }
    /// The ring between the outline and a point inside it, filled even-odd.
    static func path(in bounds: NSRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addPath(PageOutline.path(in: bounds, radius: radius, continuous: true))
        path.addPath(PageOutline.path(in: bounds.insetBy(dx: width, dy: width), radius: max(0, radius-width), continuous: true))
        return path
    }
    /// A card's edge: in Dark, the chosen tab's lit edge; in Light, the card's own thin border.
    @MainActor static func apply(to panel: Surface, theme: RiseTheme) {
        let dark = theme == .dark
        panel.layer?.borderColor = dark ? NSColor.clear.cgColor : theme.border.cgColor
        let edge = panel.subviews.compactMap { $0 as? KeroLitEdgeView }.first ?? {
            let edge = KeroLitEdgeView(frame: panel.bounds); edge.autoresizingMask = [.width, .height]
            panel.addSubview(edge); return edge
        }()
        edge.radius = panel.layer?.cornerRadius ?? 0
        edge.isHidden = !dark
    }
}

/// The lit edge over a card, above its contents and taking no clicks.
final class KeroLitEdgeView: FlippedView {
    private let gradient = CAGradientLayer(), shape = CAShapeLayer()
    var radius: CGFloat = 0 { didSet { if radius != oldValue { needsLayout = true } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.zPosition = 100
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.colors = KeroLitEdge.colors
        shape.fillRule = .evenOdd; gradient.mask = shape
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds; shape.frame = bounds
        shape.path = KeroLitEdge.path(in: bounds, radius: radius)
        CATransaction.commit()
    }
}
