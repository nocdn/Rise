import AppKit

/// The sidebar's Now Playing, over Downloads and Sort while a tab you've left plays: drawn as the
/// chosen tab is, with the media's artwork, title and artist, and a waveform following its sound.
/// Under the pointer it springs open upwards, quickly and without overshoot, to the floating
/// player's progress bar, a little slimmer, with the time either side beneath it, and a row of
/// controls: show the tab (the player's arrows) at the left edge, back, play or pause (the
/// player's) and forward in the middle, and the tab's mute button at the right edge. The waveform
/// turns into the player's X, which pauses and puts the card away.
@MainActor final class NowPlayingCard: FlippedView {
    /// The same space inside every edge, up to the ink of what's there: the artwork, the bar's
    /// ends, the times' digits and the glyphs at either end of the row, as the X's at the top.
    static let padding: CGFloat = 10
    static let artworkSize: CGFloat = 32
    static let artworkRadius: CGFloat = 3
    static let collapsedHeight: CGFloat = artworkSize+2*padding
    /// Opened: the bar 12 pt under the artwork, the times under it, and the row, whose middle is
    /// the play button's half-height (7.25 pt of ink) and the padding up from the bottom.
    static let barMiddle: CGFloat = padding+artworkSize+12
    static let rowMiddle: CGFloat = barMiddle+34
    static let expandedHeight: CGFloat = (rowMiddle+7.25+padding).rounded()
    /// The buttons' boxes, which shade under the pointer.
    static let buttonSize: CGFloat = 26
    /// Opening and the quicker closing, neither overshooting.
    static let openSpring = (response: 0.28, bounce: 0.0), closeSpring = (response: 0.16, bounce: 0.0)

    var onTogglePlayback: (() -> Void)?
    var onClose: (() -> Void)?
    var onShowTab: (() -> Void)?
    var onSkip: ((Bool) -> Void)?
    var onToggleMute: (() -> Void)?
    var onSeek: ((Double, Bool) -> Void)?

    private(set) var isShown = false
    private let background = PlainTabBackground()
    /// Clips what lies past the card's height while it's closed or opening.
    private let content = FlippedView()
    private let artwork = NowPlayingArtwork()
    private let titleField = TabTitleField(frame: .zero)
    private let artistField = FadingTextField(frame: .zero)
    let waveform = NowPlayingWaveform()
    let closeControl = FloatingVideoControl(glyph: .cross, title: "Pause and Hide")
    /// What opens: the bar, its times and the row of controls.
    private let controls = FlippedView()
    let progress = FloatingVideoProgressBar()
    private let elapsed = label("", size: 10, color: .secondaryLabelColor)
    private let remaining = label("", size: 10, color: .secondaryLabelColor)
    let showTabControl = FloatingVideoControl(glyph: .arrows, title: "Show Tab")
    let backButton = NowPlayingSkipButton(forward: false)
    let forwardButton = NowPlayingSkipButton(forward: true)
    let playButton = PlayPauseButton()
    let audio = TabAudioButton()

    private var spring = MotionSpring(0)
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var dock = (x: CGFloat(0), width: CGFloat(0), bottom: CGFloat(0))
    private var hovering = false
    private var toggleConfirmationDeadline: CFTimeInterval = 0
    private var theme: RiseTheme?
    /// How open it is: 0 closed, 1 open, past 1 in the spring's overshoot.
    var expansion: CGFloat { CGFloat(spring.value) }
    var isExpanded: Bool { spring.target == 1 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = false
        content.wantsLayer = true
        content.layer?.masksToBounds = true; content.layer?.cornerRadius = TabAppearance.radius; content.layer?.cornerCurve = .continuous
        addSubview(background); addSubview(content)
        background.show(chosen: true, hovered: false, animated: false)
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        artistField.font = .systemFont(ofSize: 12)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        remaining.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); remaining.alignment = .right
        [artwork, titleField, artistField, waveform, closeControl, controls].forEach(content.addSubview)
        [progress, elapsed, remaining, showTabControl, backButton, playButton, forwardButton, audio].forEach(controls.addSubview)

        // The floating player's bar, a little slimmer and growing a little less under the pointer.
        progress.restThickness = 4; progress.activeThickness = 7
        progress.scrubsWithScrollWheel = true
        progress.seek = { [weak self] fraction, final in self?.onSeek?(fraction, final) }
        progress.onPosition = { [weak self] in self?.updateTimes() }
        progress.interactionEnded = { [weak self] in self?.pointerMayHaveLeft() }
        closeControl.action = { [weak self] in self?.onClose?() }
        showTabControl.action = { [weak self] in self?.onShowTab?() }
        backButton.action = { [weak self] in self?.onSkip?(false) }
        forwardButton.action = { [weak self] in self?.onSkip?(true) }
        playButton.pointSize = 15
        // Tabler's outlined pause (MIT, Paweł Kuna), with the row's line weight.
        playButton.pauseOutline = .init(path: "M6 6a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1zm8 0a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1z",
                                        size: 22, lineWidth: 2*TabAudioButton.glyphSize/24)
        closeControl.glyphBox = Self.buttonSize
        // The same rounded shade as the row's other buttons.
        [playButton, backButton, forwardButton, audio].forEach { $0.layer?.cornerRadius = 7 }
        playButton.action = { [weak self] in
            guard let self else { return }
            // Shows the new state at once; the page's report confirms or corrects it.
            self.setPlayback(paused: !self.playButton.paused, confirmed: true)
            self.toggleConfirmationDeadline = CACurrentMediaTime()+1
            self.onTogglePlayback?()
        }
        audio.action = { [weak self] in
            guard let self else { return }
            self.audio.setMuted(!self.audio.muted, animated: true); self.onToggleMute?()
        }
        isHidden = true; alphaValue = 0
        applyExpansion()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Now Playing")
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ theme: RiseTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        background.dark = theme == .dark
        titleField.textColor = TabAppearance.text(theme, selected: true)
        artistField.textColor = theme.muted
        [elapsed, remaining].forEach { $0.textColor = theme.muted }
        let ink = TabAppearance.text(theme, selected: true)
        let hover = theme == .dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
        for control in [closeControl, showTabControl] {
            control.tint = ink; control.hoverBackground = hover; control.hoverHint?.appearance = theme.appearance
        }
        [backButton, forwardButton].forEach { $0.color = ink; $0.hoverColor = hover }
        playButton.color = ink; playButton.hoverColor = hover
        audio.color = ink; audio.hoverColor = hover
        waveform.color = ink
        artwork.placeholder = ink.withAlphaComponent(theme == .dark ? 0.08 : 0.06)
        progress.trackColor = ink.withAlphaComponent(theme == .dark ? 0.2 : 0.14)
        progress.fillColor = ink.withAlphaComponent(0.85)
    }

    /// What plays. The title and artist fall back to the tab's own, the artwork to its icon.
    func show(title: String, artist: String, artwork image: NSImage?, icon: NSImage?, muted: Bool) {
        if titleField.stringValue != title { titleField.stringValue = title }
        if artistField.stringValue != artist { artistField.stringValue = artist }
        artwork.set(image: image, icon: icon, animated: isShown)
        audio.setMuted(muted, animated: isShown)
        setAccessibilityLabel("Now Playing: \(title)")
    }
    /// The page's state. After a press, only its answer (`confirmed`) replaces the button's new
    /// state for a moment, so an earlier report cannot undo it.
    func setPlayback(paused: Bool, confirmed: Bool = false) {
        if confirmed { toggleConfirmationDeadline = 0 }
        else if CACurrentMediaTime() < toggleConfirmationDeadline { return }
        playButton.setPaused(paused, animated: isShown)
        waveform.playing = !paused
        startLink()
    }
    var isPaused: Bool { playButton.paused }
    func showPosition(time: Double, duration: Double) {
        progress.show(time: time, duration: duration)
        updateTimes()
    }
    private func updateTimes() {
        let shows = !progress.isHidden && progress.duration > 0
        elapsed.isHidden = !shows; remaining.isHidden = !shows
        guard shows else { return }
        let duration = progress.duration, time = progress.fraction*duration
        let left = Self.timestamp(time), right = "-" + Self.timestamp(max(0, duration-time))
        if elapsed.stringValue != left { elapsed.stringValue = left }
        if remaining.stringValue != right { remaining.stringValue = right }
    }
    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total/3600, total/60%60, total%60) : String(format: "%d:%02d", total/60, total%60)
    }

    /// Shows or hides the card, fading.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shown {
            isHidden = false
            refreshHover()
        } else {
            hovering = false
            [closeControl, showTabControl].forEach { $0.hideHoverHint() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce || window == nil ? 0 : shown ? 0.2 : 0.14
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            animator().alphaValue = shown ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.isHidden = true
                self.spring = MotionSpring(0); self.applyExpansion(); self.stopLink()
            }
        }
        startLink()
    }

    /// Where the sidebar keeps it: its left edge and width, and the bottom it opens up from.
    func dock(x: CGFloat, width: CGFloat, bottom: CGFloat) {
        guard x != dock.x || width != dock.width || bottom != dock.bottom else { return }
        dock = (x, width, bottom)
        applyExpansion()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Everything lines up on the padding by its ink, so a glyph's box reaches past it.
        let w = bounds.width, p = Self.padding, art = Self.artworkSize, middle = p+art/2
        artwork.frame = NSRect(x: p, y: p, width: art, height: art)
        // The waveform's bars are exactly its width; the X's ink ends where they do.
        let barsWidth = 5*NowPlayingWaveform.barWidth+4*NowPlayingWaveform.gap
        waveform.frame = NSRect(x: w-p-barsWidth, y: middle-11, width: barsWidth, height: 22)
        let closeBox: CGFloat = 22
        closeControl.frame = NSRect(x: w-p-closeControl.inkHalfWidth-closeBox/2, y: middle-closeBox/2, width: closeBox, height: closeBox)
        let textX = artwork.frame.maxX+8, textWidth = max(0, waveform.frame.minX-8-textX)
        let titleHeight = ceil(titleField.intrinsicContentSize.height), artistHeight = ceil(artistField.intrinsicContentSize.height)
        let textY = (middle-(titleHeight+artistHeight)/2).rounded()
        titleField.frame = NSRect(x: textX, y: textY, width: textWidth, height: titleHeight)
        artistField.frame = NSRect(x: textX, y: textY+titleHeight, width: textWidth, height: artistHeight)

        // The controls start under the artwork, so the bar is inside them to take clicks.
        let top = artwork.frame.maxY
        controls.frame = NSRect(x: 0, y: top, width: w, height: max(0, Self.expandedHeight-top))
        // The track runs from padding to padding and thickens about its centerline.
        progress.frame = NSRect(x: p, y: Self.barMiddle-top-7, width: w-2*p, height: 14)
        // A label's text sits 2 pt inside its frame, and the digits' ink half a point inside that.
        let timeHeight = ceil(elapsed.intrinsicContentSize.height), timeY = Self.barMiddle-top+6
        elapsed.frame = NSRect(x: p-2.5, y: timeY, width: (w-2*p)/2+2.5, height: timeHeight)
        remaining.frame = NSRect(x: w/2, y: timeY, width: (w-2*p)/2+2.5, height: timeHeight)
        let side = Self.buttonSize, rowY = Self.rowMiddle-top-side/2
        // The row's end buttons sit as far in from the sides as their shade does from the bottom.
        let inset = Self.expandedHeight-(Self.rowMiddle+side/2)
        showTabControl.frame = NSRect(x: inset, y: rowY, width: side, height: side)
        audio.frame = NSRect(x: w-inset-side, y: rowY, width: side, height: side)
        playButton.frame = NSRect(x: ((w-side)/2).rounded(), y: rowY, width: side, height: side)
        backButton.frame = NSRect(x: playButton.frame.minX-4-side, y: rowY, width: side, height: side)
        forwardButton.frame = NSRect(x: playButton.frame.maxX+4, y: rowY, width: side, height: side)
    }

    private func applyExpansion() {
        let e = expansion
        let height = Self.collapsedHeight+(Self.expandedHeight-Self.collapsedHeight)*max(0, e)
        let frame = NSRect(x: dock.x, y: dock.bottom-height, width: dock.width, height: height)
        if self.frame != frame { self.frame = frame }
        background.frame = bounds; content.frame = bounds
        // The controls come in as the card opens past a quarter, and leave before it's closed.
        let shown = min(1, max(0, (e-0.25)/0.6))
        controls.alphaValue = shown; controls.isHidden = e < 0.02
        let swap = min(1, max(0, e*1.6))
        waveform.alphaValue = 1-swap; waveform.shrink = swap
        closeControl.alphaValue = swap; closeControl.isHidden = swap < 0.02
    }

    // MARK: Opening under the pointer

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { pointerMayHaveLeft() }
    /// Tracking areas update only as the pointer moves; a card that moved or resized under a
    /// still one checks again.
    func refreshHover() {
        guard isShown, let window, window.isVisible else { setHovering(false); return }
        setHovering(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }
    private func pointerMayHaveLeft() {
        guard let window else { return }
        if bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) || progress.isScrubbing || progress.isTrackpadScrubbing { return }
        setHovering(false)
    }
    private func setHovering(_ hovering: Bool) {
        guard hovering != self.hovering, isShown || !hovering else { return }
        self.hovering = hovering
        if !hovering { [closeControl, showTabControl].forEach { $0.hideHoverHint() } }
        let motion = hovering ? Self.openSpring : Self.closeSpring
        spring.configure(response: motion.response, bounce: motion.bounce)
        spring.target = hovering ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
            spring.value = spring.target; spring.velocity = 0; applyExpansion()
        }
        startLink()
    }

    // MARK: The clock

    private func startLink() {
        guard link == nil, window != nil, !isHidden else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link; lastTick = nil
    }
    private func stopLink() { link?.invalidate(); link = nil; lastTick = nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() } else { startLink() }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(1.0/30, max(0, now-(lastTick ?? now-1.0/60))); lastTick = now
        if spring.isResting(within: 0.0005) {
            if spring.value != spring.target { spring.value = spring.target; spring.velocity = 0; applyExpansion() }
        } else { spring.step(dt); applyExpansion() }
        waveform.step(dt, now: now)
        if spring.isResting(within: 0.0005), !waveform.isAnimating || isHidden || alphaValue == 0 && !isShown { stopLink() }
    }

    // A click on the card, past its controls, shows its tab.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), point.y < Self.collapsedHeight { onShowTab?() }
    }
    override func accessibilityPerformPress() -> Bool { onShowTab?(); return true }
}

/// The media's artwork, filling a rounded square, or the tab's icon in its middle.
@MainActor final class NowPlayingArtwork: NSView {
    private let image = CALayer(), icon = CALayer()
    var placeholder: NSColor = .clear { didSet { layer?.backgroundColor = placeholder.cgColor } }
    private var shown: (image: NSImage?, icon: NSImage?) = (nil, nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = NowPlayingCard.artworkRadius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        image.contentsGravity = .resizeAspectFill; icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon); layer?.addSublayer(image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func set(image newImage: NSImage?, icon newIcon: NSImage?, animated: Bool) {
        guard newImage !== shown.image || newIcon !== shown.icon else { return }
        let changed = newImage !== shown.image
        shown = (newImage, newIcon)
        let scale = window?.backingScaleFactor ?? 2
        if changed, animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.2
            image.add(fade, forKey: "artwork")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.contents = newImage?.layerContents(forContentsScale: scale)
        image.isHidden = newImage == nil
        icon.contents = newIcon?.layerContents(forContentsScale: scale)
        icon.isHidden = newImage != nil
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        image.frame = bounds
        let side = min(18, bounds.width*0.55)
        icon.frame = NSRect(x: (bounds.width-side)/2, y: (bounds.height-side)/2, width: side, height: side)
        CATransaction.commit()
    }
}

/// Five bars following the playing media's sound: the bass in the middle, the treble at the ends,
/// so it keeps the waveform symbol's shape, tallest in the middle. Each band is measured against its
/// own recent peak, so quiet and loud media both move; where the page's sound can't be read, the
/// bars sway on their own. Paused, they settle and fade away, shrinking a little; playing again,
/// they come back.
@MainActor final class NowPlayingWaveform: NSView {
    var color: NSColor = .labelColor { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    var playing = false
    /// 0 to 1 as it gives way to the X: it shrinks a little as it fades.
    var shrink: CGFloat = 0 { didSet { if shrink != oldValue { placeHolder() } } }
    private let holder = CALayer()
    private let bars = (0..<5).map { _ in CALayer() }
    private var values = [Double](repeating: 0, count: 5)
    private var peaks = [Double](repeating: 0.25, count: 5)
    /// Which band each bar shows, left to right, and how far each can reach.
    private static let bands = [3, 1, 0, 2, 4]
    private static let reach: [CGFloat] = [0.6, 0.85, 1, 0.85, 0.6]
    private static let rest: [CGFloat] = [3, 5, 7, 5, 3]
    private var targets: [Double]?
    private var silentSince: CFTimeInterval?
    private var phase = 0.0
    /// 0 to 1 as it fades in while playing and out while paused.
    private(set) var presence: CGFloat = 0
    static let barWidth: CGFloat = 2.2, gap: CGFloat = 2, maximum: CGFloat = 16
    var isAnimating: Bool { playing || values.contains { $0 > 0.002 } || presence > 0 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.addSublayer(holder)
        holder.opacity = 0
        for bar in bars {
            bar.cornerRadius = Self.barWidth/2; bar.backgroundColor = color.cgColor
            holder.addSublayer(bar)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); placeHolder(); placeBars() }
    private func placeHolder() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        holder.bounds = bounds; holder.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = (1-0.4*shrink)*(0.7+0.3*presence)
        holder.transform = CATransform3DMakeScale(scale, scale, 1)
        holder.opacity = Float(presence)
        CATransaction.commit()
    }
    private func placeBars() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let total = CGFloat(bars.count)*Self.barWidth+CGFloat(bars.count-1)*Self.gap
        var x = (bounds.width-total)/2
        for (index, (bar, value)) in zip(bars, values).enumerated() {
            let low = Self.rest[index], high = Self.maximum*Self.reach[index]
            let height = low+(max(low, high)-low)*CGFloat(min(1, max(0, value)))
            bar.frame = CGRect(x: x, y: (bounds.height-height)/2, width: Self.barWidth, height: height)
            x += Self.barWidth+Self.gap
        }
        CATransaction.commit()
    }
    /// The page's levels, each 0 to 1, or nil where its sound can't be read.
    func setLevels(_ levels: [Double]?, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let levels, levels.count == bars.count else { targets = nil; silentSince = nil; return }
        // Media whose sound can't be read reads as silence; after a second of it, the bars sway instead.
        if levels.allSatisfy({ $0 < 0.004 }) {
            let since = silentSince ?? now; silentSince = since
            if now-since > 1 { targets = nil; return }
        } else { silentSince = nil }
        let shaped = levels.enumerated().map { index, level in
            peaks[index] = max(level, peaks[index]*0.985)
            return pow(min(1, level/max(peaks[index], 0.12)), 1.5)
        }
        targets = Self.bands.map { shaped[$0] }
    }
    func step(_ dt: Double, now: CFTimeInterval) {
        phase += dt
        for index in values.indices {
            let target: Double
            if !playing { target = 0 }
            else if let targets { target = targets[index] }
            else {
                let i = Double(index)
                target = 0.45+0.28*sin(phase*(5.1+i*1.7)+i*1.3)+0.17*sin(phase*(8.3-i*0.9)+i*2.1)
            }
            // Quick to rise, slower to fall, as a meter's needle.
            let rate = target > values[index] ? 22.0 : 8.0
            values[index] += (target-values[index])*(1-exp(-rate*dt))
            if !playing, values[index] < 0.002 { values[index] = 0 }
        }
        let goal: CGFloat = playing ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { presence = goal }
        else { presence += (goal-presence)*CGFloat(1-exp(-(playing ? 14.0 : 10.0)*dt)) }
        if abs(goal-presence) < 0.002 { presence = goal }
        placeHolder()
        placeBars()
    }
}

/// Back or forward: Tabler's skip back, turned round for forward, with the tab buttons' shade
/// under the pointer, which shrinks while pressed and nudges the way it skips.
@MainActor final class NowPlayingSkipButton: GlyphButton {
    let forward: Bool
    var color: NSColor = .labelColor { didSet { if color != oldValue { applyColor() } } }
    private let glyph = CALayer(), symbol = CAShapeLayer()
    private var pressed = false { didSet { if pressed != oldValue { PressScale.set(glyph, to: pressed ? 0.86 : 1) } } }
    /// The volume button's size and stroke, so the row's outlines match.
    static let glyphSize = TabAudioButton.glyphSize
    // Tabler's player skip back (MIT, Paweł Kuna).
    private static let skipBackPath = "M20 18V6a2 2 0 0 0-2.75-1.84L9 10.26a2 2 0 0 0 0 3.5l8.25 6.1A2 2 0 0 0 20 18.11M4 20V4"
    init(forward: Bool) {
        self.forward = forward
        super.init(frame: .zero)
        layer?.addSublayer(glyph); glyph.addSublayer(symbol)
        symbol.fillColor = nil; symbol.lineWidth = 2*Self.glyphSize/24
        symbol.lineCap = .round; symbol.lineJoin = .round
        applyColor()
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(forward ? "Skip Forward" : "Skip Back")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.bounds = bounds; glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        symbol.frame = bounds
        // SVG coordinates run downward; forward is the same icon turned half round.
        let scale = Self.glyphSize/24
        var transform = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: scale, y: -scale)
            .rotated(by: forward ? .pi : 0)
            .translatedBy(x: -12, y: -12)
        symbol.path = TablerIcon.path(Self.skipBackPath).copy(using: &transform)
        CATransaction.commit()
    }
    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        symbol.strokeColor = color.cgColor
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside, isEnabled { nudge() }
        super.mouseUp(with: event)
    }
    private func nudge() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.mass = 1; spring.stiffness = 520; spring.damping = 2*0.6*sqrt(520)
        spring.fromValue = forward ? 3 : -3; spring.toValue = 0; spring.duration = spring.settlingDuration
        symbol.add(spring, forKey: "nudge")
    }
}
