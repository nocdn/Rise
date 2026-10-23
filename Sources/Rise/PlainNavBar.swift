import AppKit
import RiseCore

/// Dia's bar across the top of the page: the sidebar and navigation buttons
/// on the left, the page's site and title, and its pinned extensions on the right, on the page's
/// own colour with a hairline under it. Over the address, a field shows the whole address with
/// the page's controls. Measured from Dia at 1.4 px a point.
@MainActor final class PlainNavBar: FlippedView {
    enum Metrics {
        static let height: CGFloat = 40
        /// The line the bar's contents centre on.
        static let midY: CGFloat = 20
        /// The sidebar, back, forward and reload buttons' centres.
        static let navigationCentres: [CGFloat] = [19.5, 52, 87, 119.5]
        /// Where the text's ink starts, 2 pt past its label's own edge.
        static let textX: CGFloat = 147, textInset: CGFloat = 2
        static let fieldX: CGFloat = 139.5, fieldHeight: CGFloat = 28.5, fieldRadius: CGFloat = 6
        /// The field's buttons, its last centred this far in from its end.
        static let fieldButtonStride: CGFloat = 25, fieldButtonInset: CGFloat = 14
        /// The pinned extensions, the last centred as far in from the bar's end as the sidebar
        /// button is from its start; the field ends this far before the first's centre.
        static let extensionStride: CGFloat = 29.5, extensionInset: CGFloat = 19.5, fieldEndGap: CGFloat = 18.5
        static let font = NSFont.systemFont(ofSize: 12.5)
    }
    /// Its contents' colours on a light page, or a dark one: Dia's, measured, and set so Rise's
    /// text and glyphs draw as dark as Dia's do.
    struct Ink {
        let strong: NSColor, faint: NSColor, hairline: NSColor, field: NSColor, hover: NSColor
        static func on(_ color: NSColor) -> Ink {
            if isDark(color) {
                return Ink(strong: .white.withAlphaComponent(0.8), faint: .white.withAlphaComponent(0.31), hairline: .white.withAlphaComponent(0.1),
                           field: .white.withAlphaComponent(0.13), hover: .white.withAlphaComponent(0.08))
            }
            // On a white page, a white field wouldn't show: a faint shade instead.
            let white = (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.985 && (color.usingColorSpace(.sRGB)?.saturationComponent ?? 0) < 0.02
            return Ink(strong: .black.withAlphaComponent(0.79), faint: .black.withAlphaComponent(0.3), hairline: .black.withAlphaComponent(0.042),
                       field: white ? .black.withAlphaComponent(0.045) : .white, hover: .black.withAlphaComponent(0.05))
        }
        static func isDark(_ color: NSColor) -> Bool {
            guard let c = color.usingColorSpace(.sRGB) else { return false }
            return 0.2126*c.redComponent + 0.7152*c.greenComponent + 0.0722*c.blueComponent < 0.5
        }
    }

    private let hairline = CALayer(), field = CALayer()
    /// A page loading shows along the hairline, from the left as far as it's got, its front a
    /// little thicker and narrowing back to the hairline behind it.
    struct ProgressStyle {
        var color = NSColor(hex: 0x007AFF)
        var thickness: CGFloat = 0.5
        /// The front's thickness, and how far behind it the line is back to `thickness`.
        var frontThickness: CGFloat = 1, taper: CGFloat = 140
        var glow: CGFloat = 1.5, glowOpacity: Float = 0.6
    }
    var progressStyle = ProgressStyle() { didSet { layoutProgress() } }
    private let progressLine = CAShapeLayer()
    private(set) var progress: CGFloat?
    func showProgress(_ fraction: CGFloat?) { progress = fraction; layoutProgress() }

    // MARK: Following a load

    /// Loading, the line's front follows the page's progress on a spring, frame by frame, keeping
    /// its speed as each new report comes; done, it runs on to the end and fades.
    private(set) var isLoading = false
    private var loadTarget: CGFloat = 0, loadSpeed: CGFloat = 0, finishing = false
    private var loadLink: CADisplayLink?, lastTick: CFTimeInterval = 0
    static let loadFadeKey = "Rise.PlainLoadFade"
    /// A hard reload's line is red-pink rather than the accent.
    static let hardReloadColor = NSColor(hex: 0xF03C64)
    /// How far past the end a finished load's front carries on, out of sight, so it doesn't
    /// slow to a stop there; it fades from the moment it reaches it.
    static let overrun: CGFloat = 48
    /// The spring's angular frequency: critically damped, it settles in about half a second.
    static let stiffness: CGFloat = 11
    func setLoading(_ loading: Bool, progress value: Double, hard: Bool = false) {
        if loading {
            progressStyle.color = hard ? Self.hardReloadColor : ProgressStyle().color
            if !isLoading {
                isLoading = true; finishing = false; loadTarget = 0; loadSpeed = 0
                progressLine.removeAnimation(forKey: Self.loadFadeKey)
                CATransaction.begin(); CATransaction.setDisableActions(true); progressLine.opacity = 1; CATransaction.commit()
                showProgress(0)
            }
            loadTarget = max(loadTarget, min(0.97, max(0.07, CGFloat(value))))
            follow()
        } else if isLoading {
            // Aimed past the end, so it doesn't slow to a stop there; it fades on reaching it.
            isLoading = false; finishing = true; loadTarget = 1+Self.overrun/max(1, bounds.width)
            follow()
        }
    }
    /// Another tab's load, where it's got, without catching up to it.
    func resetLoading(_ loading: Bool, progress value: Double, hard: Bool = false) {
        stopFollowing(); isLoading = false; finishing = false
        progressLine.removeAnimation(forKey: Self.loadFadeKey)
        CATransaction.begin(); CATransaction.setDisableActions(true); progressLine.opacity = 1; CATransaction.commit()
        guard loading else { showProgress(nil); return }
        setLoading(true, progress: value, hard: hard)
        showProgress(loadTarget)
    }
    private func follow() {
        guard window?.screen != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            showProgress(min(1, loadTarget)); if finishing { finish() }; return
        }
        guard loadLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); loadLink = link; lastTick = CACurrentMediaTime()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = CGFloat(min(1.0/30, max(0, now-lastTick))); lastTick = now
        // The exact step of a critically damped spring, never past where it's going.
        let omega = Self.stiffness, front = progress ?? 0, offset = front-loadTarget, decay = exp(-omega*dt)
        let carried = loadSpeed+omega*offset
        var next = loadTarget+(offset+carried*dt)*decay
        loadSpeed = (loadSpeed-omega*carried*dt)*decay
        if next >= loadTarget { next = loadTarget; loadSpeed = 0 }
        showProgress(next)
        if finishing, next >= 1 { showProgress(1); stopFollowing(); finish(); return }
        if abs(next-loadTarget) < 0.0005 {
            showProgress(loadTarget); stopFollowing()
            if finishing { finish() }
        }
    }
    private func stopFollowing() { loadLink?.invalidate(); loadLink = nil }
    private func finish() {
        finishing = false
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { showProgress(nil); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Once faded, the line goes, ready for the next load at full strength.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isLoading, !self.finishing else { return }
                self.showProgress(nil)
                CATransaction.begin(); CATransaction.setDisableActions(true); self.progressLine.opacity = 1; CATransaction.commit()
            }
        }
        progressLine.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.35; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        progressLine.add(fade, forKey: Self.loadFadeKey)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, loadLink != nil { stopFollowing(); showProgress(isLoading ? loadTarget : nil) }
    }
    private func layoutProgress() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let progress, bounds.width > 0 else { progressLine.isHidden = true; return }
        let style = progressStyle, front = bounds.width*min(1, max(0, progress))
        let scale = window?.backingScaleFactor ?? 2
        let path = Self.progressPath(front: front, centre: bounds.height-0.5/scale, style: style)
        progressLine.frame = bounds; progressLine.path = path; progressLine.shadowPath = path
        // The glow blooms up into the bar only: cut along the line's lower edge, not over the page.
        let mask = progressLine.mask ?? { let mask = CALayer(); mask.backgroundColor = NSColor.black.cgColor; progressLine.mask = mask; return mask }()
        let lineBottom = bounds.height-0.5/scale+max(style.thickness, style.frontThickness)/2
        mask.frame = NSRect(x: -20, y: -20, width: bounds.width+40, height: lineBottom+20)
        progressLine.fillColor = style.color.cgColor
        progressLine.shadowColor = style.color.cgColor; progressLine.shadowOffset = .zero
        progressLine.shadowRadius = style.glow; progressLine.shadowOpacity = style.glowOpacity
        progressLine.isHidden = false
    }
    /// The line to `front`, centred on `centre`: the hairline's thickness, easing up over the
    /// taper to the front's, which ends round.
    static func progressPath(front: CGFloat, centre: CGFloat, style: ProgressStyle) -> CGPath {
        let path = CGMutablePath(), thin = style.thickness/2
        let thick = max(thin, style.frontThickness/2), capX = max(thick, front-thick)
        let taperStart = max(0, capX-style.taper)
        path.move(to: CGPoint(x: 0, y: centre-thin))
        path.addLine(to: CGPoint(x: taperStart, y: centre-thin))
        let middle = (taperStart+capX)/2
        path.addCurve(to: CGPoint(x: capX, y: centre-thick), control1: CGPoint(x: middle, y: centre-thin), control2: CGPoint(x: middle, y: centre-thick))
        path.addArc(center: CGPoint(x: capX, y: centre), radius: thick, startAngle: -.pi/2, endAngle: .pi/2, clockwise: false)
        path.addCurve(to: CGPoint(x: taperStart, y: centre+thin), control1: CGPoint(x: middle, y: centre+thick), control2: CGPoint(x: middle, y: centre+thin))
        path.addLine(to: CGPoint(x: 0, y: centre+thin))
        path.closeSubpath()
        return path
    }
    let text = PlainNavBarText(labelWithString: "")
    let copyButton: SidebarCopyButton
    let settingsButton: SidebarHoverButton, zoomButton: SidebarHoverButton
    var onOpenAddress: (() -> Void)?
    /// Where its buttons sit, and how much sooner its address starts for fewer of them: a split's
    /// right page has no sidebar button, so its back, forward and reload move up a place.
    var navigationCentres = Metrics.navigationCentres
    var leadingRoom: CGFloat = 0 { didSet { needsLayout = true } }
    /// Rise's titlebar buttons, carried here while the bar shows.
    var navigation: [ChromeButton] = [] {
        didSet {
            for button in oldValue where !navigation.contains(button) && button.superview === self { button.removeFromSuperview() }
            for button in navigation where button.superview !== self { addSubview(button) }
            applyInk(); needsLayout = true
        }
    }
    var extensionButtons: [SidebarExtensionButton] = [] {
        didSet {
            for button in oldValue where !extensionButtons.contains(button) { button.removeFromSuperview() }
            for button in extensionButtons where button.superview !== self { addSubview(button); button.allowsInteraction = true }
            applyInk(); needsLayout = true
        }
    }
    private(set) var color = NSColor.white
    private(set) var ink = Ink.on(.white)
    private(set) var isHovered = false
    private var url: URL?, title = ""
    var pageZoom: CGFloat = 1 { didSet { if pageZoom != oldValue { needsLayout = true; updateFieldControls(animated: true) } } }
    var showsZoom: Bool { url != nil && !PageZoom.isActual(pageZoom) }

    init(copy: @escaping () -> Void, settings: @escaping () -> Void, zoom: @escaping () -> Void) {
        copyButton = SidebarCopyButton(action: copy)
        settingsButton = SidebarHoverButton(symbol: "slider.horizontal.3", size: 14, title: "Site controls", action: settings)
        settingsButton.image = TablerIcon.image(TablerIcon.adjustments, size: 16, description: "Site controls")
        zoomButton = SidebarHoverButton(symbol: "plus.magnifyingglass", size: 14, title: "Zoom", action: zoom)
        zoomButton.image = TablerIcon.image(TablerIcon.zoomIn, size: 16, description: "Zoom")
        super.init(frame: .zero)
        wantsLayer = true
        field.cornerRadius = Metrics.fieldRadius; field.cornerCurve = .continuous; field.opacity = 0
        layer?.addSublayer(field); layer?.addSublayer(hairline); layer?.addSublayer(progressLine)
        progressLine.isHidden = true
        text.font = Metrics.font; text.lineBreakMode = .byTruncatingTail; text.cell?.usesSingleLineMode = true
        addSubview(text)
        for button in [zoomButton, copyButton, settingsButton] as [SidebarHoverButton] { addSubview(button); button.alphaValue = 0 }
        setColor(.white, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The page it's over: its address and title.
    func show(url: URL?, title: String) {
        let url = url?.absoluteString == "about:blank" ? nil : url
        guard url != self.url || title != self.title else { return }
        self.url = url; self.title = title
        updateText(); updateFieldControls(animated: false); needsLayout = true
    }

    /// The page's colour under its top edge, which the bar takes, its contents light or dark to suit.
    func setColor(_ color: NSColor, animated: Bool) {
        let next = color.usingColorSpace(.sRGB) ?? color
        guard next != self.color || layer?.backgroundColor == nil else { return }
        let from = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        self.color = next; ink = Ink.on(next)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = next.cgColor
        CATransaction.commit()
        if animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let from {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from; fade.toValue = next.cgColor; fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(fade, forKey: "color")
        }
        applyInk()
    }

    private func applyInk() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hairline.backgroundColor = ink.hairline.cgColor; field.backgroundColor = ink.field.cgColor
        CATransaction.commit()
        let buttons: [ChromeButton] = navigation + [zoomButton, copyButton, settingsButton] + extensionButtons
        for button in buttons {
            if button.contentTintColor != ink.strong { button.contentTintColor = ink.strong }
            button.hoverColor = ink.hover
        }
        updateText()
    }

    private func updateText() {
        let strong: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: ink.strong]
        let faint: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: ink.faint]
        let shown = NSMutableAttributedString()
        if let url {
            if isHovered {
                // The whole address, its site strong and the rest faint.
                let address = AddressDisplay.text(url.absoluteString)
                let site = address.firstIndex(of: "/").map { String(address[..<$0]) } ?? address
                shown.append(NSAttributedString(string: site, attributes: strong))
                shown.append(NSAttributedString(string: String(address.dropFirst(site.count)), attributes: faint))
            } else {
                let site = AddressResolver.displayHost(url)
                shown.append(NSAttributedString(string: site, attributes: strong))
                let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
                // A page without a site, such as a data: one, shows its title alone.
                if !words.isEmpty, words != site { shown.append(NSAttributedString(string: site.isEmpty ? words : " / \(words)", attributes: faint)) }
            }
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        shown.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: shown.length))
        if !text.attributedStringValue.isEqual(to: shown) { text.attributedStringValue = shown }
    }

    /// Where the field ends: before the first pinned extension.
    private var fieldMaxX: CGFloat {
        guard !extensionButtons.isEmpty else { return bounds.width-12 }
        return extensionCentre(0)-Metrics.fieldEndGap
    }
    private func extensionCentre(_ index: Int) -> CGFloat {
        bounds.width-Metrics.extensionInset-Metrics.extensionStride*CGFloat(extensionButtons.count-1-index)
    }
    var fieldRect: NSRect {
        NSRect(x: Metrics.fieldX-leadingRoom, y: Metrics.midY-Metrics.fieldHeight/2, width: max(0, fieldMaxX-Metrics.fieldX+leadingRoom), height: Metrics.fieldHeight)
    }
    private var fieldButtons: [SidebarHoverButton] { (showsZoom ? [zoomButton] : []) + [copyButton, settingsButton] }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2, mid = Metrics.midY
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hairline.frame = NSRect(x: 0, y: bounds.height-1/scale, width: bounds.width, height: 1/scale)
        field.frame = fieldRect
        CATransaction.commit()
        layoutProgress()
        for (button, centre) in zip(navigation, navigationCentres) {
            button.frame = NSRect(x: centre-14, y: mid-14, width: 28, height: 28)
        }
        for (index, button) in extensionButtons.enumerated() {
            button.frame = NSRect(x: extensionCentre(index)-14, y: mid-14, width: 28, height: 28)
        }
        let buttons = fieldButtons, end = fieldRect.maxX-Metrics.fieldButtonInset
        for (index, button) in buttons.enumerated() {
            let centre = end-Metrics.fieldButtonStride*CGFloat(buttons.count-1-index)
            button.frame = NSRect(x: centre-13.5, y: mid-12, width: 27, height: 24)
        }
        zoomButton.isHidden = !showsZoom
        // The text runs to the field's buttons while they show, and to its end otherwise.
        let textEnd = isHovered || showsZoom ? (buttons.first?.frame.minX ?? fieldRect.maxX)-4 : fieldRect.maxX-8
        let line = ceil(text.intrinsicContentSize.height)
        let textX = Metrics.textX-Metrics.textInset-leadingRoom
        text.frame = NSRect(x: textX, y: round((mid-line/2)*2)/2, width: max(0, textEnd-textX), height: line)
    }

    // MARK: Hovering the address

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        setHovered(fieldRect.contains(convert(event.locationInWindow, from: nil)) && isFrontmost(at: event.locationInWindow))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ hovered: Bool) {
        let hovered = hovered && url != nil
        guard hovered != isHovered else { return }
        isHovered = hovered
        fade(field, to: hovered ? 1 : 0)
        updateText(); updateFieldControls(animated: true); needsLayout = true
    }
    private func updateFieldControls(animated: Bool) {
        for button in [zoomButton, copyButton, settingsButton] as [SidebarHoverButton] {
            let on = url != nil && (isHovered || (button === zoomButton && showsZoom))
            button.allowsInteraction = on
            let target: CGFloat = on ? 1 : 0
            guard button.alphaValue != target else { continue }
            if animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = on ? 0.14 : 0.12; button.animator().alphaValue = target
                }
            } else { button.alphaValue = target }
        }
    }
    private func fade(_ layer: CALayer, to opacity: Float) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from; fade.toValue = opacity; fade.duration = opacity > 0 ? 0.14 : 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }
    /// The address opens the address panel, as ⌘L does; the rest of the bar moves the window, as
    /// a title bar would.
    override func mouseDown(with event: NSEvent) {
        if fieldRect.contains(convert(event.locationInWindow, from: nil)) { onOpenAddress?() } else { window?.performDrag(with: event) }
    }
}

/// The address, which leaves its clicks to the bar.
final class PlainNavBarText: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
