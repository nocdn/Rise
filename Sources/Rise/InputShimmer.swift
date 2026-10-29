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
    /// Starting, the text eases down to the muted color just as quickly, rather than jumping.
    static let fade = 0.2
    /// How wide the bright band is, and how much of it, around its middle, is at full strength.
    var bandWidth: CGFloat = InputShimmer.band
    var plateau: CGFloat = 0
    /// Eases from the clear edges into the bright middle along a smoothstep curve, rather than
    /// a straight ramp.
    var softEdges = false
    /// How long one sweep takes.
    var sweep: TimeInterval = InputShimmer.period
    weak var field: NSTextField?
    var baseColor = NSColor.secondaryLabelColor { didSet { if isRunning && restoring == nil && fadingIn == nil { field?.textColor = baseColor } } }
    var bandColor = NSColor.labelColor { didSet { needsDisplay = true } }
    private(set) var isRunning = false
    private var started: CFTimeInterval = 0, stopAt: CFTimeInterval?, restoring: CFTimeInterval?
    /// Easing down to the muted color since then, from the color the text showed.
    private var fadingIn: CFTimeInterval?, fadeFrom: NSColor?
    /// How far the band is through its sweep; set directly only by tests.
    var progress: CGFloat = 0
    private var link: CADisplayLink?
    private var fieldColor: NSColor?
    private var smartRenameFinish: DispatchWorkItem?

    /// Shared by tab and download titles, including the smooth entrance and exit.
    func configureForSmartRename(field: NSTextField) {
        self.field = field; autoresizingMask = [.width, .height]
        bandWidth = 80; plateau = 0.3; softEdges = true; sweep = 0.7
        field.addSubview(self)
    }
    func startSmartRename() {
        smartRenameFinish?.cancel()
        frame = field?.bounds ?? .zero
        start()
        guard isRunning else { return }
        // Four sweeps (~2.8 s), followed by the existing smooth color restore.
        let finish = DispatchWorkItem { [weak self] in self?.finish(); self?.smartRenameFinish = nil }
        smartRenameFinish = finish
        DispatchQueue.main.asyncAfter(deadline: .now()+3*sweep+0.05, execute: finish)
    }

    // Hidden until it runs, so it never draws over the field's own colors (such as no-match red).
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); isHidden = true; clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start() {
        guard let field, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = CACurrentMediaTime()
        // From whatever the text shows now: its own color, or part way back to it.
        if !isRunning { fieldColor = field.textColor; fadeFrom = fieldColor; fadingIn = now }
        else if let restoring { fadeFrom = blend(from: baseColor, to: fieldColor ?? .labelColor, ease(min(1, (now-restoring)/Self.restore))); fadingIn = now }
        isRunning = true; stopAt = nil; restoring = nil; started = now; progress = 0
        isHidden = false; needsDisplay = true
        keepOnTop()
        // Driven by the field's link, which keeps firing once this view hides for the ease back.
        if link == nil { let link = field.displayLink(target: self, selector: #selector(tick(_:))); link.add(to: .main, forMode: .common); self.link = link }
    }
    /// Stops at the end of the current sweep, never mid-text.
    func finish() {
        guard isRunning, stopAt == nil else { return }
        stopAt = started + (floor((CACurrentMediaTime()-started)/sweep)+1)*sweep
    }
    func cancel() {
        guard isRunning else { return }
        end()
    }
    /// The field's own color changed while the shimmer runs: it eases back to this one instead.
    func setRestingColor(_ color: NSColor) {
        fieldColor = color
        if isRunning, restoring == nil, fadingIn == nil { field?.textColor = baseColor }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let restoring {
            let t = min(1, (now-restoring)/Self.restore)
            if t >= 1 { end(); return }
            setColor(blend(from: baseColor, to: fieldColor ?? .labelColor, ease(t)))
            return
        }
        if let fadingIn {
            let t = min(1, (now-fadingIn)/Self.fade)
            if t >= 1 { self.fadingIn = nil; settleMuted() } else { setColor(blend(from: fadeFrom ?? baseColor, to: baseColor, ease(t))) }
        }
        // Nothing of the band is left to draw; an empty overlay left in front blanked the field.
        if let stopAt, now >= stopAt { progress = 1; isHidden = true; restoring = now; return }
        // steps(30, end): the band jumps in 30 even steps per sweep and never shows the final position.
        let cycle = (now-started).truncatingRemainder(dividingBy: sweep)/sweep
        let stepped = CGFloat(floor(cycle*Self.steps)/Self.steps)
        if stepped != progress { progress = stepped; needsDisplay = true; keepOnTop() }
    }
    /// Inside a field (a tab's title), AppKit draws the text in a label of its own, added after
    /// this view, which would cover the band with the muted text.
    private func keepOnTop() {
        guard let superview, superview.subviews.last !== self else { return }
        superview.addSubview(self, positioned: .above, relativeTo: nil)
    }
    private func ease(_ t: Double) -> CGFloat { CGFloat(1-pow(1-t, 3)) }
    /// Part of the way from one color to another, resolved in the field's appearance since
    /// the field's color is usually a dynamic system color.
    private func blend(from start: NSColor, to end: NSColor, _ fraction: CGFloat) -> NSColor {
        guard let field else { return end }
        var color = end
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            let target = end.usingColorSpace(.sRGB) ?? end
            color = (start.usingColorSpace(.sRGB) ?? start).blended(withFraction: fraction, of: target) ?? target
        }
        return color
    }
    /// Done easing down: the field itself takes the muted color, so text typed meanwhile is muted too.
    private func settleMuted() {
        guard let field else { return }
        if let editor = field.currentEditor() as? NSTextView, let manager = editor.layoutManager {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        field.textColor = baseColor
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
        smartRenameFinish?.cancel(); smartRenameFinish = nil
        link?.invalidate(); link = nil; isRunning = false; stopAt = nil; restoring = nil; fadingIn = nil
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
        let origin = baseline(of: field, font: font, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        // A long question runs past the field; only its visible part shimmers, so the band
        // never draws over the badge beside the field.
        let visible = convert(field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds, from: field)
        let start = max(origin.x, visible.minX)
        let width = max(0, min(origin.x+CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), visible.maxX)-start)
        context.saveGState()
        context.clip(to: CGRect(x: visible.minX, y: bounds.minY, width: visible.width, height: bounds.height))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // The text in the bright color, kept only under the moving gradient. (CTLineDraw ignores
        // clip text drawing modes, so the gradient masks a transparency layer instead.)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(bandColor.cgColor); context.textPosition = origin; CTLineDraw(line, context)
        context.setBlendMode(.destinationIn)
        let x = start-bandWidth+progress*(width+bandWidth)
        let core = min(1, max(0, plateau))/2
        // Strengths across the band: up from clear, the bright middle, and back down.
        let rise: [(at: CGFloat, alpha: CGFloat)] = softEdges
            ? (0...8).map { i in let u = CGFloat(i)/8; return (u*(0.5-core), u*u*(3-2*u)) }
            : [(0, 0), (0.5-core, 1)]
        let stops = rise + rise.reversed().map { (1-$0.at, $0.alpha) }
        let colors = stops.map { NSColor.black.withAlphaComponent($0.alpha).cgColor } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: stops.map(\.at)) {
            // Extended past both ends so the clear edges also erase the text outside the band.
            context.drawLinearGradient(gradient, start: CGPoint(x: x, y: 0), end: CGPoint(x: x+bandWidth, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
    /// Where the field editor puts the first glyph's baseline, following its horizontal scroll.
    /// `width` is the text's, which a centred or right-aligned field moves in from the left.
    func baseline(of field: NSTextField, font: NSFont, width: CGFloat) -> CGPoint {
        if let editor = field.currentEditor() as? NSTextView, let manager = editor.layoutManager, manager.numberOfGlyphs > 0 {
            let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil), glyph = manager.location(forGlyphAt: 0)
            let point = NSPoint(x: editor.textContainerOrigin.x+fragment.minX+glyph.x, y: editor.textContainerOrigin.y+fragment.minY+glyph.y)
            return convert(point, from: editor)
        }
        // Unfocused (as after sending), the cell draws the text where the editor would: its line's
        // baseline offset below the title rect's top, past the 2 pt line fragment padding.
        let title = convert(field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds, from: field)
        let room = title.width-4, rightToLeft = field.userInterfaceLayoutDirection == .rightToLeft
        let inset: CGFloat = switch field.alignment {
        case .center: max(0, (room-width)/2)
        case .right: max(0, room-width)
        case .natural where rightToLeft: max(0, room-width)
        default: 0
        }
        return CGPoint(x: title.minX+2+inset, y: title.minY+NSLayoutManager().defaultBaselineOffset(for: font))
    }
}
