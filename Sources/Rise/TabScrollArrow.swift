import AppKit

/// A rounded triangle pointing into the tab being chosen by scrolling, with its fill and edge,
/// flattened onto the sidebar's colour so the page behind it cannot change its appearance.
final class TabScrollArrow: FlippedView {
    static let size = NSSize(width: 16, height: 20)
    static let gap: CGFloat = 4
    private let shade = CALayer(), ring = CAShapeLayer(), base = CAShapeLayer(), fill = CAShapeLayer()
    private let edgeHost = CALayer(), edgeClip = CAShapeLayer(), edge = CAGradientLayer(), edgeStroke = CAShapeLayer()
    private var theme: RiseTheme?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        setAccessibilityElement(false)
        shade.shadowColor = NSColor.black.cgColor; shade.shadowRadius = 2
        shade.shadowOffset = NSSize(width: 0, height: 1)
        ring.fillColor = nil; ring.strokeColor = KeroLitEdge.ringColor
        // The fill covers the inner half, leaving Light's half-point ring outside.
        ring.lineWidth = KeroLitEdge.ringWidth*2
        edge.startPoint = CGPoint(x: 0.5, y: 0); edge.endPoint = CGPoint(x: 0.5, y: 1)
        edge.colors = KeroLitEdge.colors
        edgeStroke.fillColor = nil; edgeStroke.strokeColor = NSColor.white.cgColor
        edgeStroke.lineWidth = KeroLitEdge.width*2
        // Clipping the centred stroke leaves Dark's one-point gradient edge inside.
        edge.mask = edgeStroke; edgeHost.mask = edgeClip; edgeHost.addSublayer(edge)
        [shade, ring, base, fill, edgeHost].forEach { layer?.addSublayer($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ theme: RiseTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        let dark = theme == .dark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.fillColor = theme.background.cgColor
        fill.fillColor = PlainTabBackground.chosen(dark: dark).cgColor
        ring.isHidden = dark; edgeHost.isHidden = !dark
        shade.shadowOpacity = dark ? 0.16 : 0.08
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let corners = [NSPoint(x: 0, y: h/2), NSPoint(x: w, y: 0), NSPoint(x: w, y: h)]
        let path = CGMutablePath()
        path.move(to: NSPoint(x: w/2, y: h*0.75))
        for index in corners.indices {
            path.addArc(tangent1End: corners[index], tangent2End: corners[(index+1)%corners.count], radius: 1.8)
        }
        path.closeSubpath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in [shade, ring, base, fill, edgeHost, edgeClip, edge, edgeStroke] { layer.frame = bounds }
        for shape in [ring, base, fill, edgeClip, edgeStroke] { shape.path = path }
        shade.shadowPath = path
        CATransaction.commit()
    }
}

@MainActor extension BrowserController {
    /// Move with the actual row and sidebar, including a floating sidebar's reveal. No separate
    /// movement animation: the arrow and the highlight always point at the same tab.
    func layoutTabScrollArrow() {
        let arrow = tabScroll.arrow
        guard let sidebar, let id = sidebar.scrollFocusID, !sidebar.isHidden,
              let row = sidebar.anchor(for: id), !row.isHiddenOrHasHiddenAncestor else {
            arrow.removeFromSuperview(); return
        }
        let target = row.convert(row.bounds, to: root), side = sidebar.convert(sidebar.bounds, to: root)
        arrow.apply(theme)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.frame = NSRect(x: side.maxX+TabScrollArrow.gap, y: target.midY-TabScrollArrow.size.height/2,
                             width: TabScrollArrow.size.width, height: TabScrollArrow.size.height)
        CATransaction.commit()
        if arrow.superview !== root { raiseHoverCard(arrow) }
    }
}
