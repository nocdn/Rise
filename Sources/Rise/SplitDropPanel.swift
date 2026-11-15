import AppKit
import QuartzCore

/// The two targets over the page while a tab is dragged from the sidebar: "Add left split" and
/// "Add right split", as Dia shows them. Measured from Dia at 60 frames a second, on a 1283 × 847
/// page:
///
/// - At rest each is a white card 313 × 517, its outer edge 36 in from the page's, centred down it,
///   with a dashed outline 8.5 in (6 on, 6 off, 1.5 wide) and the half-filled rectangle over its
///   label in the middle.
/// - While the drag is over the sidebar they wait at 0.62 of that, their outer edges where they were;
///   they come in from nothing, fading up from 0.4, as the drag begins.
/// - Over the page they're drawn to the pointer as it comes their way, up to 25 points by the time
///   it's a third of the way in from their edge; then the nearer one lights: blue, 1.15 times the
///   size, centred 60% of the way from where it rests to the pointer, and following it, the page's
///   edges cutting it off. It goes out again at 37% from its edge.
/// - Each change springs there in about 0.15 seconds, 6% past it at a fifth of a second, settled by a
///   third.
@MainActor final class SplitDropPanel {
    enum Side { case left, right }
    static let restSize = NSSize(width: 313, height: 517)
    static let compactScale: CGFloat = 0.62, litScale: CGFloat = 1.145, appearingScale: CGFloat = 0.4
    static let inset: CGFloat = 36, pull: CGFloat = 25, follow: CGFloat = 0.6
    static let litAt: CGFloat = 1/3, unlitAt: CGFloat = 0.37
    /// Coming onto the page from the sidebar, the pointer's this far in before the left one can
    /// light, so starting a drag doesn't snap it there at once (Dia's lights as soon as it's over).
    static let safeArea: CGFloat = 120

    let side: Side
    let layer = CALayer()
    private let card = CALayer(), dash = CAShapeLayer()
    private let icon = CALayer(), litIcon = CALayer(), label = CATextLayer()
    /// Its size for the page, 1 on a page like Dia's, so everything in it keeps its proportions.
    private(set) var unit: CGFloat = 1
    private(set) var isLit = false
    private var dark = false, contentsScale: CGFloat = 2
    /// The size it was last laid out at, as drawn, and its icons' size then.
    private var laidOut: (size: NSSize, k: CGFloat)?, drawnIcons: CGFloat?

    // Where it's going, springing there each frame.
    var center = SpringPoint(), scale = Spring(value: appearingScale), opacity = Spring(value: 0)

    init(side: Side) {
        self.side = side
        card.cornerCurve = .continuous; card.masksToBounds = false
        card.shadowColor = NSColor.black.cgColor; card.shadowOpacity = 0.16; card.shadowRadius = 14
        dash.fillColor = nil; dash.lineCap = .butt
        label.alignmentMode = .center; label.truncationMode = .end
        label.string = side == .left ? "Add left split" : "Add right split"
        for layer in [icon, litIcon] { layer.contentsGravity = .center }
        litIcon.opacity = 0
        [card, dash, icon, litIcon, label].forEach(layer.addSublayer)
        layer.opacity = 0
    }

    /// Lays it out for a page `unit` times Dia's, in a window of `contentsScale`.
    func size(unit: CGFloat, contentsScale: CGFloat, dark: Bool) {
        guard unit != self.unit || dark != self.dark || contentsScale != self.contentsScale || laidOut == nil else { return }
        self.unit = unit; self.dark = dark; self.contentsScale = contentsScale
        laidOut = nil; drawnIcons = nil
        layOut()
        applyColors(animated: false)
    }

    /// Lays everything in it out at the size it's drawn, rather than scaling a picture of it, so its
    /// label and icon are drawn afresh for each size, sharp on the screen's pixels as it grows to
    /// light and shrinks to wait.
    private func layOut() {
        let k = unit*scale.value, pixel = 1/contentsScale
        func snap(_ value: CGFloat) -> CGFloat { (value/pixel).rounded()*pixel }
        let size = NSSize(width: snap(Self.restSize.width*k), height: snap(Self.restSize.height*k))
        if let laidOut, laidOut.size == size, abs(laidOut.k-k) < 0.002 { return }
        laidOut = (size, k)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bounds = NSRect(origin: .zero, size: size)
        layer.bounds = bounds
        card.frame = bounds; card.cornerRadius = 18*k
        card.shadowOffset = NSSize(width: 0, height: 3*k)
        card.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 18*k, cornerHeight: 18*k, transform: nil)
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 8.5*k, dy: 8.5*k), cornerWidth: 10*k, cornerHeight: 10*k, transform: nil)
        dash.lineDashPattern = [NSNumber(value: Double(6*k)), NSNumber(value: Double(6*k))]
        dash.lineWidth = colors(lit: isLit).lineWidth*k
        let box = NSSize(width: snap(22*k), height: snap(17*k))
        let iconFrame = NSRect(x: snap(size.width/2-box.width/2), y: snap(size.height/2-16*k-box.height/2), width: box.width, height: box.height)
        icon.frame = iconFrame; litIcon.frame = iconFrame
        if drawnIcons.map({ abs($0-k) >= 0.002 }) ?? true { drawIcons(k: k, box: box) }
        label.contentsScale = contentsScale
        label.font = NSFont.systemFont(ofSize: 13.75*k, weight: .semibold)
        label.fontSize = 13.75*k
        let lineHeight = ceil(17*k/pixel)*pixel
        label.frame = NSRect(x: snap(8*k), y: snap(size.height/2+16*k-lineHeight/2), width: size.width-2*snap(8*k), height: lineHeight)
        CATransaction.commit()
    }

    private func drawIcons(k: CGFloat, box: NSSize) {
        drawnIcons = k
        let symbol = side == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled"
        for (layer, lit) in [(icon, false), (litIcon, true)] {
            layer.contents = Self.symbolImage(symbol, pointSize: 18.5*k, color: colors(lit: lit).ink, in: box, scale: contentsScale)
            layer.contentsScale = contentsScale
        }
    }

    struct Colors { let fill, dash, ink: NSColor; let lineWidth: CGFloat }
    func colors(lit: Bool) -> Colors {
        switch (dark, lit) {
        case (false, false): Colors(fill: NSColor(hex: 0xFEFEFE), dash: NSColor(hex: 0xE2E2E2), ink: NSColor(hex: 0x737373), lineWidth: 1.5)
        case (false, true): Colors(fill: NSColor(hex: 0xE1EEF7), dash: NSColor(hex: 0x037FC2), ink: NSColor(hex: 0x017EC1), lineWidth: 1.75)
        case (true, false): Colors(fill: NSColor(hex: 0x2C2C2E), dash: NSColor(white: 1, alpha: 0.2), ink: NSColor(white: 1, alpha: 0.55), lineWidth: 1.5)
        case (true, true): Colors(fill: NSColor(hex: 0x1C3446), dash: NSColor(hex: 0x3D9EE0), ink: NSColor(hex: 0x5AB0EA), lineWidth: 1.75)
        }
    }
    /// Blue as it lights, in two frames as Dia's does, grey again as it goes out.
    func setLit(_ lit: Bool) {
        guard lit != isLit else { return }
        isLit = lit; applyColors(animated: true)
    }
    private func applyColors(animated: Bool) {
        let colors = colors(lit: isLit)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.06)
        card.backgroundColor = colors.fill.cgColor
        card.shadowOpacity = dark ? 0.4 : 0.16
        dash.strokeColor = colors.dash.cgColor; dash.lineWidth = colors.lineWidth*unit*scale.value
        label.foregroundColor = colors.ink.cgColor
        icon.opacity = isLit ? 0 : 1; litIcon.opacity = isLit ? 1 : 0
        CATransaction.commit()
    }

    /// Its frame as drawn, in its host's coordinates.
    var shownFrame: NSRect {
        let size = NSSize(width: Self.restSize.width*unit*scale.value, height: Self.restSize.height*unit*scale.value)
        return NSRect(x: center.x.value-size.width/2, y: center.y.value-size.height/2, width: size.width, height: size.height)
    }
    var cornerRadius: CGFloat { 18*unit*scale.value }
    /// Puts the layer where its springs are, at its size then, on the screen's pixels.
    func render() {
        layOut()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let pixel = 1/contentsScale, size = layer.bounds.size
        let origin = NSPoint(x: ((center.x.value-size.width/2)/pixel).rounded()*pixel, y: ((center.y.value-size.height/2)/pixel).rounded()*pixel)
        layer.anchorPoint = .zero
        layer.position = origin
        layer.opacity = Float(min(1, max(0, opacity.value)))
        CATransaction.commit()
    }

    /// The symbol drawn to fit `box`, centred, at the screen's pixels, so nothing scales it after.
    static func symbolImage(_ name: String, pointSize: CGFloat, color: NSColor, in box: NSSize, scale: CGFloat) -> CGImage? {
        guard box.width > 0, box.height > 0,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium).applying(.init(paletteColors: [color]))) else { return nil }
        let fit = min(box.width/symbol.size.width, box.height/symbol.size.height)
        let drawn = NSSize(width: symbol.size.width*fit, height: symbol.size.height*fit)
        let rect = NSRect(x: (box.width-drawn.width)/2, y: (box.height-drawn.height)/2, width: drawn.width, height: drawn.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((box.width*scale).rounded()), pixelsHigh: Int((box.height*scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = box
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// A value springing to wherever it's sent, keeping its speed when sent somewhere new, so a panel
/// following the pointer never jumps.
struct Spring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    init(value: CGFloat) { self.value = value; target = value }
    /// The spring Dia's panels move on: there in 0.15 seconds, 6% past it at 0.2, settled by 0.35.
    static let motion = (response: 0.31, damping: 0.65)
    static let fade = (response: 0.1, damping: 1.0)
    mutating func step(_ dt: CGFloat, response: Double, damping: Double) {
        let omega = 2*Double.pi/response, stiffness = CGFloat(omega*omega), friction = CGFloat(2*damping*omega)
        // Small steps, so a slow frame doesn't throw it.
        var left = dt
        while left > 0 {
            let h = min(left, 1/240)
            velocity += (stiffness*(target-value)-friction*velocity)*h
            value += velocity*h
            left -= h
        }
    }
    var isSettled: Bool { abs(target-value) < 0.002 && abs(velocity) < 0.02 }
    mutating func jump(to value: CGFloat) { self.value = value; target = value; velocity = 0 }
}
struct SpringPoint {
    var x = Spring(value: 0), y = Spring(value: 0)
    mutating func send(to point: NSPoint) { x.target = point.x; y.target = point.y }
    mutating func jump(to point: NSPoint) { x.jump(to: point.x); y.jump(to: point.y) }
    mutating func step(_ dt: CGFloat, response: Double, damping: Double) {
        x.step(dt, response: response, damping: damping); y.step(dt, response: response, damping: damping)
    }
    var isSettled: Bool { abs(x.target-x.value) < 0.05 && abs(y.target-y.value) < 0.05 && abs(x.velocity) < 0.5 && abs(y.velocity) < 0.5 }
}

/// Holds the panels over the page, cut off at its edges, taking no clicks.
final class SplitDropHost: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
