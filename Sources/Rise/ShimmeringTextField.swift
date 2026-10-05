import AppKit
import QuartzCore

/// AppKit translation of ElevenLabs' MIT-licensed shimmering-text component:
/// 250% background width; transparent / foreground / transparent stops at
/// 50% ± (UTF-16 text length * 2) px; linear movement from 100% to 0%.
/// https://github.com/elevenlabs/ui/blob/main/apps/www/registry/elevenlabs-ui/ui/shimmering-text.tsx
final class ShimmeringTextField: NSTextField {
    static let duration = 0.65 // React default: 2 seconds.
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    var isShimmering: Bool { timer != nil }
    var shimmerColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        cell?.usesSingleLineMode = true; lineBreakMode = .byTruncatingTail
        wantsLayer = true; clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func startShimmer() {
        stopShimmer()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if CACurrentMediaTime() - self.started >= Self.duration { self.stopShimmer() }
            else { self.needsDisplay = true }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }
    func stopShimmer() {
        timer?.invalidate(); timer = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { super.draw(dirtyRect); return }
        context.saveGState()
        // Always use the same native cell and compositing path. Switching to a
        // separately rasterized white mask changed the font's antialiased edges.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        super.draw(dirtyRect)
        if isShimmering, bounds.width > 0 {
            let elapsed = CACurrentMediaTime() - started
            let fraction = min(1, max(0, elapsed / Self.duration))
            let width = bounds.width * 2.5
            let spread = CGFloat((stringValue as NSString).length) * 2
            let fade = min(1, max(0, elapsed / 0.15))
            let color = shimmerColor.withAlphaComponent(shimmerColor.alphaComponent * fade)
            let colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
            let stops: [CGFloat] = [max(0, 0.5 - spread / width), 0.5, min(1, 0.5 + spread / width)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: stops) {
                let offset = -1.5 * bounds.width * (1 - fraction)
                // Color the existing glyph pixels without changing their alpha
                // coverage: the shimmer cannot expand or thicken the strokes.
                context.setBlendMode(.sourceAtop)
                context.drawLinearGradient(gradient, start: CGPoint(x: offset, y: 0),
                    end: CGPoint(x: offset + width, y: 0), options: [])
            }
        }
        context.endTransparencyLayer(); context.restoreGState()
    }
}
