import AppKit

/// The border, arrow, material and outer shadow belong to NSPopover.
final class PopoverContentView: FlippedView {}

enum SiteControlsLayout {
    static let scale: CGFloat = 0.96
}

/// Shared Arc-style action bezel used by settings and copy confirmation.
class PopoverActionButton: ChromeButton {
    /// The share symbol's box sits low in its frame, so it's drawn higher: a little in the
    /// notices' small buttons, a little more in the settings popover's wide ones.
    static let shareSymbol = "square.and.arrow.up", shareLift: CGFloat = 1.5, popoverShareLift: CGFloat = 2
    init(symbol: String, size: CGFloat = 18, scale: CGFloat = 1, title: String, theme: RiseTheme, shareLift: CGFloat = PopoverActionButton.shareLift, action: @escaping () -> Void) {
        super.init(symbol: symbol, size: size*scale, title: title, action: action)
        if symbol == Self.shareSymbol { image = image?.raised(by: shareLift*scale) }
        contentTintColor = theme.text
        baseColor = theme == .dark ? NSColor(hex: 0x3D3D3D) : .white.withAlphaComponent(0.75)
        layer?.backgroundColor = baseColor.cgColor
        layer?.cornerRadius = 8*scale; layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.65*scale
        layer?.borderColor = (theme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(theme == .dark ? 0.17 : 0.20).cgColor
        clipsToBounds = false; layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 1.5*scale; layer?.shadowOffset = NSSize(width: 0, height: -0.5*scale)
        // A shade off the resting bezel, rather than the tab list's much darker hover.
        hoverColor = theme == .dark ? NSColor(hex: 0x464646) : NSColor(hex: 0xF1F0EF)
    }
    /// The same button with a word on it in place of a symbol, such as the capture popover's.
    convenience init(label text: String, scale: CGFloat = 1, title: String, theme: RiseTheme, action: @escaping () -> Void) {
        self.init(symbol: "", scale: scale, title: title, theme: theme, action: action)
        image = nil; imagePosition = .noImage
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13*scale, weight: .semibold), .foregroundColor: theme.text,
            .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; return style }()])
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Block Ads in the site controls: a shield while ads are blocked on this site, with a slash drawn
/// across it while they aren't. It's one symbol that stays put, and the slash its own stroke over it, as
/// `shield` and `shield.slash` sit differently in their boxes, so swapping them moves the shield.
final class AdBlockButton: PopoverActionButton {
    /// Over the button, without taking its clicks.
    private final class Glyph: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    static let symbol = "shield"
    /// The slash, as `shield.slash` has it, in points at the size the button's symbol is drawn:
    /// its reach from the middle of the shield's ink, its stroke, and the gap each side of it.
    private static let reach: CGFloat = 7.5, stroke: CGFloat = 1.25, gap: CGFloat = 1.1
    /// The middle of the shield's ink in its 18 by 20 box, measured from the bottom left.
    private static let inkCenter = CGPoint(x: 8.25, y: 9.94)
    /// The same slashed shield still, as an image to tint, for anywhere it can't draw itself.
    /// `pointSize` is the symbol's; the slash keeps its proportions, in a `stroke` wide line.
    static func slashedShield(canvas: CGFloat, pointSize: CGFloat, weight: NSFont.Weight, stroke: CGFloat, description: String) -> NSImage {
        let symbol = NSImage(systemSymbolName: Self.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))!
        let ratio = pointSize/(17*SiteControlsLayout.scale)
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let middle = canvas/2
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: NSRect(x: middle-inkCenter.x*ratio, y: middle-inkCenter.y*ratio, width: symbol.size.width, height: symbol.size.height))
            let reach = Self.reach*ratio
            context.setLineCap(.round)
            context.move(to: CGPoint(x: middle-reach, y: middle+reach)); context.addLine(to: CGPoint(x: middle+reach, y: middle-reach))
            let line = context.path
            context.setBlendMode(.clear); context.setLineWidth(stroke+2*Self.gap*ratio); context.strokePath()
            context.setBlendMode(.normal); context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(stroke)
            if let line { context.addPath(line) }
            context.strokePath()
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = description
        return image
    }
    private let glyph = Glyph()
    private let shield = CALayer(), shieldCut = CAShapeLayer(), slash = CAShapeLayer()
    private let shieldImage: NSImage
    private(set) var isBlocking: Bool
    private static let response: Double = 0.22, bounce: Double = 0.45
    private var progress: MotionSpring
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    init(isBlocking: Bool, size: CGFloat, scale: CGFloat, theme: RiseTheme) {
        progress = MotionSpring(isBlocking ? 0 : 1)
        self.isBlocking = isBlocking
        let symbol = NSImage(systemSymbolName: Self.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: size*scale, weight: .regular))!
        let tint = theme.text
        shieldImage = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect); tint.set(); rect.fill(using: .sourceIn); return true
        }
        super.init(symbol: Self.symbol, size: size, scale: scale, title: "Block Ads", theme: theme, action: {})
        image = nil; title = ""
        glyph.wantsLayer = true
        glyph.frame.size = shieldImage.size
        shield.frame = CGRect(origin: .zero, size: shieldImage.size)
        shieldCut.frame = shield.bounds; shieldCut.fillRule = .evenOdd; shieldCut.fillColor = NSColor.black.cgColor
        shield.mask = shieldCut
        slash.frame = shield.bounds; slash.fillColor = nil; slash.strokeColor = tint.cgColor
        slash.lineWidth = Self.stroke; slash.lineCap = .round
        glyph.layer?.addSublayer(shield); glyph.layer?.addSublayer(slash)
        addSubview(glyph)
        render()
        setAccessibilityValue(isBlocking ? "On" : "Off")
    }
    required init?(coder: NSCoder) { fatalError() }
    private var slashStart: CGPoint { CGPoint(x: Self.inkCenter.x-Self.reach, y: Self.inkCenter.y+Self.reach) }
    private var slashEnd: CGPoint { CGPoint(x: Self.inkCenter.x+Self.reach, y: Self.inkCenter.y-Self.reach) }
    /// The slash as far along as `progress`, which passes 1 as it overshoots, with the shield cut
    /// away around it: the box, then a cut of the slash's width plus a gap each side, which even-odd
    /// filling leaves empty. It reaches only a gap ahead of the line's tip, so each gap in the shield
    /// opens as the line gets there.
    private func render() {
        let progress = max(0, self.progress.value)
        let tip = CGPoint(x: slashStart.x+(slashEnd.x-slashStart.x)*progress, y: slashStart.y+(slashEnd.y-slashStart.y)*progress)
        let line = CGMutablePath(), cut = CGMutablePath()
        cut.addRect(shield.bounds.insetBy(dx: -4, dy: -4))
        if progress > 0.001 {
            line.move(to: slashStart); line.addLine(to: tip)
            let half = Self.stroke/2+Self.gap, step = half/2.0.squareRoot()
            let start = CGPoint(x: slashStart.x-step, y: slashStart.y+step), end = CGPoint(x: tip.x+step, y: tip.y-step)
            cut.addLines(between: [CGPoint(x: start.x-step, y: start.y-step), CGPoint(x: start.x+step, y: start.y+step),
                                   CGPoint(x: end.x+step, y: end.y+step), CGPoint(x: end.x-step, y: end.y-step)])
            cut.closeSubpath()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        slash.path = line; shieldCut.path = cut
        CATransaction.commit()
    }
    private func settle() {
        link?.invalidate(); link = nil
        progress.settle(); render()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        progress.step(dt)
        if progress.isResting(within: 0.001) { settle() } else { render() }
    }
    var showsSlash: Bool { !isBlocking }
    func show(blocking: Bool) {
        guard blocking != isBlocking else { return }
        isBlocking = blocking
        setAccessibilityValue(blocking ? "On" : "Off")
        // Quick, and overshooting as it draws. Going away it can't: past nothing there's nothing to show.
        progress.configure(response: Self.response, bounce: blocking ? 0 : Self.bounce)
        progress.target = blocking ? 0 : 1
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { settle(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    /// In the middle, on whole pixels, wherever the button has been put.
    private func placeGlyph() {
        let size = glyph.frame.size
        let middle = NSRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
        glyph.frame.origin = window == nil ? middle.origin : backingAlignedRect(middle, options: .alignAllEdgesNearest).origin
        let scale = window?.backingScaleFactor ?? 2
        [shield, shieldCut, slash, glyph.layer].forEach { $0?.contentsScale = scale }
        shield.contents = shieldImage.layerContents(forContentsScale: scale)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); placeGlyph() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); placeGlyph(); if window == nil { settle() } }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); placeGlyph() }
    override var isEnabled: Bool { didSet { glyph.alphaValue = isEnabled ? 1 : 0.4 } }
    /// Dims while pressed, as the other buttons' images do.
    override func highlight(_ flag: Bool) { super.highlight(flag); glyph.alphaValue = flag ? 0.6 : 1 }
}

final class SiteSettingRow: NSButton {
    let name: NSTextField
    let detail: NSTextField
    let icon = NSImageView()
    private let perform: () -> Void
    override var isFlipped: Bool { true }
    init(title: String, subtitle: String, symbol: String, image: NSImage? = nil, active: Bool, checked: Bool? = nil, theme: RiseTheme, action: @escaping () -> Void) {
        perform = action
        let scale = SiteControlsLayout.scale
        name = label(title, size: 14*scale, weight: .semibold, color: theme.text)
        detail = label(subtitle, size: 13*scale, color: theme.muted)
        super.init(frame: .zero)
        isBordered = false; self.title = ""; target = self; self.action = #selector(invoke)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.cornerCurve = .continuous
        icon.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15*scale, weight: .semibold))
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .white; icon.wantsLayer = true; icon.layer?.cornerRadius = 16*scale
        icon.layer?.backgroundColor = NSColor(hex: active ? 0x915439 : theme == .dark ? 0x685957 : 0xD9C5BF).cgColor
        if let checked { state = checked ? .on : .off }
        [icon, name, detail].forEach(addSubview)
        setAccessibilityLabel(title); setAccessibilityValue(subtitle)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The developer tabs' hammer and Tabler's bell, filled to match the symbols beside them.
    static let hammer: NSImage = {
        let original = TablerIcon.image(LucideIcon.hammer, size: 17*SiteControlsLayout.scale, filled: true, centered: true)
        let shift: CGFloat = 0.65
        let image = NSImage(size: NSSize(width: original.size.width+2*shift, height: original.size.height+2*shift), flipped: false) { _ in
            original.draw(in: NSRect(origin: NSPoint(x: 2*shift, y: 2*shift), size: original.size)); return true
        }
        image.isTemplate = true; return image
    }()
    static let bell: NSImage = {
        let size = 18*SiteControlsLayout.scale
        let body = TablerIcon.image(TablerIcon.bell, size: size, filled: true)
        let clapper = TablerIcon.image(TablerIcon.bellClapper, size: size, filled: true)
        // Its ink spans y 2 to 23 of the 24-unit box; this centers it.
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let offset = rect.offsetBy(dx: 0, dy: -0.5*size/24)
            body.draw(in: offset); clapper.draw(in: offset); return true
        }
        image.isTemplate = true
        return image
    }()
    @objc func invoke() { perform() }
    override func layout() {
        super.layout()
        let scale = SiteControlsLayout.scale
        icon.frame = NSRect(x: 0, y: (bounds.height-32*scale)/2, width: 32*scale, height: 32*scale)
        let textX = 40*scale, width = bounds.width-textX-4
        name.frame = NSRect(x: textX, y: bounds.midY-18*scale, width: width, height: 19*scale)
        detail.frame = NSRect(x: textX, y: bounds.midY+scale, width: width, height: 18*scale)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !bounds.contains(convert(point, from: superview)) ? nil : self
    }
}

/// A setting in the site controls' list, as System Settings lists them: its icon, its name over
/// a few words on what it does, and a native switch, or for a permission its value, which opens
/// a menu. The whole row takes a
/// click, as its switch does.
final class SiteOptionRow: NSButton {
    enum Accessory { case toggle(Bool), value(String) }
    static let height: CGFloat = 40, iconSize: CGFloat = 18
    /// The mini switch draws only this much of its frame, at its trailing edge; the name can run
    /// into the rest.
    static let switchInk: CGFloat = 36
    /// The name sits a little in from the row's start, the icon a touch closer to it, and the
    /// switch a little in from the row's end.
    static let leading: CGFloat = 3, iconLeading: CGFloat = 5, trailing: CGFloat = 4
    /// Every row's icon is the same Tabler-style line, as wide and as heavy.
    static func icon(_ path: String) -> NSImage { TablerIcon.image(path, size: iconSize, strokeWidth: 1.5) }
    let name: NSTextField
    let detail: NSTextField
    let icon = NSImageView()
    let toggle = NSSwitch()
    let value: NSTextField
    private let chevron = NSImageView()
    private let perform: () -> Void
    private let isToggle: Bool
    override var isFlipped: Bool { true }
    init(title: String, subtitle: String, image: NSImage, accessory: Accessory, theme: RiseTheme, action: @escaping () -> Void) {
        perform = action
        name = label(title, size: 13, color: theme.text)
        detail = label(subtitle, size: 11, color: theme.muted)
        value = label("", size: 12.5, color: theme.muted)
        if case .toggle = accessory { isToggle = true } else { isToggle = false }
        super.init(frame: .zero)
        isBordered = false; self.title = ""; target = self; self.action = #selector(invoke)
        icon.image = image; icon.imageScaling = .scaleNone; icon.contentTintColor = theme.text
        name.lineBreakMode = .byTruncatingTail; detail.lineBreakMode = .byTruncatingTail
        toggle.controlSize = .mini; toggle.target = self; toggle.action = #selector(switched)
        toggle.setAccessibilityLabel(title)
        value.alignment = .right
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = theme.muted
        [icon, name, detail].forEach(addSubview)
        switch accessory {
        case .toggle(let on): toggle.state = on ? .on : .off; state = toggle.state; addSubview(toggle)
        case .value(let text): value.stringValue = text; [value, chevron].forEach(addSubview)
        }
        setAccessibilityLabel(title); setAccessibilityHelp(subtitle)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isEnabled: Bool {
        didSet { toggle.isEnabled = isEnabled; [icon, name, detail, value, chevron].forEach { $0.alphaValue = isEnabled ? 1 : 0.4 } }
    }
    /// A click on the row flips its switch, sliding as a click on the switch would.
    @objc func invoke() { if isToggle { toggle.performClick(nil) } else { perform() } }
    @objc private func switched() { state = toggle.state; perform() }
    /// A fresh row's state, taken without rebuilding, so a switch just flipped finishes its slide.
    func take(_ other: SiteOptionRow) {
        if toggle.state != other.toggle.state { toggle.state = other.toggle.state }
        state = other.state; value.stringValue = other.value.stringValue; isEnabled = other.isEnabled; toolTip = other.toolTip
    }
    override func layout() {
        super.layout()
        let size = Self.iconSize
        icon.frame = NSRect(x: Self.iconLeading, y: ((bounds.height-size)/2).rounded(), width: size, height: size)
        var end = bounds.width-Self.trailing
        if toggle.superview != nil {
            let fit = toggle.fittingSize
            toggle.frame = NSRect(x: end-fit.width, y: ((bounds.height-fit.height)/2).rounded(), width: fit.width, height: fit.height)
            end = toggle.frame.maxX-min(fit.width, Self.switchInk)-8
        } else {
            chevron.frame = NSRect(x: end-10, y: ((bounds.height-12)/2).rounded(), width: 10, height: 12)
            let width = ceil(value.intrinsicContentSize.width), line = ceil(value.intrinsicContentSize.height)
            value.frame = NSRect(x: chevron.frame.minX-4-width, y: ((bounds.height-line)/2).rounded(), width: width, height: line)
            end = value.frame.minX-8
        }
        // The name and the words under it, together in the middle of the row.
        let line = ceil(name.intrinsicContentSize.height), small = ceil(detail.intrinsicContentSize.height), textX = Self.leading+size+10
        let top = ((bounds.height-line-small)/2).rounded()
        name.frame = NSRect(x: textX, y: top, width: max(0, end-textX), height: line)
        detail.frame = NSRect(x: textX, y: top+line, width: max(0, end-textX), height: small)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return toggle.superview != nil && toggle.frame.contains(convert(point, from: superview)) ? toggle : self
    }
}

@MainActor final class SiteControlsController: NSViewController {
    weak var browser: BrowserController?
    private(set) var rows: [String: SiteOptionRow] = [:]
    /// What the popover is laid out from; a refresh that keeps it only updates the rows.
    private(set) var layoutKey: [String] = []
    private(set) var quickActions: [NSButton] = []
    private(set) var extensionsButton: PopoverActionButton!
    init(browser: BrowserController) { self.browser = browser; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        guard let browser else { view = NSView(); return }
        let theme = browser.theme
        let scale = SiteControlsLayout.scale
        view = PopoverContentView(frame: NSRect(x: 0, y: 0, width: 240, height: 440))
        let actions: [(String, String, () -> Void)] = [
            (PopoverActionButton.shareSymbol, "Share Page", { [weak browser] in browser?.shareCurrentPage() }),
            ("camera", "Capture Whole Page", {}),
            (AdBlockButton.symbol, "Block Ads", {}),
            ("ellipsis", "More Site Controls", { [weak browser] in browser?.moreSiteControls() })
        ]
        for (index, action) in actions.enumerated() {
            let button = action.0 == AdBlockButton.symbol
                ? AdBlockButton(isBlocking: browser.adBlocker.isBlocking(on: browser.selectedTab?.url), size: 17, scale: scale, theme: theme)
                : PopoverActionButton(symbol: action.0, size: action.0 == "ellipsis" ? 18 : 17, scale: scale, title: action.1, theme: theme,
                                      shareLift: PopoverActionButton.popoverShareLift, action: action.2)
            button.frame = NSRect(x: 10+CGFloat(index)*56+(52-52*scale)/2, y: 10+(34-34*scale)/2, width: 52*scale, height: 34*scale)
            if action.0 == "camera" { button.actionBlock = { [weak browser, weak button] in if let button { browser?.showCaptureChoices(from: button) } } }
            if let adBlock = button as? AdBlockButton {
                // Only a web page has a site to turn it off for, unless it's off everywhere.
                adBlock.isEnabled = !browser.adBlocker.enabled || AdBlocker.site(of: browser.selectedTab?.url) != nil
                adBlock.actionBlock = { [weak browser, weak adBlock] in
                    browser?.toggleAdBlockingHere(); adBlock?.show(blocking: browser?.adBlocker.isBlocking(on: browser?.selectedTab?.url) ?? true)
                }
            }
            view.addSubview(button); quickActions.append(button)
        }
        func heading(_ title: String, y: CGFloat) {
            let field = label(title, size: 14, weight: .semibold, color: theme.text)
            field.frame = NSRect(x: 10, y: y, width: 220, height: 20); view.addSubview(field)
        }
        heading("Extensions", y: 52)
        var y = layOutExtensions(in: view, theme: theme, scale: scale)
        func row(_ title: String, _ subtitle: String, _ icon: String, _ accessory: SiteOptionRow.Accessory, action: @escaping () -> Void) {
            let row = SiteOptionRow(title: title, subtitle: subtitle, image: SiteOptionRow.icon(icon), accessory: accessory, theme: theme, action: action)
            // As wide as the buttons above.
            row.frame = NSRect(x: 11, y: y, width: 218, height: SiteOptionRow.height); view.addSubview(row); rows[title] = row
            y += SiteOptionRow.height
        }
        let origin = SitePermissions.origin(browser.selectedTab?.url)
        let permissions = [SiteCapability.camera, .microphone, .location].filter { browser.sitePermissions.hasDecision($0, origin: origin) }
        if !permissions.isEmpty { heading("Permissions", y: y); y += 26 }
        for capability in permissions {
            let permission = browser.sitePermissions.permission(capability, origin: origin)
            row(capability.title, "Access for this site", capability.tablerIcon, .value(permission.subtitle)) { [weak browser] in browser?.permissionSettingMenu(capability) }
        }
        layoutKey = [theme == .dark ? "dark" : "light"] + view.subviews.compactMap { ($0 as? NSButton)?.toolTip ?? ($0 as? SiteOptionRow)?.name.stringValue }
            + rows.keys.sorted() + ["\(y)"]
        // Ending on the extensions' buttons, it leaves as much below them as beside them.
        let bottom = (view.subviews.last as? PopoverActionButton).map { ($0.frame.maxY+quickActions[0].frame.minX).rounded() }
        view.setFrameSize(NSSize(width: 240, height: bottom ?? y+8))
    }
    /// Only the rows' states changed: this popover takes them from a fresh one.
    func take(_ fresh: SiteControlsController) -> Bool {
        fresh.loadViewIfNeeded()
        guard fresh.layoutKey == layoutKey else { return false }
        for (title, row) in fresh.rows { rows[title]?.take(row) }
        return true
    }
}

@MainActor extension SiteControlsController {
    /// The extensions' buttons, four to a line with “+” last, and below them, on a Web Store page
    /// for one not yet added, a row adding it. Returns where what follows goes.
    func layOutExtensions(in view: NSView, theme: RiseTheme, scale: CGFloat) -> CGFloat {
        guard let browser else { return 125 }
        var buttons: [NSButton] = []
        var addTitle = "Extensions"
        if ChromiumEngine.isRunning {
            addTitle = "Get Extensions"
            for action in browser.extensionActions {
                let id = action.extensionID
                let button = PopoverActionButton(symbol: "puzzlepiece.extension", size: 15, scale: scale, title: action.name, theme: theme) { [weak browser] in
                    browser?.runExtension(id)
                }
                if let icon = action.icon(forTab: browser.selectedChromiumView) {
                    icon.size = NSSize(width: 18*scale, height: 18*scale); button.image = icon
                }
                button.menu = browser.extensionMenu(for: action)
                buttons.append(button)
            }
        }
        let add = PopoverActionButton(symbol: "plus", size: 15, scale: scale, title: addTitle, theme: theme) { [weak browser] in
            guard let browser else { return }
            browser.siteControlsPopover.close()
            browser.addTab(url: URL(string: "https://chromewebstore.google.com/category/extensions")!)
        }
        add.toolTip = "Get extensions from the Chrome Web Store"
        add.setAccessibilityLabel(addTitle)
        if ChromiumEngine.isRunning {
            let menu = NSMenu()
            menu.addItem(browser.menuItem("Manage Extensions…") { [weak browser] in browser?.showExtensions() })
            add.menu = menu
        }
        extensionsButton = add
        buttons.append(add)
        for (index, button) in buttons.enumerated() {
            let column = CGFloat(index % 4), line = CGFloat(index / 4)
            button.frame = NSRect(x: 10+column*56+(52-52*scale)/2, y: 78+line*42+(34-34*scale)/2, width: 52*scale, height: 34*scale)
            view.addSubview(button)
        }
        var y = 78+CGFloat((buttons.count+3)/4)*42+5
        if ChromiumEngine.isRunning, let id = BrowserController.webStoreExtensionID(browser.selectedTab?.url), !browser.isExtensionInstalled(id) {
            let name = (browser.selectedTab?.title ?? "").replacingOccurrences(of: " - Chrome Web Store", with: "")
            let row = SiteSettingRow(title: "Add to Rise", subtitle: name.isEmpty ? "From the Chrome Web Store" : name, symbol: "plus",
                                     active: true, theme: theme) { [weak browser] in browser?.addFromWebStore(id) }
            row.frame = NSRect(x: 14, y: y-4, width: 216, height: 43); view.addSubview(row); row.toolTip = "Add to Rise"
            y += 45
        }
        return y
    }
}

extension SiteCapability {
    /// Its icon in the address bar and the prompt.
    var tablerIcon: String {
        switch self {
        case .notifications: return TablerIcon.bellWithClapper
        case .camera: return TablerIcon.camera
        case .microphone: return TablerIcon.microphone
        case .location: return TablerIcon.mapPin
        }
    }
    /// Its colour in the prompt, deeper on light and brighter on dark: the camera green and the
    /// microphone orange, as macOS's own recording lights are, location blue and notifications red.
    func accent(_ theme: RiseTheme) -> NSColor {
        let dark = theme == .dark
        switch self {
        case .camera: return NSColor(hex: dark ? 0x4CD173 : 0x1A9E4B)
        case .microphone: return NSColor(hex: dark ? 0xFFA23A : 0xE07800)
        case .location: return NSColor(hex: dark ? 0x4DA3FF : 0x0A72E8)
        case .notifications: return NSColor(hex: dark ? 0xFF6B6B : 0xE5383B)
        }
    }
}

extension NSImage {
    /// The same image, drawn `lift` points higher wherever it's centered.
    func raised(by lift: CGFloat) -> NSImage {
        let raised = NSImage(size: NSSize(width: size.width, height: size.height+2*lift), flipped: false) { [self] _ in
            draw(in: NSRect(x: 0, y: 2*lift, width: size.width, height: size.height)); return true
        }
        raised.isTemplate = isTemplate; raised.accessibilityDescription = accessibilityDescription
        return raised
    }
}
