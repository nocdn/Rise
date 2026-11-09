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
        /// The page's buttons, then the pinned extensions, in one row at the bar's end, 28 pt
        /// square: the last centred as far in from the bar's end as the sidebar button is from
        /// its start; the field ends this far before the first's centre.
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
    /// The page's buttons, left of the pinned extensions, which give way to developer mode's.
    private let addressHost = ContentHost()
    let copyButton: SidebarCopyButton
    let settingsButton: SidebarHoverButton, zoomButton: SidebarHoverButton
    /// What the page is asking to use, left of the site controls while it asks, or of developer
    /// mode's buttons while its bar shows; its prompt comes out of it.
    let permissionButton: SidebarHoverButton
    /// Right of the copy button while Replace on Page has the page's prices in another currency,
    /// shown as the permission icon is, hovered or not; its panel comes out of it.
    let currencyButton: SidebarHoverButton
    /// Where developer mode's buttons start while its bar shows here.
    var developerControlsMinX: CGFloat? { didSet { if developerControlsMinX != oldValue { needsLayout = true } } }
    var onOpenAddress: (() -> Void)?
    /// The icon of what the page asks for, nil when it isn't asking.
    var requestedPermission: (icon: String, title: String)? {
        didSet {
            guard requestedPermission?.icon != oldValue?.icon || requestedPermission?.title != oldValue?.title else { return }
            if let requestedPermission {
                permissionButton.image = TablerIcon.image(requestedPermission.icon, size: 16, description: requestedPermission.title)
                permissionButton.setAccessibilityLabel(requestedPermission.title)
            }
            popsPermission = oldValue == nil && requestedPermission != nil
            if requestedPermission != nil { stopPermissionLeaving() }
            else if oldValue != nil { permissionLeaves() }
            needsLayout = true; updateFieldControls(animated: true)
        }
    }
    /// A newly asked-for icon grows into its place, once laid out there, as it fades in.
    private var popsPermission = false
    /// The currency Replace on Page has the page's prices in, nil while they're the page's own.
    var replacedCurrency: String? { replacedCurrencyCode }
    private var replacedCurrencyCode: String?
    /// Shows `code`'s icon, or takes it away; growing in and shrinking away, unless the bar is
    /// changing pages, when it just comes or goes with the rest.
    func setReplacedCurrency(_ code: String?, animated: Bool) {
        let old = replacedCurrencyCode
        guard code != old else { return }
        replacedCurrencyCode = code
        if let code { currencyButton.setHoverHint("Prices in \(code)"); currencyButton.setAccessibilityLabel("Prices in \(code)") }
        popsCurrency = animated && old == nil && code != nil
        if code != nil { stopCurrencyLeaving() }
        else if animated { currencyLeaving = leave(currencyButton) { [weak self] in
            guard let self, self.currencyLeaving else { return }
            self.stopCurrencyLeaving(); self.needsLayout = true; self.updateFieldControls(animated: false)
        } }
        needsLayout = true; updateFieldControls(animated: animated)
    }
    private var popsCurrency = false, currencyLeaving = false
    private func stopCurrencyLeaving() {
        currencyLeaving = false
        currencyButton.layer?.removeAnimation(forKey: Self.leaveKey)
    }
    enum PermissionMotion {
        /// From this size, on a quick spring that barely overshoots; the prompt comes out of it
        /// `promptDelay` in, as it nears its size.
        static let scale: CGFloat = 0.4, stiffness: CGFloat = 420, damping: CGFloat = 30, promptDelay = 0.12
        /// Going, once its prompt has gone back into it, which looks to take `leaveLead`.
        static let leaveDuration = 0.16, leaveLead = 0.15
    }
    /// Answered, the icon shrinks as it fades, quickly, and keeps its place until it's gone.
    private var permissionLeaving = false
    private static let leaveKey = "Rise.PermissionLeave"
    private func permissionLeaves() {
        permissionLeaving = leave(permissionButton) { [weak self] in
            guard let self, self.permissionLeaving else { return }
            self.stopPermissionLeaving(); self.needsLayout = true; self.updateFieldControls(animated: false)
        }
    }
    /// Shrinks `button` as it fades, quickly; `done` once it has gone. Whether it's going at all.
    private func leave(_ button: ChromeButton, then done: @escaping () -> Void) -> Bool {
        guard window != nil, !button.isHidden, button.alphaValue > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = button.layer else { return false }
        let middle = CGPoint(x: button.bounds.midX, y: button.bounds.midY), scale = PermissionMotion.scale
        let shrink = CABasicAnimation(keyPath: "transform"); shrink.fromValue = CATransform3DIdentity
        shrink.toValue = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(middle.x, middle.y, 0), scale, scale, 1), -middle.x, -middle.y, 0)
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [shrink, fade]
        group.duration = PermissionMotion.leaveDuration; group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.6)
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        layer.add(group, forKey: Self.leaveKey)
        CATransaction.commit()
        return true
    }
    private func stopPermissionLeaving() {
        permissionLeaving = false
        permissionButton.layer?.removeAnimation(forKey: Self.leaveKey)
    }
    /// Grows `button` into its place on a quick spring that barely overshoots, as it fades in.
    private func popIn(_ button: ChromeButton) {
        guard window != nil, !button.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = button.layer else { return }
        let middle = CGPoint(x: button.bounds.midX, y: button.bounds.midY), scale = PermissionMotion.scale
        let grow = CASpringAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(middle.x, middle.y, 0), scale, scale, 1), -middle.x, -middle.y, 0)
        grow.toValue = CATransform3DIdentity
        grow.stiffness = PermissionMotion.stiffness; grow.damping = PermissionMotion.damping
        grow.duration = grow.settlingDuration; grow.fillMode = .backwards
        layer.add(grow, forKey: "Rise.PermissionPop")
    }
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
    /// The ink of what shows over developer mode's bar while it's more than half in.
    private var developerInk: Ink?
    private var shownInk: Ink { developerInk ?? ink }
    private(set) var isHovered = false
    private var url: URL?, title = ""
    var pageZoom: CGFloat = 1 { didSet { if pageZoom != oldValue { needsLayout = true; updateFieldControls(animated: true) } } }
    var showsZoom: Bool { url != nil && !PageZoom.isActual(pageZoom) }

    init(copy: @escaping () -> Void, settings: @escaping () -> Void, zoom: @escaping () -> Void, permission: @escaping () -> Void = {},
         currency: @escaping () -> Void = {}) {
        copyButton = SidebarCopyButton(action: copy)
        settingsButton = SidebarHoverButton(symbol: "slider.horizontal.3", size: 14, title: "Site controls", action: settings)
        settingsButton.setHoverHint("Site controls")
        settingsButton.image = TablerIcon.image(TablerIcon.adjustments, size: 16, description: "Site controls")
        zoomButton = SidebarHoverButton(symbol: "plus.magnifyingglass", size: 14, title: "Zoom", action: zoom)
        zoomButton.image = TablerIcon.image(TablerIcon.zoomIn, size: 16, description: "Zoom")
        permissionButton = SidebarHoverButton(symbol: "camera", size: 14, title: "Permission request", action: permission)
        currencyButton = SidebarHoverButton(symbol: "dollarsign.circle", size: 14, title: "Prices replaced", action: currency)
        currencyButton.image = TablerIcon.coinsImage(size: 16)
        super.init(frame: .zero)
        wantsLayer = true
        field.cornerRadius = Metrics.fieldRadius; field.cornerCurve = .continuous; field.opacity = 0
        layer?.addSublayer(field); layer?.addSublayer(hairline); layer?.addSublayer(progressLine)
        progressLine.isHidden = true
        text.font = Metrics.font; text.lineBreakMode = .byTruncatingTail; text.cell?.usesSingleLineMode = true
        text.wantsLayer = true
        addSubview(text); addSubview(addressHost)
        for button in fieldControls { addressHost.addSubview(button); button.alphaValue = 0 }
        // Over the field, so it stays while developer mode's bar takes the field's place.
        addSubview(permissionButton); permissionButton.alphaValue = 0
        addSubview(currencyButton); currencyButton.alphaValue = 0
        setColor(.white, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The page it's over: its address and title.
    func show(url: URL?, title: String) {
        let url = url?.absoluteString == "about:blank" ? nil : url
        guard url != self.url || title != self.title else { return }
        if url != self.url { hideNotice() }
        self.url = url; self.title = title
        // Read the full address through accessibility without opening the palette or copying it.
        copyButton.setAccessibilityValue(url?.absoluteString ?? "")
        updateText(); updateFieldControls(animated: false); needsLayout = true
    }

    /// The page's colour under its top edge, which the bar takes, its contents light or dark to suit.
    func setColor(_ color: NSColor, animated: Bool) {
        let next = color.usingColorSpace(.sRGB) ?? color
        guard next != self.color || layer?.backgroundColor == nil else { return }
        let from = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        self.color = next; ink = Ink.on(next)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = background
        CATransaction.commit()
        if animated, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let from {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from; fade.toValue = background; fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(fade, forKey: "color")
        }
        applyInk()
    }

    private func applyInk() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hairline.backgroundColor = ink.hairline.cgColor; field.backgroundColor = ink.field.cgColor
        CATransaction.commit()
        // The buttons that stay over developer mode's bar take its ink.
        let staying: [ChromeButton] = navigation + extensionButtons + [permissionButton, currencyButton], field: [ChromeButton] = fieldControls
        for (buttons, ink) in [(staying, shownInk), (field, ink)] {
            for button in buttons {
                if button.contentTintColor != ink.strong { button.contentTintColor = ink.strong }
                button.hoverColor = ink.hover
            }
        }
        for case let notice as BarNotice in subviews { notice.tint(noticeInk) }
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

    /// Where the field ends: before the row of the page's buttons and the pinned extensions.
    private var fieldMaxX: CGFloat {
        guard rowCount > 0 else { return bounds.width-12 }
        return rowCentre(0)-Metrics.fieldEndGap
    }
    private var rowCount: Int { pageButtons.count+extensionButtons.count }
    private func rowCentre(_ index: Int) -> CGFloat {
        bounds.width-Metrics.extensionInset-Metrics.extensionStride*CGFloat(rowCount-1-index)
    }
    private func extensionCentre(_ index: Int) -> CGFloat { rowCentre(pageButtons.count+index) }
    var fieldRect: NSRect {
        NSRect(x: Metrics.fieldX-leadingRoom, y: Metrics.midY-Metrics.fieldHeight/2, width: max(0, fieldMaxX-Metrics.fieldX+leadingRoom), height: Metrics.fieldHeight)
    }
    private var fieldControls: [SidebarHoverButton] { [zoomButton, copyButton, settingsButton] }
    private var showsPermission: Bool { url != nil && (requestedPermission != nil || permissionLeaving) }
    private var showsCurrency: Bool { url != nil && (replacedCurrencyCode != nil || currencyLeaving) }
    /// The page's buttons, as the extensions' are: what it's zoomed to and asking for while it
    /// is, its controls and its address's copy, for any page with an address.
    private var pageButtons: [SidebarHoverButton] {
        guard url != nil else { return [] }
        return (showsZoom ? [zoomButton] : []) + (showsPermission ? [permissionButton] : []) + [settingsButton, copyButton]
            + (showsCurrency ? [currencyButton] : [])
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2, mid = Metrics.midY
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hairline.frame = NSRect(x: 0, y: bounds.height-1/scale, width: bounds.width, height: 1/scale)
        field.frame = fieldRect
        CATransaction.commit()
        addressHost.frame = bounds
        layoutProgress()
        for (button, centre) in zip(navigation, navigationCentres) {
            button.frame = NSRect(x: centre-14, y: mid-14, width: 28, height: 28)
        }
        layoutExtensions()
        for (index, button) in pageButtons.enumerated() {
            button.frame = NSRect(x: rowCentre(index)-14, y: mid-14, width: 28, height: 28)
        }
        zoomButton.isHidden = !showsZoom; permissionButton.isHidden = !showsPermission; currencyButton.isHidden = !showsCurrency
        if developerProgress > 0.5, let start = developerControlsMinX {
            // Leftwards from developer mode's buttons, the prices' icon nearest them.
            let staying = (showsPermission ? [permissionButton] : []) + (showsCurrency ? [currencyButton] : [])
            for (index, button) in staying.reversed().enumerated() {
                button.frame = NSRect(x: start-8-28-Metrics.extensionStride*CGFloat(index), y: mid-14, width: 28, height: 28)
            }
        }
        if popsPermission { popsPermission = false; popIn(permissionButton) }
        if popsCurrency { popsCurrency = false; popIn(currencyButton) }
        let textEnd = fieldRect.maxX-8
        let line = ceil(text.intrinsicContentSize.height)
        let textX = Metrics.textX-Metrics.textInset-leadingRoom
        text.frame = NSRect(x: textX, y: round((mid-line/2)*2)/2, width: max(0, textEnd-textX), height: line)
        for case let notice as BarNotice in subviews { place(notice) }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Saying something in the address's place

    /// Copying the address or a link, switching full screen, starring a repository and saving a
    /// capture say so where the address is, as Dia does,
    /// measured from it: the address rises 10 pt as it fades, quickening, and the words rise 9 pt
    /// into its place from below as they fade in, slowing; then they go the same way and it comes
    /// back. Something else said while they show takes their place the same way, the whole row.
    enum Notice {
        static let rise: CGFloat = 10, entry: CGFloat = 9
        static let exitDuration = 0.13, entryDelay = 0.11, entryDuration = 0.19
        /// From the words coming to their starting to go.
        static let hold = 1.25
    }
    /// What the bar says in the address's place, while it does.
    private(set) var notice: BarNotice?
    var isShowingCopied: Bool { notice?.text == BarNotice.copied }
    private var noticeTimer: Timer?
    func showCopied() { showNotice(BarNotice.copied, image: BarNotice.linkImage) }
    /// Saying the same again while it shows holds it longer, and so does the pointer on its link.
    /// `nudge` moves the words and icon that far right of where notices sit.
    /// `dotted` is a word among `words` to show a link's dots under, though it's no link.
    func showNotice(_ words: String, image: NSImage, link: BarNotice.Link? = nil, action: BarNotice.Link? = nil, hold: TimeInterval = Notice.hold, nudge: CGFloat = 0, dotted: String? = nil) {
        holdNotice(hold)
        // Two saves can say the same thing while referring to different items.
        guard link != nil || action != nil || notice?.text != BarNotice.text(words, link: link) else { return }
        // In the font of the address it takes the place of.
        let next = BarNotice(words, image: image, link: link, action: action,
                             font: showsDeveloperAddress ? IoskeleyMonoFont.developerAddress : Metrics.font)
        next.nudge = nudge; next.dottedWords = dotted
        next.tint(noticeInk); next.alphaValue = 0
        addSubview(next); place(next)
        let old: NSView = notice ?? address
        notice = next
        exchange(old, for: next)
    }
    private func holdNotice(_ hold: TimeInterval) {
        noticeTimer?.invalidate()
        let timer = Timer(timeInterval: hold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.notice?.actionLabel == nil, self.notice?.isLinkHovered == true { self.holdNotice(0.4) } else { self.hideNotice() }
            }
        }
        noticeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func hideNotice() {
        noticeTimer?.invalidate(); noticeTimer = nil
        guard let notice else { return }
        self.notice = nil
        exchange(notice, for: address)
    }
    /// A notice's colour: over developer mode's bar, that of the address it takes the place of.
    private var noticeInk: NSColor { showsDeveloperAddress ? (developerAddress as? NSTextField)?.textColor ?? shownInk.strong : shownInk.strong }
    /// What a notice takes the place of: the address, or developer mode's while it's on.
    private var address: NSView { showsDeveloperAddress ? developerAddress ?? text : text }
    private func place(_ notice: BarNotice) {
        let textX = Metrics.textX-leadingRoom
        let x = textX-1-BarNotice.inkStart+notice.nudge
        let end = fieldRect.maxX
        notice.frame = NSRect(x: x, y: 0, width: min(notice.width, max(0, end-8-x)), height: bounds.height)
    }
    private func exchange(_ old: NSView, for new: NSView) {
        let from = old.layer?.presentation()?.opacity ?? 1
        old.alphaValue = 0; new.alphaValue = 1
        // Words that have gone are done with.
        let done = { if let old = old as? BarNotice, old !== self.notice { old.removeFromSuperview() } }
        guard window != nil, let oldLayer = old.layer, let newLayer = new.layer else { done(); return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Up the screen, in the bar's flipped layers.
        let up: CGFloat = oldLayer.superlayer?.contentsAreFlipped() == false ? 1 : -1
        let now = CACurrentMediaTime()
        func move(_ layer: CALayer, opacity: (Float, Float), y: (CGFloat, CGFloat), begin: CFTimeInterval, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = opacity.0; fade.toValue = opacity.1
            let rise = CABasicAnimation(keyPath: "transform.translation.y"); rise.fromValue = still ? 0 : y.0; rise.toValue = still ? 0 : y.1
            let group = CAAnimationGroup(); group.animations = [fade, rise]
            group.beginTime = begin; group.duration = duration; group.timingFunction = timing; group.fillMode = .backwards
            layer.add(group, forKey: "notice")
        }
        move(oldLayer, opacity: (from, 0), y: (0, up*Notice.rise), begin: now, duration: Notice.exitDuration,
             timing: CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.6))
        move(newLayer, opacity: (0, 1), y: (-up*Notice.entry, 0), begin: now+Notice.entryDelay, duration: Notice.entryDuration,
             timing: CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1))
        DispatchQueue.main.asyncAfter(deadline: .now()+Notice.exitDuration+0.05) { done() }
    }

    // MARK: Becoming developer mode's bar

    /// Developer mode's address, in its bar under this one, which takes the address's place.
    weak var developerAddress: NSView?
    private(set) var showsDeveloperAddress = false
    /// How far the bar has become developer mode's, which is under it: its colour and hairline
    /// ease away and its field gives way, and the buttons that stay take developer mode's ink.
    /// Developer mode's bar takes the clicks they don't. Its address, or what a notice says in its
    /// place, is exchanged for developer mode's as a notice is, at once when it isn't moving.
    private(set) var developerProgress: CGFloat = 0
    func setDeveloper(_ progress: CGFloat, enabled: Bool, surface: NSColor) {
        if enabled != showsDeveloperAddress {
            let old = notice ?? address
            showsDeveloperAddress = enabled
            noticeTimer?.invalidate(); noticeTimer = nil; notice = nil
            if progress != (enabled ? 1 : 0) { exchange(old, for: address) } else {
                for view in [old, address] { view.layer?.removeAnimation(forKey: "notice") }
                old.alphaValue = 0; address.alphaValue = 1
                if old is BarNotice { old.removeFromSuperview() }
            }
        }
        let ink = progress > 0.5 ? Ink.on(surface) : nil
        guard progress != developerProgress || ink?.strong != developerInk?.strong else { return }
        developerProgress = progress; developerInk = ink
        if progress > 0 { setHovered(false) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: "color"); layer?.backgroundColor = background
        hairline.opacity = Float(DeveloperModeMotion.covering(progress))
        CATransaction.commit()
        addressHost.alphaValue = DeveloperModeMotion.leaving(progress)
        applyInk()
    }
    private var background: CGColor { color.withAlphaComponent(color.alphaComponent*DeveloperModeMotion.covering(developerProgress)).cgColor }
    /// Where developer mode's buttons can run to: up to the pinned extensions.
    var developerControlsMaxX: CGFloat { extensionButtons.isEmpty ? bounds.width : extensionCentre(0)-14 }
    lazy var fullscreenSlide = FullscreenNavigationSlide(view: self)
    private(set) var isFullscreenHidden = false
    func setFullscreenHidden(_ hidden: Bool, animated: Bool) {
        if hidden != isFullscreenHidden {
            isFullscreenHidden = hidden
            setAccessibilityHidden(hidden)
            if hidden {
                setHovered(false)
                (navigation+extensionButtons+fieldControls+[permissionButton, currencyButton]).forEach { $0.hoverHint?.setHovered(false) }
            }
        }
        fullscreenSlide.setHidden(hidden, animated: animated)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isFullscreenHidden else { return nil }
        let hit = super.hitTest(point)
        guard developerProgress > 0 else { return hit }
        return (navigation+extensionButtons+[permissionButton, currencyButton]).contains { hit?.isDescendant(of: $0) == true } ? hit : nil
    }

    // MARK: Reordering the pinned extensions

    /// A pinned extension dragged with Control held moves along the row as a pinned tab's tile
    /// moves in its grid: it stays under the pointer, the others spring aside on the tiles' spring
    /// without a bounce to make room, with a tick as it crosses each, and let go, it springs into
    /// its place with the tiles' slight bounce. The new order is kept then.
    var onReorderExtensions: (([String]) -> Void)?
    var crossingClick: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    /// The extension in hand: where the pointer holds it from its left edge, and where that is.
    private var heldExtension: (button: SidebarExtensionButton, grab: CGFloat, x: CGFloat)?
    var isDraggingExtension: Bool { heldExtension != nil }
    /// Extensions on their way to their places, by their left edges.
    private var extensionMotion: [ObjectIdentifier: MotionSpring] = [:]
    private var extensionLink: CADisplayLink?, extensionTick: CFTimeInterval?
    private func layoutExtensions() {
        let mid = Metrics.midY
        for (index, button) in extensionButtons.enumerated() {
            let place = extensionCentre(index)-14, key = ObjectIdentifier(button)
            var x = place
            if let held = heldExtension, held.button === button { x = held.x }
            else if var spring = extensionMotion[key] { spring.target = place; extensionMotion[key] = spring; x = spring.value }
            button.frame = NSRect(x: x, y: mid-14, width: 28, height: 28)
        }
    }
    func beginExtensionDrag(_ button: SidebarExtensionButton, event: NSEvent) {
        guard heldExtension == nil, extensionButtons.contains(button) else { return }
        let x = convert(event.locationInWindow, from: nil).x
        // Picked up again on its way into its place, it goes on from where it's shown.
        extensionMotion[ObjectIdentifier(button)] = nil
        heldExtension = (button, x-button.frame.minX, button.frame.minX)
        button.holdsHover = true; button.layer?.zPosition = 1
    }
    func moveExtensionDrag(_ event: NSEvent) {
        guard var held = heldExtension, let index = extensionButtons.firstIndex(of: held.button) else { return }
        let first = extensionCentre(0)-14, last = extensionCentre(extensionButtons.count-1)-14
        held.x = min(max(convert(event.locationInWindow, from: nil).x-held.grab, first), last)
        heldExtension = held
        let slot = min(extensionButtons.count-1, max(0, Int(((held.x-first)/Metrics.extensionStride).rounded())))
        if slot != index {
            var order = extensionButtons
            order.remove(at: index); order.insert(held.button, at: slot)
            for button in extensionButtons where button !== held.button { spring(button, bouncy: false) }
            extensionButtons = order
            crossingClick()
        }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func endExtensionDrag() {
        guard let held = heldExtension else { return }
        heldExtension = nil
        held.button.holdsHover = false
        spring(held.button, bouncy: true)
        needsLayout = true; layoutSubtreeIfNeeded()
        onReorderExtensions?(extensionButtons.map(\.extensionID))
    }
    /// From where `button` is now to its place, on the pinned tiles' spring.
    private func spring(_ button: SidebarExtensionButton, bouncy: Bool) {
        let key = ObjectIdentifier(button)
        guard extensionMotion[key] == nil, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if extensionMotion[key] == nil { button.layer?.zPosition = 0 }
            return
        }
        var spring = MotionSpring(button.frame.minX)
        spring.configure(response: PinnedLayout.response, bounce: bouncy ? PinnedLayout.bounce : 0)
        extensionMotion[key] = spring
        guard extensionLink == nil else { return }
        extensionTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(stepExtensions(_:)))
        link.add(to: .main, forMode: .common); extensionLink = link
    }
    @objc private func stepExtensions(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(extensionTick ?? now)); extensionTick = now
        for (key, var spring) in extensionMotion {
            spring.step(dt)
            extensionMotion[key] = spring.isResting(within: 0.05) ? nil : spring
        }
        for button in extensionButtons where extensionMotion[ObjectIdentifier(button)] == nil && heldExtension?.button !== button {
            button.layer?.zPosition = 0
        }
        needsLayout = true; layoutSubtreeIfNeeded()
        if extensionMotion.isEmpty { extensionLink?.invalidate(); extensionLink = nil; extensionTick = nil }
    }

    // MARK: Hovering the address

    /// Under a Peek: AppKit shows a view's cursor wherever it is, even covered, so a bar the Peek's
    /// card covers sets none, nor hovers, leaving the Peek's own bar its cursor.
    var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            if isCovered { setHovered(false) }
            window?.invalidateCursorRects(for: self)
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isCovered, url != nil, developerProgress == 0, !isFullscreenHidden, !fieldRect.isEmpty else { return }
        addCursorRect(fieldRect, cursor: .iBeam)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        setHovered(!isCovered && hoverArea(contains: convert(event.locationInWindow, from: nil)) && isFrontmost(at: event.locationInWindow))
    }
    /// The address, and the page's buttons out past its end to the copy button, which show
    /// while the pointer's on either and fade as it leaves, as they did in the field.
    private func hoverArea(contains point: NSPoint) -> Bool {
        if fieldRect.contains(point) { return true }
        // Up to the copy button, or the prices' icon past it, which shows them as hovering them does.
        let end = showsCurrency ? max(copyButton.frame.maxX, currencyButton.frame.maxX) : copyButton.frame.maxX
        guard url != nil, end > fieldRect.maxX else { return false }
        return NSRect(x: fieldRect.maxX, y: 0, width: end-fieldRect.maxX, height: bounds.height).contains(point)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    /// While the site controls are open from it, the address stays as if hovered, its buttons
    /// showing and the settings button lit, wherever the pointer goes.
    var holdsHover = false {
        didSet {
            guard holdsHover != oldValue else { return }
            settingsButton.holdsHover = holdsHover
            // The pointer may have left while the popover covered the bar.
            if !holdsHover, let window {
                let point = window.mouseLocationOutsideOfEventStream
                pointerHovered = hoverArea(contains: convert(point, from: nil)) && isFrontmost(at: point)
            }
            setHovered(pointerHovered)
        }
    }
    private var pointerHovered = false
    func setHovered(_ hovered: Bool) {
        pointerHovered = hovered
        let hovered = (hovered || holdsHover) && url != nil && developerProgress == 0
        guard hovered != isHovered else { return }
        isHovered = hovered
        fade(field, to: hovered ? 1 : 0)
        updateText(); updateFieldControls(animated: true); needsLayout = true
    }
    private func updateFieldControls(animated: Bool) {
        for button in fieldControls + [permissionButton, currencyButton] {
            let on = url != nil && (isHovered && button !== currencyButton || (button === zoomButton && showsZoom)
                || (button === permissionButton && showsPermission) || (button === currencyButton && showsCurrency))
            // A leaving icon shows until it has gone, but can't be pressed.
            button.allowsInteraction = on && !(button === permissionButton && permissionLeaving) && !(button === currencyButton && currencyLeaving)
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
    /// a title bar would. A Control-click on the address is a right-click.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self); return }
        if fieldRect.contains(convert(event.locationInWindow, from: nil)) { onOpenAddress?() } else { window?.performDrag(with: event) }
    }
    /// What right-clicking the address offers, for this bar's page.
    var addressMenu: ((PlainNavBar) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard url != nil, developerProgress == 0, fieldRect.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        return addressMenu?(self)
    }
}

/// Words in the address's place, after a glyph, and perhaps a link after them: "Copied Current
/// URL" with a link, say, or "Saved to Downloads" with the folder's name to click. The glyph's
/// ink starts a point before the address's, 12 pt across, and the words' 7 pt after it.
@MainActor final class BarNotice: FlippedView {
    struct Link { let text: String; let perform: () -> Void }
    static let copied = "Copied Current URL"
    /// The copy button's confirmation glyph: the link with its marks around it.
    /// How far right of the usual place this one sits.
    var nudge: CGFloat = 0
    var dottedWords: String? {
        get { words.dotted }
        set { words.dotted = newValue; needsLayout = true }
    }
    static let linkImage = TablerIcon.image(TablerIcon.linkCopied, size: 16, description: nil)
    /// The arrows of the full screen notices, drawn as heavy as the link.
    static let fullScreenImage = symbol("arrow.up.left.and.arrow.down.right")
    static let starImage = TablerIcon.image(TablerIcon.star, size: 14, description: nil)
    static let commandImage = symbol("command")
    static let unpinImage = symbol("pin.slash"), resetImage = symbol("arrow.counterclockwise")
    static let warningImage = TablerIcon.image(TablerIcon.alertTriangle, size: 14, description: nil)
    static let photoImage = symbol("photo"), documentImage = symbol("doc.richtext")
    static let calendarImage = symbol("calendar.badge.checkmark"), reminderImage = symbol("checklist.checked")
    /// macOS's small spinner in the glyph's place, in the bar's ink, for something under way.
    static let spinnerImage = NSImage(size: NSSize(width: 16, height: 16))
    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)) ?? linkImage
    }
    /// Where the glyph's ink starts in its 16 pt frame.
    static let inkStart: CGFloat = 3
    /// The middle of an image's ink, up and down, from its top: glyphs draw off their frame's
    /// middle, each by its own amount, so it's measured rather than set for each.
    static func inkMidFromTop(_ image: NSImage) -> CGFloat {
        let key = ObjectIdentifier(image)
        if let known = inkMids[key] { return known }
        let scale: CGFloat = 4, size = image.size
        let width = max(1, Int(ceil(size.width*scale))), height = max(1, Int(ceil(size.height*scale)))
        var mid = size.height/2
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            NSGraphicsContext.restoreGraphicsState()
            var top: Int?, bottom: Int?
            if let data = rep.bitmapData {
                for y in 0..<height where (0..<width).contains(where: { data[y*rep.bytesPerRow+$0*4+3] > 40 }) {
                    if top == nil { top = y }; bottom = y
                }
            }
            if let top, let bottom { mid = (CGFloat(top)+CGFloat(bottom)+1)/2/scale }
        }
        inkMids[key] = mid
        return mid
    }
    private static var inkMids: [ObjectIdentifier: CGFloat] = [:]
    private let image: NSImage
    static func text(_ words: String, link: Link?) -> String { link.map { "\(words) \($0.text)" } ?? words }
    private let icon = NSImageView()
    private var spinner: SpinnerView?
    private let words: PlainNavBarText
    private(set) var linkLabel: BarLinkLabel?
    private(set) var actionLabel: BarLinkLabel?
    let text: String
    let font: NSFont
    init(_ text: String, image: NSImage, link: Link? = nil, action: Link? = nil, font: NSFont = PlainNavBar.Metrics.font) {
        words = PlainNavBarText(labelWithString: text)
        self.text = Self.text(text, link: link)
        self.image = image
        self.font = font
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleNone
        if image === Self.spinnerImage { let spinner = SpinnerView(); self.spinner = spinner; icon.addSubview(spinner) } else { icon.image = image }
        words.font = font
        words.usesSingleLineMode = true; words.cell?.wraps = false
        addSubview(icon); addSubview(words)
        if let link {
            let label = BarLinkLabel(link.text, font: font, perform: link.perform)
            linkLabel = label; addSubview(label)
        }
        if let action {
            let label = BarLinkLabel(action.text, font: font, perform: action.perform)
            actionLabel = label; addSubview(label)
        }
        setAccessibilityElement(link == nil && action == nil); setAccessibilityRole(.staticText); setAccessibilityLabel(self.text)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Only its link takes clicks, and only while it shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0 else { return nil }
        let local = convert(point, from: superview)
        return [linkLabel, actionLabel].compactMap { $0 }.first { $0.frame.contains(local) }
    }
    var isLinkHovered: Bool { linkLabel?.isHovered == true || actionLabel?.isHovered == true }
    func tint(_ color: NSColor) { icon.contentTintColor = color; spinner?.color = color; words.textColor = color; linkLabel?.ink = color; actionLabel?.ink = color }
    private var wordsX: CGFloat { Self.inkStart+19-PlainNavBar.Metrics.textInset }
    /// The link a space after the words: both labels' margins are the same, so the words' own
    /// width and a space's from where they start.
    private var linkX: CGFloat {
        wordsX+((words.stringValue+" ") as NSString).size(withAttributes: [.font: font]).width
    }
    var width: CGFloat {
        let main = linkLabel.map { linkX+$0.fittingWidth } ?? wordsX+ceil(words.intrinsicContentSize.width)+4
        return main+(actionLabel.map { 12+$0.fittingWidth } ?? 0)
    }
    override func layout() {
        super.layout()
        let mid = PlainNavBar.Metrics.midY, line = ceil(words.intrinsicContentSize.height)
        // On the baseline of the address it replaces: developer mode's centres its capitals, which
        // in its font isn't where centring the line would put them. A label draws its baseline
        // under its font's ascent and leading, rounded up, whatever its own offset reports.
        let y = font == PlainNavBar.Metrics.font ? round((mid-line/2)*2)/2
            : DeveloperAddressCell.baseline(of: font, middle: mid)-ceil(font.ascender+font.leading)
        // Level with the reload glyph's ink, whatever the glyph.
        let level: CGFloat = {
            guard let bar = superview as? PlainNavBar, let reload = bar.navigation.compactMap({ $0 as? ReloadButton }).first,
                  reload.superview != nil else { return mid }
            return convert(NSPoint(x: 0, y: reload.inkMidY), from: reload).y
        }()
        if spinner != nil {
            icon.frame = NSRect(x: 0, y: level-8, width: 16, height: 16)
        } else {
            let height = image.size.height
            // On a whole pixel, so the glyph stays crisp.
            let scale = window?.backingScaleFactor ?? 2
            icon.frame = NSRect(x: 0, y: round((level-Self.inkMidFromTop(image))*scale)/scale, width: 16, height: height)
        }
        spinner?.frame = NSRect(x: 2, y: 2, width: 12, height: 12)
        let actionWidth = actionLabel?.fittingWidth ?? 0
        let mainEnd = max(wordsX, bounds.width-(actionLabel == nil ? 0 : actionWidth+12))
        // With dots, a little taller than the line, as a link is.
        words.frame = NSRect(x: wordsX, y: y, width: min(ceil(words.intrinsicContentSize.width)+4, max(0, mainEnd-wordsX)), height: line+(words.dotted == nil ? 0 : 2))
        // A little taller than the line, for the dots under it.
        linkLabel?.frame = NSRect(x: linkX, y: y,
                                  width: min(linkLabel?.fittingWidth ?? 0, max(0, mainEnd-linkX)), height: line+2)
        actionLabel?.frame = NSRect(x: max(wordsX, bounds.width-actionWidth), y: y, width: actionWidth, height: line+2)
    }
}

/// A notice's link in the bar: in the bar's ink, with a row of faint round dots under it that
/// darken under the pointer, a hand cursor, and a click. The words before it share its ink, so
/// the dots say which it is on any page's colour.
@MainActor final class BarLinkLabel: NSTextField {
    private let perform: () -> Void
    var ink = NSColor.labelColor { didSet { textColor = ink; needsDisplay = true } }
    private(set) var isHovered = false { didSet { needsDisplay = true } }
    init(_ text: String, font: NSFont = PlainNavBar.Metrics.font, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        stringValue = text; self.font = font
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        usesSingleLineMode = true; cell?.wraps = false; cell?.isScrollable = false
        lineBreakMode = .byTruncatingTail
        setAccessibilityRole(.link)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// NSTextField's intrinsic width can round down its last glyph. Include its cell's two-point
    /// margins and a spare pixel, so Calendar/Reminders are fully drawn at either display scale.
    var fittingWidth: CGFloat {
        ceil((stringValue as NSString).size(withAttributes: [.font: font ?? PlainNavBar.Metrics.font]).width)+6
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let font, let cell else { return }
        let width = min(ceil((stringValue as NSString).size(withAttributes: [.font: font]).width), max(0, bounds.width-4))
        Self.drawDots(under: cell.titleRect(forBounds: bounds), flipped: isFlipped, font: font, from: 0, width: width, ink: ink.withAlphaComponent(isHovered ? 0.7 : 0.35))
    }
    /// The row of dots under `width` of a label's text, starting `offset` along it.
    static func drawDots(under text: NSRect, flipped: Bool, font: NSFont, from offset: CGFloat, width: CGFloat, ink: NSColor) {
        let baseline = flipped ? text.minY+font.ascender+font.leading : text.maxY-font.ascender-font.leading
        let y = baseline + (flipped ? 1 : -1)*dotDrop
        let (size, step) = (dotSize, dotStep)
        ink.setFill()
        // Label cells pad their text by 2 pt on each side; the dots start two points in from the
        // word's left and run to its end, the row a pixel left of that.
        let start = text.minX + 2 - dotShift + offset, end = start + width
        var x = start + 2 + size/2
        while x <= end - size/2 {
            NSBezierPath(ovalIn: NSRect(x: x-size/2, y: y-size/2, width: size, height: size)).fill()
            x += step
        }
    }
    /// Round dots a little below where an underline would sit: AppKit's dotted underline draws
    /// dashes at this size.
    static let dotSize: CGFloat = 1.25, dotStep: CGFloat = 2.5, dotDrop: CGFloat = 3, dotShift: CGFloat = 0.5
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func cursorUpdate(with event: NSEvent) {
        if (superview?.superview as? PlainNavBar ?? superview as? PlainNavBar)?.isCovered == true { NSCursor.arrow.set() } else { NSCursor.pointingHand.set() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { perform() }
    }
    override func accessibilityPerformPress() -> Bool { perform(); return true }
}

/// The address, which leaves its clicks to the bar.
final class PlainNavBarText: NSTextField {
    /// Words in it to show a link's dots under, though they're no link.
    var dotted: String? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let dotted, let font, let cell, let range = stringValue.range(of: dotted) else { return }
        let measure = { (words: String) in (words as NSString).size(withAttributes: [.font: font]).width }
        BarLinkLabel.drawDots(under: cell.titleRect(forBounds: bounds), flipped: isFlipped, font: font,
                              from: measure(String(stringValue[..<range.lowerBound])), width: ceil(measure(dotted)),
                              ink: (textColor ?? .labelColor).withAlphaComponent(0.35))
    }
}

/// Views together so they can fade and move as one; its own clicks go to what's behind it.
final class ContentHost: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
