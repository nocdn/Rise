import AppKit

/// A play/pause button shared by the floating player and the tab rows. Each
/// symbol has its own layer, centered on its own bounds, so swapping never
/// shifts either one. The outgoing symbol shrinks away while the incoming one
/// springs up with a slight overshoot.
@MainActor final class PlayPauseButton: GlyphButton {
    private(set) var paused = false
    /// A fixed symbol size; without one, the symbol fills 62% of the height.
    var pointSize: CGFloat? { didSet { needsLayout = true } }
    var weight: NSFont.Weight = .bold { didSet { renderedKey = nil; needsLayout = true } }
    var color: NSColor = .white { didSet { if color != oldValue { renderedKey = nil; needsLayout = true } } }
    private let playLayer = CALayer()
    private let pauseLayer = CALayer()
    private var renderedKey: (size: CGFloat, scale: CGFloat)?
    static let hiddenScale: CGFloat = 0.25
    override init(frame: NSRect) {
        super.init(frame: frame)
        [playLayer, pauseLayer].forEach { layer?.addSublayer($0) }
        show(animated: false)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Pause")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let size = pointSize ?? (bounds.height*0.62).rounded(), scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (glyph, symbol) in [(playLayer, "play.fill"), (pauseLayer, "pause.fill")] {
            if renderedKey?.size != size || renderedKey?.scale != scale,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
                   NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))) {
                glyph.contentsScale = scale; glyph.contents = image.layerContents(forContentsScale: scale)
                glyph.bounds = CGRect(origin: .zero, size: image.size)
            }
            glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        renderedKey = (size, scale)
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    func setPaused(_ paused: Bool, animated: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        setAccessibilityLabel(paused ? "Play" : "Pause")
        show(animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func show(animated: Bool) {
        let incoming = paused ? playLayer : pauseLayer, outgoing = paused ? pauseLayer : playLayer
        // Continue from wherever an interrupted swap currently is.
        let incomingScale = incoming.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? Self.hiddenScale
        let incomingOpacity = incoming.presentation()?.opacity ?? 0
        let outgoingScale = outgoing.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        let outgoingOpacity = outgoing.presentation()?.opacity ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        incoming.removeAllAnimations(); outgoing.removeAllAnimations()
        incoming.opacity = 1; incoming.transform = CATransform3DIdentity
        outgoing.opacity = 0; outgoing.transform = CATransform3DMakeScale(Self.hiddenScale, Self.hiddenScale, 1)
        CATransaction.commit()
        guard animated else { return }
        // Underdamped (ζ ≈ 0.55): about a 12% overshoot, settled in ~0.3s.
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.mass = 1; grow.stiffness = 700; grow.damping = 2*0.55*sqrt(700)
        grow.fromValue = incomingScale; grow.toValue = 1; grow.duration = grow.settlingDuration
        incoming.add(grow, forKey: "swap.scale")
        incoming.add(Self.fade(from: incomingOpacity, to: 1, duration: 0.08), forKey: "swap.opacity")
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = outgoingScale; shrink.toValue = Self.hiddenScale; shrink.duration = 0.12
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        outgoing.add(shrink, forKey: "swap.scale")
        outgoing.add(Self.fade(from: outgoingOpacity, to: 0, duration: 0.1), forKey: "swap.opacity")
    }
    private static func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = to; fade.duration = duration
        return fade
    }
    // A pinch over the floating player's button resizes the player.
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
}
