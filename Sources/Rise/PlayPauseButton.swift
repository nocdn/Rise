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
    /// Holds both symbols and shrinks slightly while pressed.
    private let glyph = CALayer()
    private let playLayer = CALayer()
    private let pauseLayer = CALayer()
    private var renderedKey: (size: CGFloat, scale: CGFloat)?
    static let hiddenScale: CGFloat = 0.25
    static let pressedScale: CGFloat = 0.86
    private var pressed = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(glyph)
        [playLayer, pauseLayer].forEach { glyph.addSublayer($0) }
        show(animated: false)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Pause")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let size = pointSize ?? (bounds.height*0.62).rounded(), scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Transform animations flatten the grouping layer into a temporary
        // surface. Pin its rasterization resolution too, so it never falls back
        // to a soft intermediate surface while either spring is active.
        glyph.contentsScale = scale; glyph.allowsGroupOpacity = false
        glyph.shouldRasterize = true; glyph.rasterizationScale = scale*4
        glyph.bounds = bounds; glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for (symbolLayer, symbol) in [(playLayer, "play.fill"), (pauseLayer, "pause.fill")] {
            if renderedKey?.size != size || renderedKey?.scale != scale,
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
                   NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))) {
                let rasterScale = scale*2
                let imageSize = NSSize(width: image.size.width, height: image.size.height*(symbol == "pause.fill" ? 1.06 : 1))
                symbolLayer.contentsScale = rasterScale
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    symbolLayer.contents = Self.rasterize(image, size: imageSize, scale: rasterScale, pause: symbol == "pause.fill")
                }
                symbolLayer.bounds = CGRect(origin: .zero, size: imageSize)
            }
            symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        renderedKey = (size, scale)
        CATransaction.commit()
    }
    private static func rasterize(_ image: NSImage, size: NSSize, scale: CGFloat, pause: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(ceil(size.width*scale)), height: Int(ceil(size.height*scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = CGRect(origin: .zero, size: size)
        if pause {
            // Narrow each bar independently, keeping their centers and the gap.
            for x in [CGFloat.zero, size.width/2] {
                context.saveGState()
                context.clip(to: CGRect(x: x, y: 0, width: size.width/2, height: size.height))
                let center = x+size.width/4
                context.translateBy(x: center, y: 0); context.scaleBy(x: 0.92, y: 1); context.translateBy(x: -center, y: 0)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                context.restoreGState()
            }
        } else { image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1) }
        return context.makeImage()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); renderedKey = nil; needsLayout = true
    }
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
    private func setPressed(_ pressed: Bool) {
        guard pressed != self.pressed else { return }
        self.pressed = pressed
        PressScale.set(glyph, to: pressed ? Self.pressedScale : 1)
    }
    override func mouseDown(with event: NSEvent) { if isEnabled { setPressed(true) } }
    override func mouseDragged(with event: NSEvent) { setPressed(bounds.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        super.mouseUp(with: event)
    }
    // A pinch over the floating player's button resizes the player.
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
}
