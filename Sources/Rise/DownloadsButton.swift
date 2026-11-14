import AppKit
import QuartzCore

/// The downloads icon: Material Line Icons' download-loop (MIT, Vjacheslav Trushkin), a
/// down arrow in a circle, with the circle drawn whole and still. While downloads run, the
/// part of the circle they've completed turns blue and the rest goes a lighter grey, as
/// the iOS app's rings do. Geometry is in the icon's 24-unit space, y down, drawn 20 pt
/// wide in the middle of a 28 pt button.
enum DownloadGlyph {
    enum State: Equatable { case idle, progress(Double), indeterminate }
    static let unit: CGFloat = 20.0/24
    static let lineWidth = 2*unit
    static let radius = 9*unit
    static let blue = NSColor(displayP3Red: 63/255, green: 141/255, blue: 247/255, alpha: 1)
    /// An unknown size turns a quarter of the ring once every 1.1 seconds.
    static let spinPeriod = 1.1, unknownLength = 0.25

    static func arrow(center c: CGPoint) -> CGPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x+(x-12)*unit, y: c.y+(y-12)*unit) }
        let path = CGMutablePath()
        path.move(to: point(12, 8)); path.addLine(to: point(12, 15.5))
        path.move(to: point(8.5, 12)); path.addLine(to: point(12, 15.5)); path.addLine(to: point(15.5, 12))
        return path
    }
    /// From `start` turns past the top, clockwise for `length` of the way round, y down.
    static func arc(center c: CGPoint, start: Double = 0, length: Double) -> CGPath {
        let path = CGMutablePath(), from = -Double.pi/2+start*2 * .pi
        path.addArc(center: c, radius: radius, startAngle: from, endAngle: from+length*2 * .pi, clockwise: false)
        return path
    }
    /// The track's opacity while downloads run, of the tint's.
    static let faintTrack = 0.32
    /// Draws the icon in `rect` (y down), with `spin` turns into an unknown download's loop.
    /// `faint` is how far the track has gone from the tint to its faint grey (by default, all
    /// the way unless idle), and `closing` how far a full ring has turned from blue to the tint.
    static func draw(in context: CGContext, rect: CGRect, state: State, tint: NSColor, spin: Double = 0,
                     faint: Double? = nil, closing: Double = 0) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        let faintness = faint ?? (state == .idle ? 0 : 1)
        let track = tint.withAlphaComponent(tint.alphaComponent*(1-(1-faintTrack)*faintness))
        context.setStrokeColor(track.cgColor)
        context.addEllipse(in: CGRect(x: center.x-radius, y: center.y-radius, width: 2*radius, height: 2*radius))
        context.strokePath()
        let done: (start: Double, length: Double)?
        switch state {
        case .idle: done = nil
        case .progress(let fraction): done = fraction > 0 ? (0, min(1, fraction)) : nil
        case .indeterminate: done = (spin, unknownLength)
        }
        if let done {
            let ring = closing > 0 ? (blue.usingColorSpace(.sRGB)?.blended(withFraction: closing, of: tint.usingColorSpace(.sRGB) ?? tint) ?? tint) : blue
            context.setStrokeColor(ring.cgColor)
            context.addPath(arc(center: center, start: done.start, length: done.length)); context.strokePath()
        }
        context.setStrokeColor(tint.cgColor)
        context.addPath(arrow(center: center)); context.strokePath()
    }
    /// The icon as a picture, for the stand-in a download lands on.
    static func image(state: State, tint: NSColor, spin: Double = 0, size: CGFloat = 28) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect, state: state, tint: tint, spin: spin); return true
        }
    }
}

/// Draws ``DownloadGlyph``. A flipped view's drawing is always y-down, unlike hand-made
/// sublayers, whose orientation AppKit may change after the window appears.
final class DownloadGlyphView: FlippedView {
    var tint = NSColor(hex: 0x7D7B7B) { didSet { needsDisplay = true } }
    private(set) var state = DownloadGlyph.State.idle
    /// The fraction shown, which glides to each new one rather than jumping.
    private var shown = 0.0, from = 0.0, to = 0.0, glideStart: CFTimeInterval = 0
    private var spinStart = CACurrentMediaTime()
    private var link: CADisplayLink?
    /// A finished download's closing, under way: from when, and from the track's faintness and
    /// the fraction shown as it began.
    private var closing: (start: CFTimeInterval, faint: Double, shown: Double)?
    /// Finished while hidden under a download's flight: closes once it shows again.
    private var closesWhenShown = false
    private var completing: Bool { closing != nil || closesWhenShown }
    static let glide = 0.22
    /// However quickly a download finishes, the icon closes its ring in these steps, 0.7 s at
    /// most: the track fades to its faint grey (unless it's there already), the blue goes the
    /// rest of the way round (a whole turn taking `closeFill`), and the full ring turns from
    /// blue back to the icon's grey.
    static let closeFade = 0.12, closeFill = 0.38, closeBlend = 0.2
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setState(_ state: DownloadGlyph.State) {
        if completing, state == .idle { return }
        closing = nil; closesWhenShown = false
        guard state != self.state else { return }
        let animated = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if case .progress(let fraction) = state {
            if animated {
                if self.state == .idle { shown = 0 }
                else if self.state == .indeterminate { shown = DownloadGlyph.unknownLength }
                from = shown; to = fraction; glideStart = CACurrentMediaTime()
            } else { shown = fraction; from = fraction; to = fraction }
        }
        if state == .indeterminate, self.state != .indeterminate { spinStart = CACurrentMediaTime() }
        self.state = state
        needsDisplay = true
        if animated && (state == .indeterminate || from != to) { startLink() } else { stopLink() }
    }
    /// Even a transfer which finishes before the first display frame fills
    /// smoothly before returning to the idle icon. A new transfer can take over.
    func complete() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { setState(.idle); return }
        if isHidden { closesWhenShown = true; return }
        beginClosing()
    }
    private func beginClosing() {
        let faint: Double, from: Double
        switch state {
        case .idle: faint = 0; from = 0
        case .progress: faint = 1; from = shown
        case .indeterminate: faint = 1; from = DownloadGlyph.unknownLength
        }
        closesWhenShown = false
        closing = (CACurrentMediaTime(), faint, min(1, max(0, from)))
        state = .progress(1); shown = closing!.shown
        needsDisplay = true
        startLink()
    }
    override var isHidden: Bool {
        didSet { if !isHidden, closesWhenShown { beginClosing() } }
    }
    /// Where a closing is at `now`: the track's faintness, the fraction shown, how far the ring
    /// has turned grey, and whether it's over.
    private func closingPose(at now: CFTimeInterval) -> (faint: Double, shown: Double, blend: Double, over: Bool)? {
        guard let closing else { return nil }
        let elapsed = now-closing.start
        let fade = closing.faint < 1 ? Self.closeFade*(1-closing.faint) : 0
        let fill = Self.closeFill*(1-closing.shown)
        func progress(_ from: Double, _ duration: Double) -> Double { duration > 0 ? min(1, max(0, (elapsed-from)/duration)) : (elapsed >= from ? 1 : 0) }
        let easeOut = { (t: Double) in 1-pow(1-t, 3) }
        let easeInOut = { (t: Double) in t < 0.5 ? 4*t*t*t : 1-pow(-2*t+2, 3)/2 }
        let faint = closing.faint+(1-closing.faint)*easeOut(progress(0, fade))
        let shown = closing.shown+(1-closing.shown)*easeInOut(progress(fade, fill))
        let blend = easeInOut(progress(fade+fill, Self.closeBlend))
        return (faint, shown, blend, elapsed >= fade+fill+Self.closeBlend)
    }
    /// What it shows now, for a stand-in to copy.
    var displayed: (state: DownloadGlyph.State, spin: Double) {
        if case .progress = state { return (.progress(shown), 0) }
        return (state, spin)
    }
    private var spin: Double { (CACurrentMediaTime()-spinStart)/DownloadGlyph.spinPeriod }
    private func startLink() {
        guard link == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick)); link.add(to: .main, forMode: .common); self.link = link
    }
    private func stopLink() { link?.invalidate(); link = nil }
    @objc private func tick() {
        if let pose = closingPose(at: CACurrentMediaTime()) {
            shown = pose.shown
            needsDisplay = true
            if pose.over { closing = nil; state = .idle; stopLink() }
            return
        }
        let t = min(1, (CACurrentMediaTime()-glideStart)/Self.glide)
        shown = from+(to-from)*(1-pow(1-t, 3))
        needsDisplay = true
        if state != .indeterminate, t >= 1 { stopLink() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink(); if completing { closing = nil; closesWhenShown = false; state = .idle } }
        else if state == .indeterminate || from != to { startLink() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shownState: DownloadGlyph.State
        if case .progress = state { shownState = .progress(shown) } else { shownState = state }
        if let pose = closingPose(at: CACurrentMediaTime()) {
            DownloadGlyph.draw(in: context, rect: bounds, state: .progress(pose.shown), tint: tint, faint: pose.faint, closing: pose.blend)
            return
        }
        DownloadGlyph.draw(in: context, rect: bounds, state: shownState, tint: tint, spin: spin)
    }
}

/// The sidebar's downloads button, drawn from ``DownloadGlyph`` with the downloads' progress.
final class DownloadsButton: ChromeButton {
    let glyph = DownloadGlyphView()
    /// Hidden while a download flight draws a stand-in that the download lands on.
    var isGlyphHidden: Bool {
        get { glyph.isHidden }
        set { glyph.isHidden = newValue }
    }
    override var contentTintColor: NSColor? {
        didSet { glyph.tint = contentTintColor ?? NSColor(hex: 0x7D7B7B) }
    }
    init(title: String, action: @escaping () -> Void) {
        super.init(symbol: "arrow.down.circle", size: 15, title: title, action: action)
        setHoverHint("Downloads", shortcut: "⌥⌘L")
        image = nil; self.title = ""
        addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    var secondaryAction: (() -> Void)?
    override func layout() { super.layout(); glyph.frame = bounds }
    override func rightMouseDown(with event: NSEvent) {
        hoverHint?.hide()
        if let secondaryAction { secondaryAction() } else { super.rightMouseDown(with: event) }
    }
}
