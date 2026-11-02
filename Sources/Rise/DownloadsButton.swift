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
    /// Draws the icon in `rect` (y down), with `spin` turns into an unknown download's loop.
    static func draw(in context: CGContext, rect: CGRect, state: State, tint: NSColor, spin: Double = 0) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        let track = state == .idle ? tint : tint.withAlphaComponent(tint.alphaComponent*0.32)
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
            context.setStrokeColor(blue.cgColor)
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
    private var completing = false
    static let glide = 0.22
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setState(_ state: DownloadGlyph.State) {
        if completing, state == .idle { return }
        completing = false
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
        setState(.progress(1))
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, shown < 1 else { setState(.idle); return }
        completing = true; startLink()
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
        let t = min(1, (CACurrentMediaTime()-glideStart)/Self.glide)
        shown = from+(to-from)*(1-pow(1-t, 3))
        needsDisplay = true
        if state != .indeterminate, t >= 1 {
            stopLink()
            if completing { completing = false; state = .idle }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink(); if completing { completing = false; state = .idle } }
        else if state == .indeterminate || from != to { startLink() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shownState: DownloadGlyph.State
        if case .progress = state { shownState = .progress(shown) } else { shownState = state }
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
