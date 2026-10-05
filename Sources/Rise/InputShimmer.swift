import AppKit
import CoreText

/// T3 Code's `live-tool-shine` (the shine on "Running python3" while a tool runs), drawn over
/// a text field's own text:
///
///     color: transparent; -webkit-background-clip: text;
///     background-image: linear-gradient(to right, transparent, var(--contrast-foreground), transparent),
///                       linear-gradient(var(--contrast-secondary-label), var(--contrast-secondary-label));
///     background-size: 4.5rem 100%, 100% 100%;
///     animation: 2.2s steps(30, end) infinite live-tool-shine;  /* -4.5rem 0 → calc(100% + 4.5rem) 0 */
///
/// The field keeps drawing its own text, muted, while this draws only the bright band over it
/// at the field editor's baseline, so caret, selection and scrolling stay native. Finishing
/// lets the band run off the end of the text, then eases the field's own color back. (Drawing
/// the whole line here and handing it back at the end flashed: AppKit renders the field's
/// glyphs a touch heavier than a separate copy can, so the swap showed as a jump in weight.)
@MainActor final class InputShimmer: FlippedView {
    /// T3's sweep is 2.2 s; Rise runs it 2.2× faster so a short answer still shows it moving.
    static let band: CGFloat = 72, period = 1.0, steps = 30.0
    /// After the last sweep the muted text eases up to the field's own color.
    static let restore = 0.35
    weak var field: NSTextField?
    var baseColor = NSColor.secondaryLabelColor { didSet { if isRunning && restoring == nil { field?.textColor = baseColor } } }
    var bandColor = NSColor.labelColor { didSet { needsDisplay = true } }
    private(set) var isRunning = false
    private var started: CFTimeInterval = 0, stopAt: CFTimeInterval?, restoring: CFTimeInterval?
    private var progress: CGFloat = 0
    private var link: CADisplayLink?
    private var fieldColor: NSColor?

    // Hidden until it runs, so it never draws over the field's own colors (such as no-match red).
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); isHidden = true }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start() {
        guard let field, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if !isRunning { fieldColor = field.textColor }
        field.textColor = baseColor
        isRunning = true; stopAt = nil; restoring = nil; started = CACurrentMediaTime(); progress = 0
        isHidden = false; needsDisplay = true
        // Driven by the field's link, which keeps firing once this view hides for the ease back.
        if link == nil { let link = field.displayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common); self.link = link }
    }
    /// Stops at the end of the current sweep, never mid-text.
    func finish() {
        guard isRunning, stopAt == nil else { return }
        stopAt = started + (floor((CACurrentMediaTime()-started)/Self.period)+1)*Self.period
    }
    func cancel() {
        guard isRunning else { return }
        end()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let restoring {
            let t = min(1, (now-restoring)/Self.restore)
            if t >= 1 { end(); return }
            setColor(restoredColor(CGFloat(1-pow(1-t, 3))))
            return
        }
        // Nothing of the band is left to draw; an empty overlay left in front blanked the field.
        if let stopAt, now >= stopAt { progress = 1; isHidden = true; restoring = now; return }
        // steps(30, end): the band jumps in 30 even steps per sweep and never shows the final position.
        let cycle = (now-started).truncatingRemainder(dividingBy: Self.period)/Self.period
        let stepped = CGFloat(floor(cycle*Self.steps)/Self.steps)
        if stepped != progress { progress = stepped; needsDisplay = true }
    }
    /// The muted color part of the way back to the field's own, resolved in the field's
    /// appearance since the field's color is usually a dynamic system color.
    private func restoredColor(_ fraction: CGFloat) -> NSColor {
        guard let field else { return baseColor }
        var color = baseColor
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            let target = (self.fieldColor ?? .labelColor).usingColorSpace(.sRGB) ?? .labelColor
            color = (self.baseColor.usingColorSpace(.sRGB) ?? self.baseColor).blended(withFraction: fraction, of: target) ?? target
        }
        return color
    }
    /// Recolors the text being edited as a temporary attribute, which only redraws. Setting the
    /// field's or editor's `textColor` every frame restyled the text storage each time, and the
    /// field showed blank (selection and all) until the changes stopped.
    private func setColor(_ color: NSColor) {
        guard let field else { return }
        if let editor = field.currentEditor() as? NSTextView, let manager = editor.layoutManager {
            manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        } else { field.textColor = color }
    }
    private func end() {
        link?.invalidate(); link = nil; isRunning = false; stopAt = nil; restoring = nil
        field?.textColor = fieldColor ?? .labelColor
        if let editor = field?.currentEditor() as? NSTextView, let manager = editor.layoutManager {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isRunning, progress < 1, let field, let font = field.font, !field.stringValue.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: field.stringValue, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let origin = baseline(of: field, font: font)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // The text in the bright color, kept only under the moving gradient. (CTLineDraw ignores
        // clip text drawing modes, so the gradient masks a transparency layer instead.)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(bandColor.cgColor); context.textPosition = origin; CTLineDraw(line, context)
        context.setBlendMode(.destinationIn)
        let x = origin.x-Self.band+progress*(width+Self.band)
        let colors = [NSColor.black.withAlphaComponent(0), .black, NSColor.black.withAlphaComponent(0)].map(\.cgColor) as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1]) {
            // Extended past both ends so the clear edges also erase the text outside the band.
            context.drawLinearGradient(gradient, start: CGPoint(x: x, y: 0), end: CGPoint(x: x+Self.band, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
    /// Where the field editor puts the first glyph's baseline, following its horizontal scroll.
    private func baseline(of field: NSTextField, font: NSFont) -> CGPoint {
        if let editor = field.currentEditor() as? NSTextView, let manager = editor.layoutManager, manager.numberOfGlyphs > 0 {
            let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil), glyph = manager.location(forGlyphAt: 0)
            let point = NSPoint(x: editor.textContainerOrigin.x+fragment.minX+glyph.x, y: editor.textContainerOrigin.y+fragment.minY+glyph.y)
            return convert(point, from: editor)
        }
        // Unfocused (as after sending), the cell draws the text where the editor would: its line's
        // baseline offset below the title rect's top, past the 2 pt line fragment padding.
        let title = convert(field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds, from: field)
        return CGPoint(x: title.minX+2, y: title.minY+NSLayoutManager().defaultBaselineOffset(for: font))
    }
}
