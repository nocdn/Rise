import AppKit

/// A tab's background in the Plain theme, as Kero's sidebar rows (github.com/egoist/kero, view.go
/// and elevation.go): white when chosen, on an even ring a shade darker than the sidebar and a
/// faint shadow close under it, and a 4% shade under the pointer. Each fades in and out over
/// Kero's 110 ms. Fading their opacity mixes them as Kero's premultiplied colours do, where
/// Core Animation's colour fades would dip through grey.
final class PlainTabBackground: FlippedView {
    static let hover = NSColor.black.withAlphaComponent(0.04)
    static let fadeDuration: CFTimeInterval = 0.11
    static let fadeKey = "Rise.PlainTabFade"
    private let hoverLayer = CALayer(), chosenLayer = CALayer(), ring = CALayer()
    var radius: CGFloat = TabAppearance.radius { didSet { if radius != oldValue { needsLayout = true } } }
    var isChosen: Bool { chosenLayer.opacity == 1 }
    var isHovered: Bool { hoverLayer.opacity == 1 }
    /// How much of the chosen white shows now, mid-fade included, for checks.
    var shownChosen: Float { chosenLayer.presentation()?.opacity ?? chosenLayer.opacity }

    init() {
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        hoverLayer.backgroundColor = Self.hover.cgColor
        chosenLayer.backgroundColor = NSColor.white.cgColor
        // Kero's `chosen`: a 0.5 pt ring of 6% black just outside, and a shadow 0.5 pt down,
        // blurred 2 pt (a radius of 1), of 5%.
        ring.borderWidth = 0.5; ring.borderColor = NSColor.black.withAlphaComponent(0.06).cgColor
        chosenLayer.shadowColor = NSColor.black.cgColor; chosenLayer.shadowOpacity = 0.05
        chosenLayer.shadowRadius = 1; chosenLayer.shadowOffset = CGSize(width: 0, height: 0.5)
        [hoverLayer, chosenLayer, ring].forEach { $0.cornerCurve = .continuous }
        hoverLayer.opacity = 0; chosenLayer.opacity = 0
        chosenLayer.addSublayer(ring)
        layer?.addSublayer(hoverLayer); layer?.addSublayer(chosenLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shade in [hoverLayer, chosenLayer] { shade.frame = bounds; shade.cornerRadius = radius }
        ring.frame = bounds.insetBy(dx: -ring.borderWidth, dy: -ring.borderWidth); ring.cornerRadius = radius+ring.borderWidth
        chosenLayer.shadowPath = PageOutline.path(in: bounds, radius: radius, continuous: true)
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
