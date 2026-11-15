import AppKit

/// The glow round the edges of a page while the chat's model uses it (`AIChatPageDriver`): blue
/// light that moves slowly round the page's edges, fading in from them, so it's plain whose page
/// it is for now. It takes no clicks and isn't in the page, so neither the person's input nor the
/// model's screenshots meet it. The chat's stop button ends it, as it ends the model's turn.
@MainActor final class AIChatGlow: NSView {
    /// How long a turn of the light round the page takes, and the breathing's.
    static let turn: CFTimeInterval = 9
    static let breath: CFTimeInterval = 2.6

    private let lights = CALayer()
    private let band = CALayer()
    private let base = CALayer()
    private let swirl = CAGradientLayer()
    private let counter = CAGradientLayer()
    private let dots = CALayer()
    private var bandWidth: CGFloat = 0
    private(set) var isShowing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        guard let layer else { return }
        layer.masksToBounds = true
        layer.opacity = 0
        lights.mask = band
        band.contentsGravity = .resize
        layer.addSublayer(lights)
        // Never empty: a wash of blue under the moving light.
        base.backgroundColor = NSColor(srgbRed: 0.27, green: 0.5, blue: 1, alpha: 0.62).cgColor
        lights.addSublayer(base)
        // The light that goes round: brighter and deeper blues by angle, turning.
        swirl.type = .conic
        swirl.startPoint = CGPoint(x: 0.5, y: 0.5); swirl.endPoint = CGPoint(x: 0.5, y: 0)
        swirl.colors = Self.colors([(0.30, 0.58, 1, 1), (0.16, 0.36, 1, 0.7), (0.38, 0.46, 1, 0.95), (0.50, 0.80, 1, 1),
                                    (0.14, 0.32, 0.98, 0.65), (0.36, 0.55, 1, 1), (0.30, 0.58, 1, 1)])
        lights.addSublayer(swirl)
        // A second, fainter, turning the other way more slowly, so the light never repeats plainly.
        counter.type = .conic
        counter.startPoint = CGPoint(x: 0.5, y: 0.5); counter.endPoint = CGPoint(x: 1, y: 0.5)
        counter.colors = Self.colors([(0.75, 0.9, 1, 0.0), (0.78, 0.92, 1, 0.75), (0.75, 0.9, 1, 0.0), (0.4, 0.55, 1, 0.5), (0.75, 0.9, 1, 0.0)])
        counter.compositingFilter = "screenBlendMode"
        lights.addSublayer(counter)
        // Fine dots over the light, as a halftone.
        dots.backgroundColor = NSColor(patternImage: Self.dotPattern).cgColor
        dots.opacity = 0.85
        dots.compositingFilter = "screenBlendMode"
        lights.addSublayer(dots)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    /// Shows the glow over `page`, on top of it, fading in if it wasn't already showing.
    func show(over page: NSView) {
        if superview !== page || page.subviews.last !== self {
            frame = page.bounds
            page.addSubview(self, positioned: .above, relativeTo: nil)
        }
        guard !isShowing, let layer else { return }
        isShowing = true
        layOut()
        startMoving()
        let shown = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown; fade.toValue = 1; fade.duration = 0.5
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }
    /// Fades the glow out and takes it away.
    func hide() {
        guard isShowing, let layer else { return }
        isShowing = false
        let shown = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShowing else { return }
                self.lights.removeAllAnimations(); self.swirl.removeAllAnimations(); self.counter.removeAllAnimations()
                self.removeFromSuperview()
            }
        }
        layer.removeAnimation(forKey: "fade")
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown; fade.toValue = 0; fade.duration = 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layOut()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        bandWidth = 0
        layOut()
    }

    private func layOut() {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        lights.frame = bounds; band.frame = bounds; base.frame = bounds; dots.frame = bounds
        // Squares round the middle, big enough that their corners never show as they turn.
        let side = hypot(bounds.width, bounds.height)*1.05
        let square = CGRect(x: bounds.midX-side/2, y: bounds.midY-side/2, width: side, height: side)
        for layer in [swirl, counter] { layer.bounds = CGRect(origin: .zero, size: square.size); layer.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        // The band the light shows in: wider on a bigger page, in steps, so it's drawn rarely.
        let width = (min(max(min(bounds.width, bounds.height)*0.14, 60), 150)/8).rounded()*8
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if width != bandWidth || band.contentsScale != scale {
            bandWidth = width
            band.contents = Self.bandImage(width: width, radius: PageAppearance.radius, scale: scale)
            band.contentsScale = scale
            let whole = 2*width+1
            band.contentsCenter = CGRect(x: width/whole, y: width/whole, width: 1/whole, height: 1/whole)
        }
        CATransaction.commit()
    }

    private func startMoving() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !still {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -2*Double.pi; spin.duration = Self.turn; spin.repeatCount = .infinity
            swirl.add(spin, forKey: "spin")
            let back = CABasicAnimation(keyPath: "transform.rotation.z")
            back.fromValue = 0.6; back.toValue = 0.6+2*Double.pi; back.duration = Self.turn*1.7; back.repeatCount = .infinity
            counter.add(back, forKey: "spin")
        }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.78; breathe.toValue = 1; breathe.duration = Self.breath
        breathe.autoreverses = true; breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lights.add(breathe, forKey: "breathe")
    }

    private static func colors(_ list: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> [CGColor] {
        list.map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: $0.3).cgColor }
    }

    /// A nine-part mask: opaque at a rounded rectangle's edge, fading to nothing `width` in, whose
    /// middle pixel stretches over the page.
    static func bandImage(width: CGFloat, radius: CGFloat, scale: CGFloat) -> CGImage? {
        let points = 2*width+1
        let size = Int((points*scale).rounded())
        guard size > 0, let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: size*size)
        let half = points/2
        for row in 0..<size {
            for column in 0..<size {
                // How far in from the rounded edge, in points.
                let x = abs((CGFloat(column)+0.5)/scale-half), y = abs((CGFloat(row)+0.5)/scale-half)
                let qx = x-(half-radius), qy = y-(half-radius)
                let outside = hypot(max(qx, 0), max(qy, 0))+min(max(qx, qy), 0)-radius
                let inside = max(0, -outside)
                let t = min(1, inside/width)
                // Strong at the edge, easing away.
                let alpha = pow(1-t, 1.7)*(0.62+0.38*pow(1-t, 5))
                pixels[row*size+column] = UInt8(max(0, min(255, (alpha*255).rounded())))
            }
        }
        return context.makeImage()
    }

    /// Dots 1.4 points across, 5 apart.
    static let dotPattern: NSImage = NSImage(size: NSSize(width: 5, height: 5), flipped: false) { _ in
        NSColor(white: 1, alpha: 0.5).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1.8, y: 1.8, width: 1.4, height: 1.4)).fill()
        return true
    }
}
