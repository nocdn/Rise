import AppKit

/// A round button beside the Peek card. The cross and arrows are Picture in Picture's: the
/// drawn ✕, and the diagonal arrows that spread apart on hover. The split's divider sways
/// left and right once on hover. The button shrinks slightly while pressed, and it can sit
/// tucked behind the card's right edge, then slide out from under it.
@MainActor final class PeekControl: NSView {
    enum Glyph: CaseIterable {
        case cross, arrows, split

        var symbol: String {
            switch self {
            case .cross: "xmark"
            case .arrows: "arrow.up.left.and.arrow.down.right"
            case .split: "rectangle.split.2x1"
            }
        }

        var title: String {
            switch self {
            case .cross: "Close Peek"
            case .arrows: "Expand Peek to tab"
            case .split: "Open Peek in split view"
            }
        }
    }
    static let side: CGFloat = 34, gap: CGFloat = 12
    /// Room around the button for its shadow; the view clips at the card's edge.
    static let shadowRoom: CGFloat = 6
    static let pressedScale: CGFloat = 0.9
    /// How far past the button its shadow can show.
    static let shadowReach: CGFloat = 8
    /// Tucked this far left, the button and its shadow sit wholly past the card's edge.
    static let tuckedOffset: CGFloat = -(gap+side+shadowReach+4)
    /// Going back in is quicker than coming out, and doesn't overshoot.
    static let tuckDuration: TimeInterval = 0.1
    /// The sidebar's slide: quick, with a few points of overshoot as it lands.
    static var slideSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.185, bounce: 0.2) }
    static let tint = NSColor(hex: 0xE87088)

    var action: (() -> Void)?
    let glyph: Glyph
    /// Slides; the view itself is left free for the Peek swipe's transform.
    private let body = CALayer()
    /// Shrinks while pressed.
    private let face = CALayer()
    private let fill = CALayer()
    private let wash = CALayer()
    private let strokes: [CAShapeLayer]
    private var pieces: [(layer: CALayer, direction: CGVector)] = []
    private var renderedScale: CGFloat = 0
    private var washColor = NSColor.black
    private(set) var hovering = false { didSet { if hovering != oldValue { updateWash(); updateGlyph(); watchCommand() } } }
    /// Over the arrows with ⌘ held, a small plus at their top right: the Peek opens in a new tab.
    private let plus = CALayer()
    private(set) var showsPlus = false { didSet { if showsPlus != oldValue { updatePlus() } } }
    private var commandMonitor: Any?
    static let plusScale: CGFloat = 0.7, plusDuration: TimeInterval = 0.12
    private(set) var pressed = false {
        didSet {
            guard pressed != oldValue else { return }
            updateWash(); PressScale.set(face, to: pressed ? Self.pressedScale : 1)
        }
    }
    /// The glyphs are drawn for Picture in Picture's 30 pt button and scale with this one.
    private var glyphScale: CGFloat { Self.side/30 }

    init(glyph: Glyph, title: String) {
        self.glyph = glyph
        strokes = glyph == .arrows ? [] : [CAShapeLayer(), CAShapeLayer()]
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true; clipsToBounds = true
        layer?.addSublayer(body); body.addSublayer(face)
        for circle in [fill, wash] { circle.cornerRadius = Self.side/2; face.addSublayer(circle) }
        fill.shadowColor = NSColor.black.cgColor; fill.shadowOpacity = 0.12; fill.shadowRadius = 3
        fill.shadowOffset = CGSize(width: 0, height: -1)
        for stroke in strokes {
            stroke.strokeColor = Self.tint.cgColor; stroke.fillColor = nil
            stroke.lineCap = glyph == .cross ? .round : .butt
            face.addSublayer(stroke)
        }
        if glyph == .arrows {
            // Up-left keeps the triangle above the bottom-left to top-right diagonal; down-right the one below.
            pieces = [CGVector(dx: -1, dy: 1), CGVector(dx: 1, dy: -1)].map { (CALayer(), $0) }
            pieces.forEach { $0.layer.mask = CAShapeLayer(); face.addSublayer($0.layer) }
            plus.opacity = 0; plus.transform = CATransform3DMakeScale(Self.plusScale, Self.plusScale, 1)
            face.addSublayer(plus)
        }
        toolTip = title
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        updateWash()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Where the button itself sits in this view; the rest is room for the shadow and the slide.
    var buttonRect: NSRect { NSRect(x: Self.gap, y: Self.shadowRoom, width: Self.side, height: Self.side) }
    /// The view's frame for a button whose top sits at `top`, beside a card ending at `cardMaxX`.
    static func frame(cardMaxX: CGFloat, top: CGFloat) -> NSRect {
        NSRect(x: cardMaxX, y: top-shadowRoom, width: gap+side+shadowRoom, height: side+2*shadowRoom)
    }

    func applyTheme(_ theme: RiseTheme) {
        washColor = theme.text
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = theme.popup.cgColor
        CATransaction.commit()
        updateWash()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let rect = buttonRect, k = glyphScale
        // Bounds and position, not frame: the slide's transform must not shift where the button rests.
        // The view isn't flipped, so its layer shares its coordinates.
        body.bounds = CGRect(origin: .zero, size: rect.size); body.position = CGPoint(x: rect.midX, y: rect.midY)
        face.bounds = CGRect(origin: .zero, size: rect.size); face.position = CGPoint(x: rect.width/2, y: rect.height/2)
        fill.frame = face.bounds; wash.frame = face.bounds
        fill.shadowPath = CGPath(ellipseIn: fill.bounds, transform: nil)
        let center = CGPoint(x: rect.width/2, y: rect.height/2)
        switch glyph {
        case .cross:
            // Picture in Picture's 13 pt semibold ✕: ink 10 wide and 10.6 tall, strokes 1.9 pt.
            for (index, stroke) in strokes.enumerated() {
                let dx = 4.05*k, dy = (index == 0 ? 1 : -1)*4.36*k
                let path = CGMutablePath()
                path.move(to: CGPoint(x: center.x-dx, y: center.y-dy)); path.addLine(to: CGPoint(x: center.x+dx, y: center.y+dy))
                stroke.frame = face.bounds; stroke.lineWidth = 1.9*k; stroke.path = path
            }
        case .split:
            // SF Symbols' rectangle.split.2x1 at the same size: ink 15 by 12, strokes about 1.6 pt.
            let width = 15*k, height = 12*k, line = 1.6*k
            let outline = CGRect(x: center.x-width/2+line/2, y: center.y-height/2+line/2, width: width-line, height: height-line)
            strokes[0].frame = face.bounds; strokes[0].lineWidth = line
            strokes[0].path = CGPath(roundedRect: outline, cornerWidth: 3*k, cornerHeight: 3*k, transform: nil)
            let divider = CGMutablePath()
            divider.move(to: CGPoint(x: center.x, y: outline.minY)); divider.addLine(to: CGPoint(x: center.x, y: outline.maxY))
            strokes[1].frame = face.bounds; strokes[1].lineWidth = line; strokes[1].path = divider
        case .arrows:
            let scale = window?.backingScaleFactor ?? 2
            if scale != renderedScale, let image = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13*k, weight: .semibold).applying(.init(paletteColors: [Self.tint]))) {
                renderedScale = scale
                let size = image.size
                for (piece, direction) in pieces {
                    piece.contentsScale = scale; piece.contents = image.layerContents(forContentsScale: scale)
                    piece.bounds = CGRect(origin: .zero, size: size)
                    let half = CGMutablePath()
                    half.addLines(between: direction.dx < 0 ? [.zero, CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
                                                             : [.zero, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height)])
                    half.closeSubpath()
                    (piece.mask as? CAShapeLayer)?.path = half
                }
                if let mark = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7*k, weight: .bold).applying(.init(paletteColors: [Self.tint]))) {
                    plus.contentsScale = scale; plus.contents = mark.layerContents(forContentsScale: scale)
                    plus.bounds = CGRect(origin: .zero, size: mark.size)
                }
            }
            pieces.forEach { $0.layer.position = center }
            // In the empty corner between the arrows, at the glyph's top right.
            let arrows = pieces.first?.layer.bounds.size ?? .zero
            plus.position = CGPoint(x: center.x+arrows.width*0.36, y: center.y+arrows.height*0.36)
        }
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); renderedScale = 0; needsLayout = true }

    // MARK: Sliding out from behind the card

    /// Tucks the button behind the card's edge, out of sight.
    func tuckBehindCard() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.removeAnimation(forKey: "slide")
        body.transform = CATransform3DMakeTranslation(Self.tuckedOffset, 0, 0)
        CATransaction.commit()
    }
    /// Slides the button back behind the card's edge after `delay`, from wherever it shows now.
    func slideIn(after delay: TimeInterval) {
        let from = shownSlide
        action = nil
        tuckBehindCard()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, from != Self.tuckedOffset else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = from; slide.toValue = Self.tuckedOffset
        // Quick off the mark, so it's mostly in before the card has moved far.
        slide.duration = Self.tuckDuration; slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        slide.beginTime = CACurrentMediaTime()+delay; slide.fillMode = .backwards
        body.add(slide, forKey: "slide")
    }
    var isTucked: Bool { body.transform.m41 < 0 }
    /// Slides the button out from behind the card's edge after `delay`.
    func slideOut(after delay: TimeInterval) {
        let from = body.transform.m41
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.transform = CATransform3DIdentity
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, from != 0 else { return }
        // A single number, so the spring can carry it past its end; whole transforms don't overshoot.
        let spring = Self.slideSpring
        spring.keyPath = "transform.translation.x"; spring.fromValue = from; spring.toValue = 0
        spring.duration = spring.settlingDuration
        spring.beginTime = CACurrentMediaTime()+delay; spring.fillMode = .backwards
        body.add(spring, forKey: "slide")
    }

    // MARK: Hover and press

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: buttonRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        refreshHover()
    }
    /// Moving or revealing the button can leave its tracking state at the previous geometry.
    func refreshHover() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 else { hovering = false; return }
        hovering = buttonRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    /// Only the button takes clicks, not the room around it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, let superview else { return nil }
        return buttonRect.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hovering = false }
    }
    /// While the pointer is over the arrows, ⌘ going down or up shows or hides the plus.
    private func watchCommand() {
        guard glyph == .arrows else { return }
        if hovering, commandMonitor == nil {
            commandMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.commandChanged(event.modifierFlags.contains(.command)); return event
            }
        } else if !hovering, let monitor = commandMonitor {
            NSEvent.removeMonitor(monitor); commandMonitor = nil
        }
        commandChanged(NSEvent.modifierFlags.contains(.command))
    }
    func commandChanged(_ held: Bool) { showsPlus = glyph == .arrows && hovering && held }
    /// Fades and grows in from 0.7, and back out the same way.
    private func updatePlus() {
        let opacity: Float = showsPlus ? 1 : 0, scale: CGFloat = showsPlus ? 1 : Self.plusScale
        let shown = plus.presentation() ?? plus
        let fromOpacity = shown.opacity, fromScale = shown.transform.m11
        CATransaction.begin(); CATransaction.setDisableActions(true)
        plus.opacity = opacity; plus.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        guard !Self.reduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = fromOpacity; fade.toValue = opacity
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = fromScale; grow.toValue = scale
        let group = CAAnimationGroup(); group.animations = [fade, grow]
        group.duration = Self.plusDuration; group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        plus.add(group, forKey: "plus")
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = buttonRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = buttonRect.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }

    /// A faint wash of the text color over the button's own fill.
    private func updateWash() {
        CATransaction.begin(); CATransaction.setAnimationDuration(pressed ? 0.05 : 0.15)
        wash.backgroundColor = washColor.withAlphaComponent(pressed ? 0.07 : hovering ? 0.04 : 0).cgColor
        CATransaction.commit()
    }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func updateGlyph() {
        switch glyph {
        case .cross: break
        case .arrows:
            // Picture in Picture's spread: 1.5 pt apart, springing in and returning quickly.
            for (piece, direction) in pieces {
                let distance: CGFloat = hovering && !Self.reduceMotion ? 1.5 : 0
                let target = CGSize(width: direction.dx*distance, height: direction.dy*distance)
                let current = (piece.presentation()?.value(forKeyPath: "transform.translation") as? NSValue)?.sizeValue ?? .zero
                CATransaction.begin(); CATransaction.setDisableActions(true)
                piece.removeAnimation(forKey: "hover")
                piece.transform = CATransform3DMakeTranslation(target.width, target.height, 0)
                CATransaction.commit()
                guard !Self.reduceMotion else { continue }
                let animation: CABasicAnimation
                if hovering {
                    let spring = CASpringAnimation(keyPath: "transform.translation")
                    spring.mass = 1; spring.stiffness = 520; spring.damping = 2*0.6*sqrt(520)
                    spring.duration = spring.settlingDuration; animation = spring
                } else {
                    animation = CABasicAnimation(keyPath: "transform.translation")
                    animation.duration = 0.1; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                }
                animation.fromValue = NSValue(size: current); animation.toValue = NSValue(size: target)
                piece.add(animation, forKey: "hover")
            }
        case .split:
            // The divider sways once: middle, left, right, and back to the middle.
            guard hovering, !Self.reduceMotion, strokes[1].animation(forKey: "sway") == nil else { return }
            let sway = CAKeyframeAnimation(keyPath: "transform.translation.x")
            let reach = 1.6*glyphScale
            sway.values = [0, -reach, reach, 0]; sway.keyTimes = [0, 0.28, 0.72, 1]
            sway.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
            sway.duration = 0.5
            strokes[1].add(sway, forKey: "sway")
        }
    }
    /// For tests: how far the button is shrunk, how strong its hover wash is, whether the
    /// divider is swaying, and how far apart the arrows are heading.
    var pressScale: CGFloat { face.transform.m11 }
    /// Where the slide shows the button now, 0 once it's out.
    var shownSlide: CGFloat { (body.presentation() ?? body).transform.m41 }
    /// Where the button comes to rest once any slide is done.
    var restingCenter: CGPoint { body.position }
    /// When the slide starts, if one is on its way.
    var slideStart: CFTimeInterval? { body.animation(forKey: "slide")?.beginTime }
    /// The spring carrying the slide, if one is on its way.
    var slideAnimation: CASpringAnimation? { body.animation(forKey: "slide") as? CASpringAnimation }
    var washAlpha: CGFloat { wash.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 }
    var isSwaying: Bool { strokes.count > 1 && strokes[1].animation(forKey: "sway") != nil }
    var arrowSpread: CGFloat { pieces.first.map { abs($0.layer.transform.m41) } ?? 0 }
}
