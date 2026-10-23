import AppKit

/// A tab's background, as Kero's sidebar rows (github.com/egoist/kero, view.go
/// and elevation.go), and a shade under the pointer. In Light, the chosen one is white on an even
/// ring a shade darker than the sidebar, with a faint shadow close under it; in Dark, a tenth of
/// white with Kero's lit edge, its text's colour brighter along the top than the bottom, over
/// three tight shadows. Each fades in and out over Kero's 110 ms. Fading their opacity mixes them
/// as Kero's premultiplied colours do, where Core Animation's colour fades would dip through grey.
final class PlainTabBackground: FlippedView {
    static func hover(dark: Bool) -> NSColor { dark ? .white.withAlphaComponent(0.05) : .black.withAlphaComponent(0.04) }
    static func chosen(dark: Bool) -> NSColor { dark ? .white.withAlphaComponent(0.1) : .white }
    static let fadeDuration: CFTimeInterval = 0.11
    static let fadeKey = "Rise.PlainTabFade"
    /// Kero's shadows, as CSS writes them: down, blur, spread, black's opacity.
    private static let lightShadows: [(y: CGFloat, blur: CGFloat, spread: CGFloat, opacity: Float)] = [(0.5, 2, 0, 0.05)]
    private static let darkShadows: [(y: CGFloat, blur: CGFloat, spread: CGFloat, opacity: Float)] = [(1, 1, 0, 0.2), (2, 2, -1, 0.2), (4, 6, -3, 0.24)]

    private let hoverLayer = CALayer()
    /// The chosen look, fading as one: its shadows, fill and edge.
    private let chosenLayer = CALayer(), fill = CALayer(), ring = CALayer()
    /// The shadows show only outside the tab, as CSS's do: Dark's fill shows what's under it.
    private let shadowHost = CALayer(), shadowCut = CAShapeLayer()
    private var shadows: [CALayer] = []
    private let litEdge = CAGradientLayer(), litEdgeShape = CAShapeLayer()
    var radius: CGFloat = TabAppearance.radius { didSet { if radius != oldValue { needsLayout = true } } }
    var dark = false { didSet { if dark != oldValue { applyStyle(); needsLayout = true } } }
    var isChosen: Bool { chosenLayer.opacity == 1 }
    var isHovered: Bool { hoverLayer.opacity == 1 }
    /// How much of the chosen look shows now, mid-fade included, for checks.
    var shownChosen: Float { chosenLayer.presentation()?.opacity ?? chosenLayer.opacity }

    init() {
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        [hoverLayer, fill, ring].forEach { $0.cornerCurve = .continuous }
        shadowCut.fillRule = .evenOdd; shadowHost.mask = shadowCut
        litEdge.mask = litEdgeShape; litEdgeShape.fillRule = .evenOdd
        // Lit from above: the edge's top brighter than its bottom.
        litEdge.startPoint = CGPoint(x: 0.5, y: 0); litEdge.endPoint = CGPoint(x: 0.5, y: 1)
        litEdge.colors = KeroLitEdge.colors
        // Light's ring: 0.5 pt of 6% black just outside.
        ring.borderWidth = KeroLitEdge.ringWidth; ring.borderColor = KeroLitEdge.ringColor
        hoverLayer.opacity = 0; chosenLayer.opacity = 0
        [shadowHost, fill, ring, litEdge].forEach(chosenLayer.addSublayer)
        layer?.addSublayer(hoverLayer); layer?.addSublayer(chosenLayer)
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyStyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverLayer.backgroundColor = Self.hover(dark: dark).cgColor
        fill.backgroundColor = Self.chosen(dark: dark).cgColor
        ring.isHidden = dark; litEdge.isHidden = !dark
        shadows.forEach { $0.removeFromSuperlayer() }
        shadows = (dark ? Self.darkShadows : Self.lightShadows).map { spec in
            let shadow = CALayer()
            shadow.shadowColor = NSColor.black.cgColor; shadow.shadowOpacity = spec.opacity
            shadow.shadowRadius = spec.blur/2; shadow.shadowOffset = CGSize(width: 0, height: spec.y)
            shadowHost.addSublayer(shadow)
            return shadow
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shade in [hoverLayer, fill] { shade.frame = bounds; shade.cornerRadius = radius }
        chosenLayer.frame = bounds; shadowHost.frame = bounds; shadowCut.frame = bounds
        ring.frame = bounds.insetBy(dx: -ring.borderWidth, dy: -ring.borderWidth); ring.cornerRadius = radius+ring.borderWidth
        let outline = PageOutline.path(in: bounds, radius: radius, continuous: true)
        for (shadow, spec) in zip(shadows, dark ? Self.darkShadows : Self.lightShadows) {
            shadow.frame = bounds
            // A spread grows or shrinks the shape that casts it.
            shadow.shadowPath = PageOutline.path(in: bounds.insetBy(dx: -spec.spread, dy: -spec.spread), radius: max(0, radius+spec.spread), continuous: true)
        }
        let cut = CGMutablePath(); cut.addRect(bounds.insetBy(dx: -40, dy: -40)); cut.addPath(outline)
        shadowCut.path = cut
        litEdge.frame = bounds; litEdgeShape.frame = bounds
        litEdgeShape.path = KeroLitEdge.path(in: bounds, radius: radius)
        CATransaction.commit()
    }

    func show(chosen: Bool, hovered: Bool, animated: Bool) {
        fade(chosenLayer, on: chosen, animated: animated)
        fade(hoverLayer, on: hovered, animated: animated)
    }
    private func fade(_ shade: CALayer, on: Bool, animated: Bool) {
        let target: Float = on ? 1 : 0
        guard shade.opacity != target else { return }
        let from = shade.presentation()?.opacity ?? shade.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shade.opacity = target
        CATransaction.commit()
        guard animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            shade.removeAnimation(forKey: Self.fadeKey); return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = target; fade.duration = Self.fadeDuration
        // Kero's ease-out: a cubic, 1-(1-t)³.
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        shade.add(fade, forKey: Self.fadeKey)
    }
}
