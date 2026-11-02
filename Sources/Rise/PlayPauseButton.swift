import AppKit

/// A play/pause button shared by the floating player, the tab rows and downloads. Each
/// symbol has its own layer, centered on its own bounds, so swapping never
/// shifts either one. The outgoing symbol shrinks away while the incoming one
/// springs up with a slight overshoot.
@MainActor final class PlayPauseButton: GlyphButton {
    private(set) var paused = false
    /// A fixed symbol size; without one, the symbol fills 62% of the height.
    var pointSize: CGFloat? { didSet { needsLayout = true } }
    var weight: NSFont.Weight = .bold { didSet { renderedKey = nil; needsLayout = true } }
    var color: NSColor = .white { didSet { if color != oldValue { renderedKey = nil; needsLayout = true } } }
    /// Pause bars drawn to measure instead of the symbol's, in points: each bar's size and corner
    /// radius, and how far apart their middles are.
    struct PauseBars { var width: CGFloat, height: CGFloat, radius: CGFloat, spacing: CGFloat }
    var pauseBars: PauseBars? { didSet { renderedKey = nil; needsLayout = true } }
    /// Holds both symbols. It doesn't shrink while pressed; with `growsOnHover`, it grows slightly under the pointer.
    private let glyph = CALayer()
    private let playLayer = CALayer()
    private let pauseLayer = CALayer()
    private var renderedKey: (size: CGFloat, scale: CGFloat)?
    static let hiddenScale = SymbolSwapMotion.hiddenScale
    static let hoverScale: CGFloat = 1.08
    /// The floating player's: a touch bigger under the pointer.
    var growsOnHover = false { didSet { updateTrackingAreas(); refreshGrowth() } }
    private var grown = false
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
                let rasterScale = scale*2, pause = symbol == "pause.fill"
                let bars = pause ? pauseBars : nil
                let imageSize = NSSize(width: image.size.width, height: max(image.size.height*(pause ? 1.06 : 1), bars?.height ?? 0))
                symbolLayer.contentsScale = rasterScale
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    symbolLayer.contents = bars.map { Self.rasterize($0, color: color, size: imageSize, scale: rasterScale) }
                        ?? Self.rasterize(image, size: imageSize, scale: rasterScale, pause: pause)
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
    private static func rasterize(_ bars: PauseBars, color: NSColor, size: NSSize, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(ceil(size.width*scale)), height: Int(ceil(size.height*scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setFill()
        for middle in [size.width/2-bars.spacing/2, size.width/2+bars.spacing/2] {
            let bar = NSRect(x: middle-bars.width/2, y: (size.height-bars.height)/2, width: bars.width, height: bars.height)
            NSBezierPath(roundedRect: bar, xRadius: bars.radius, yRadius: bars.radius).fill()
        }
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
        SymbolSwapMotion.show(incoming, replacing: outgoing, animated: animated)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if growsOnHover {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); refreshGrowth() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); refreshGrowth() }
    /// Tracking only follows the pointer, so a player that moved or faded under a still one checks again.
    func refreshGrowth() {
        var hovering = false
        if growsOnHover, let window, window.isVisible, !isHiddenOrHasHiddenAncestor {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        guard hovering != grown else { return }
        grown = hovering
        PressScale.set(glyph, to: hovering ? Self.hoverScale : 1)
    }
    // A pinch over the floating player's button resizes the player.
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
}
