import AppKit

/// The floating player's controls. All of them appear only while the pointer
/// is over the video, and stay in the accessibility tree while transparent.
@MainActor final class FloatingVideoOverlay: NSView {
    var closeAction: (() -> Void)?
    var minimizeAction: (() -> Void)?
    var returnAction: (() -> Void)?
    var togglePlayback: (() -> Void)?
    var seek: ((Double, Bool) -> Void)?
    var mouseDrag: ((NSEvent) -> Void)?
    var pinch: ((NSEvent) -> Void)?
    let playButton = PlayPauseButton()
    let progress = FloatingVideoProgressBar()
    private let scrim = FloatingVideoScrim()
    private let closeControl = FloatingVideoControl(glyph: .cross, title: "Close Picture in Picture and pause video")
    private let minimizeControl = FloatingVideoControl(glyph: .dash, title: "Hide Picture in Picture and keep playing")
    private let returnControl = FloatingVideoControl(glyph: .arrows, title: "Return video to its tab")
    private var downPoint: NSPoint?
    private var dragged = false
    private(set) var controlsVisible = false
    private var faded: [NSView] { [scrim, closeControl, minimizeControl, returnControl, playButton, progress] }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        closeControl.action = { [weak self] in self?.closeAction?() }
        minimizeControl.action = { [weak self] in self?.minimizeAction?() }
        returnControl.action = { [weak self] in self?.returnAction?() }
        playButton.action = { [weak self] in self?.toggle() }
        progress.seek = { [weak self] fraction, final in self?.seek?(fraction, final) }
        faded.forEach { $0.alphaValue = 0; addSubview($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityLabel("YouTube Picture in Picture. Drag with two fingers to move; pinch to resize; click video to play or pause.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let side: CGFloat = 30, inset: CGFloat = 10
        scrim.frame = bounds
        closeControl.frame = NSRect(x: inset, y: inset, width: side, height: side)
        minimizeControl.frame = NSRect(x: inset+side+6, y: inset, width: side, height: side)
        returnControl.frame = NSRect(x: bounds.width-inset-side, y: inset, width: side, height: side)
        let play = min(72, max(44, bounds.height*0.3))
        playButton.frame = NSRect(x: (bounds.width-play)/2, y: (bounds.height-play)/2, width: play, height: play)
        // The bar's centerline sits 17pt above the bottom; it thickens around it.
        progress.frame = NSRect(x: 12, y: bounds.height-17-12, width: bounds.width-24, height: 24)
    }
    // The panel never becomes key, so every click is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { if !progress.isScrubbing { setControlsVisible(false) } }
    /// Tracking areas update only when the pointer moves. A window that moved
    /// under a still pointer (a two-finger drag, a flick, a resize) checks again.
    func refreshHover() {
        guard let window, window.isVisible else { setControlsVisible(false); return }
        setControlsVisible(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }
    private func setControlsVisible(_ visible: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : visible ? 0.15 : 0.1
            faded.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }
    }
    /// Shows the new state at once; the page's report confirms or corrects it.
    func toggle() {
        playButton.setPaused(!playButton.paused, animated: true)
        togglePlayback?()
    }
    // A real trackpad pinch reaches the panel as a raw gesture, which AppKit
    // turns into magnify(with:) only for a view that implements it.
    override func magnify(with event: NSEvent) { pinch?(event) }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        if !dragged, hypot(event.locationInWindow.x-downPoint.x, event.locationInWindow.y-downPoint.y) >= 3 {
            dragged = true
            mouseDrag?(NSEvent.mouseEvent(with: .leftMouseDown, location: downPoint, modifierFlags: event.modifierFlags,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) ?? event)
        }
        if dragged { mouseDrag?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { mouseDrag?(event) } else if downPoint != nil { toggle() }
        downPoint = nil; dragged = false
    }
}

/// A rounded-square button on a faint white background, brighter on hover.
/// Each glyph also moves slightly on hover: the arrows spread apart, the dash
/// drops, and the cross's arms lengthen. The motion springs in and returns quickly.
@MainActor final class FloatingVideoControl: NSView {
    enum Glyph { case cross, dash, arrows }
    var action: (() -> Void)?
    private let glyph: Glyph
    private let background = CALayer()
    private var hovering = false { didSet { updateBackground(); updateGlyph() } }
    private var pressed = false { didSet { updateBackground() } }
    /// Symbol pieces and the direction each moves on hover. The arrows are
    /// the symbol split along its diagonal, one arrow per layer; at rest the
    /// pieces draw the whole symbol.
    private var pieces: [(layer: CALayer, direction: CGVector)] = []
    /// The cross is drawn, so its arms can grow without thickening.
    private let strokes = [CAShapeLayer(), CAShapeLayer()]
    private var renderedScale: CGFloat = 0
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    /// Matches the 13pt semibold xmark: ink 10 wide and 10.6 tall, strokes 1.9pt.
    private static let crossArm = CGVector(dx: 4.05, dy: 4.36), crossWidth: CGFloat = 1.9
    init(glyph: Glyph, title: String) {
        self.glyph = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        wantsLayer = true
        background.cornerRadius = 8; background.cornerCurve = .continuous
        layer?.addSublayer(background)
        switch glyph {
        case .cross:
            for stroke in strokes {
                stroke.strokeColor = NSColor.white.cgColor; stroke.fillColor = nil
                stroke.lineWidth = Self.crossWidth; stroke.lineCap = .round
                layer?.addSublayer(stroke)
            }
        case .dash: pieces = [(CALayer(), CGVector(dx: 0, dy: -1))]
        case .arrows:
            // Up-left keeps the triangle above the bottom-left to top-right
            // diagonal; down-right keeps the one below it.
            pieces = [CGVector(dx: -1, dy: 1), CGVector(dx: 1, dy: -1)].map { (CALayer(), $0) }
            pieces.forEach { $0.layer.mask = CAShapeLayer() }
        }
        pieces.forEach { layer?.addSublayer($0.layer) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = title
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var symbol: String { glyph == .dash ? "minus" : "arrow.up.left.and.arrow.down.right" }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        background.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        if !pieces.isEmpty, scale != renderedScale,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
               Self.configuration.applying(.init(paletteColors: [.white]))) {
            renderedScale = scale
            let size = image.size
            for (piece, direction) in pieces {
                piece.contentsScale = scale; piece.contents = image.layerContents(forContentsScale: scale)
                piece.bounds = CGRect(origin: .zero, size: size)
                guard let mask = piece.mask as? CAShapeLayer else { continue }
                let half = CGMutablePath()
                half.addLines(between: direction.dx < 0 ? [.zero, CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
                                                         : [.zero, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height)])
                half.closeSubpath()
                mask.path = half
            }
        }
        pieces.forEach { $0.layer.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        for (index, stroke) in strokes.enumerated() where glyph == .cross {
            stroke.frame = bounds; stroke.removeAnimation(forKey: "hover")
            stroke.path = crossArm(index, extended: hovering && !Self.reduceMotion)
        }
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); renderedScale = 0; needsLayout = true }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// One arm of the cross through the center; on hover each end reaches 1pt further.
    private func crossArm(_ index: Int, extended: Bool) -> CGPath {
        let arm = Self.crossArm, length = hypot(arm.dx, arm.dy)
        let reach = extended ? (length+1)/length : 1
        let dx = arm.dx*reach, dy = (index == 0 ? arm.dy : -arm.dy)*reach
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.midX-dx, y: bounds.midY-dy))
        path.addLine(to: CGPoint(x: bounds.midX+dx, y: bounds.midY+dy))
        return path
    }
    private func updateGlyph() {
        let moved = hovering && !Self.reduceMotion
        for (piece, direction) in pieces {
            let distance: CGFloat = moved ? 1.5 : 0
            let target = CGSize(width: direction.dx*distance, height: direction.dy*distance)
            let current = (piece.presentation()?.value(forKeyPath: "transform.translation") as? NSValue)?.sizeValue ?? .zero
            CATransaction.begin(); CATransaction.setDisableActions(true)
            piece.removeAnimation(forKey: "hover")
            piece.transform = CATransform3DMakeTranslation(target.width, target.height, 0)
            CATransaction.commit()
            animate(piece, "transform.translation", from: NSValue(size: current), to: NSValue(size: target))
        }
        for (index, stroke) in strokes.enumerated() where glyph == .cross {
            let current = stroke.presentation()?.path ?? stroke.path, target = crossArm(index, extended: moved)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            stroke.removeAnimation(forKey: "hover"); stroke.path = target
            CATransaction.commit()
            animate(stroke, "path", from: current, to: target)
        }
    }
    /// Hover springs in with a slight overshoot (ζ 0.6); leaving returns in 0.1s.
    private func animate(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any) {
        guard !Self.reduceMotion, let from else { return }
        let animation: CABasicAnimation
        if hovering {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1; spring.stiffness = 520; spring.damping = 2*0.6*sqrt(520)
            spring.duration = spring.settlingDuration; animation = spring
        } else {
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = 0.1; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        animation.fromValue = from; animation.toValue = to
        layer.add(animation, forKey: "hover")
    }
    private func updateBackground() {
        CATransaction.begin(); CATransaction.setAnimationDuration(pressed ? 0.05 : 0.15)
        background.backgroundColor = NSColor.white.withAlphaComponent(pressed ? 0.38 : hovering ? 0.27 : 0.17).cgColor
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action?() }
    }
    // AppKit turns a trackpad pinch into magnify(with:) only for a view that
    // implements it; the overlay resizes the window.
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

/// Darkens the top and bottom edges behind the controls, so they stay legible
/// over a bright picture, while the middle of the video stays nearly clear.
@MainActor final class FloatingVideoScrim: NSView {
    private let gradient = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let edge = NSColor.black.withAlphaComponent(0.52).cgColor, middle = NSColor.black.withAlphaComponent(0.17).cgColor
        gradient.colors = [edge, middle, middle, edge]; gradient.locations = [0, 0.38, 0.62, 1]
        layer?.addSublayer(gradient)
    }
    required init?(coder: NSCoder) { fatalError() }
    // Clicks and pinches over it belong to the overlay.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); gradient.frame = bounds; CATransaction.commit()
    }
}

/// A capsule track that thickens on hover equally above and below its
/// centerline. The fill spans the track and is scaled horizontally, so
/// position updates never interrupt the thickness animation.
@MainActor final class FloatingVideoProgressBar: NSView {
    var seek: ((Double, Bool) -> Void)?
    private(set) var fraction: Double = 0
    private(set) var isScrubbing = false
    private var seekTarget: (fraction: Double, until: CFTimeInterval)?
    private let track = CALayer()
    private let fill = CALayer()
    private var hovering = false
    private var thickness: CGFloat { hovering || isScrubbing ? 9 : 5 }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        fill.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(track); track.addSublayer(fill); track.masksToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.slider); setAccessibilityLabel("Playback position")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); applyGeometry(animated: false) }
    private func applyGeometry(animated: Bool) {
        let size = CGSize(width: bounds.width, height: thickness)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1))
        } else { CATransaction.setDisableActions(true) }
        track.bounds = CGRect(origin: .zero, size: size); track.position = CGPoint(x: bounds.midX, y: bounds.midY)
        track.cornerRadius = size.height/2
        fill.bounds = CGRect(origin: .zero, size: size); fill.position = CGPoint(x: 0, y: size.height/2)
        CATransaction.commit()
        updateFill()
    }
    private func setHovering(_ hovering: Bool) {
        let before = thickness; self.hovering = hovering
        if thickness != before { applyGeometry(animated: true) }
    }
    private func setScrubbing(_ scrubbing: Bool) {
        let before = thickness; isScrubbing = scrubbing
        if thickness != before { applyGeometry(animated: true) }
    }
    private func updateFill() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.transform = CATransform3DMakeScale(CGFloat(fraction), 1, 1)
        CATransaction.commit()
    }
    /// The page's position. Ignored while scrubbing, and briefly after a seek
    /// until the page reaches it, so the fill never jumps back.
    func show(time: Double, duration: Double) {
        guard duration.isFinite, duration > 0, time.isFinite else { isHidden = true; return }
        isHidden = false
        let reported = min(1, max(0, time/duration))
        if isScrubbing { return }
        if let target = seekTarget {
            if abs(reported-target.fraction)*duration > 1.5, CACurrentMediaTime() < target.until { return }
            seekTarget = nil
        }
        fraction = reported; updateFill()
        setAccessibilityValue(Self.timestamp(time))
    }
    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total/3600, total/60%60, total%60) : String(format: "%d:%02d", total/60, total%60)
    }
    private func scrub(to event: NSEvent, final: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        fraction = min(1, max(0, Double(x/max(1, bounds.width)))); updateFill()
        seek?(fraction, final)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func magnify(with event: NSEvent) { superview?.magnify(with: event) }
    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseDown(with event: NSEvent) { setScrubbing(true); scrub(to: event, final: false) }
    override func mouseDragged(with event: NSEvent) { scrub(to: event, final: false) }
    override func mouseUp(with event: NSEvent) {
        scrub(to: event, final: true)
        setScrubbing(false)
        seekTarget = (fraction, CACurrentMediaTime()+1.5)
        (superview as? FloatingVideoOverlay)?.refreshHover()
    }
    override func accessibilityPerformIncrement() -> Bool { step(0.05) }
    override func accessibilityPerformDecrement() -> Bool { step(-0.05) }
    private func step(_ delta: Double) -> Bool {
        fraction = min(1, max(0, fraction+delta)); updateFill()
        seekTarget = (fraction, CACurrentMediaTime()+1.5); seek?(fraction, true); return true
    }
}
