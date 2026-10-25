import AppKit

/// The border, arrow, material and outer shadow belong to NSPopover.
final class PopoverContentView: FlippedView {}

enum SiteControlsLayout {
    static let scale: CGFloat = 0.96
}

/// Shared Arc-style action bezel used by settings and copy confirmation.
final class PopoverActionButton: ChromeButton {
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

@MainActor final class SiteControlsController: NSViewController {
    weak var browser: BrowserController?
    private(set) var rows: [String: SiteSettingRow] = [:]
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
            ("text.viewfinder", "Copy Text from Page Image", { [weak browser] in browser?.siteControlsPopover.close(); browser?.copyTextFromPageImage() }),
            ("ellipsis", "More Site Controls", { [weak browser] in browser?.moreSiteControls() })
        ]
        for (index, action) in actions.enumerated() {
            let button = PopoverActionButton(symbol: action.0, size: action.0 == "ellipsis" ? 18 : 17, scale: scale, title: action.1, theme: theme,
                                             shareLift: PopoverActionButton.popoverShareLift, action: action.2)
            button.frame = NSRect(x: 10+CGFloat(index)*56+(52-52*scale)/2, y: 10+(34-34*scale)/2, width: 52*scale, height: 34*scale)
            if action.0 == "camera" { button.actionBlock = { [weak browser, weak button] in if let button { browser?.showCaptureChoices(from: button) } } }
            view.addSubview(button); quickActions.append(button)
        }
        func heading(_ title: String, y: CGFloat) {
            let field = label(title, size: 14, weight: .semibold, color: theme.text)
            field.frame = NSRect(x: 10, y: y, width: 220, height: 20); view.addSubview(field)
        }
        heading("Extensions", y: 52)
        var y = layOutExtensions(in: view, theme: theme, scale: scale)
        heading("Settings", y: y)
        y += 26
        func row(_ title: String, subtitle: String, symbol: String, image: NSImage? = nil, active: Bool, checked: Bool? = nil, action: @escaping () -> Void) {
            let row = SiteSettingRow(title: title, subtitle: subtitle, symbol: symbol, image: image, active: active, checked: checked, theme: theme, action: action)
            row.frame = NSRect(x: 14, y: y, width: 216, height: 43); view.addSubview(row); rows[title] = row; y += 43
        }
        let origin = SitePermissions.origin(browser.selectedTab?.url)
        row("Developer Mode", subtitle: browser.selectedTab?.developer == true ? "On" : "Off", symbol: "hammer.fill", image: SiteSettingRow.hammer, active: browser.selectedTab?.developer == true) { [weak browser] in browser?.toggleDeveloper(); browser?.refreshSiteControls() }
        let cookies = browser.cookieConsent.isEnabled(for: browser.selectedTab?.url)
        row("Dismiss Cookie Dialogs", subtitle: cookies ? "On" : "Off", symbol: "", image: TablerIcon.image(TablerIcon.cookie, size: 17*scale), active: cookies, checked: cookies) { [weak browser] in browser?.toggleCookieConsent() }
        rows["Dismiss Cookie Dialogs"]?.isEnabled = SitePermissions.origin(browser.selectedTab?.url) != nil
        row("Block Ads", subtitle: browser.adBlocker.enabled ? "On" : "Off", symbol: "shield.fill", active: browser.adBlocker.enabled, checked: browser.adBlocker.enabled) { [weak browser] in browser?.toggleAdBlocking(); browser?.refreshSiteControls() }
        let pip = browser.sitePermissions.automaticPictureInPicture(origin: origin)
        row("Automatic Picture-In-Picture", subtitle: pip ? "Allowed" : "Blocked", symbol: "gearshape.fill", active: pip) { [weak browser] in browser?.toggleAutomaticPictureInPicture(); browser?.refreshSiteControls() }
        row("Preload Links", subtitle: browser.linkPreloader.enabled ? "On · Experimental" : "Off · Experimental", symbol: "bolt.fill", active: browser.linkPreloader.enabled, checked: browser.linkPreloader.enabled) { [weak browser] in
            guard let browser else { return }; browser.linkPreloader.setEnabled(!browser.linkPreloader.enabled); browser.refreshSiteControls()
        }
        rows["Preload Links"]?.toolTip = "Preload a link after hovering for 150 ms."
        for capability in [SiteCapability.camera, .microphone, .location] where browser.sitePermissions.hasDecision(capability, origin: origin) {
            let permission = browser.sitePermissions.permission(capability, origin: origin)
            row(capability.title, subtitle: permission.subtitle, symbol: capability.symbol, active: permission == .allow) { [weak browser] in browser?.permissionSettingMenu(capability) }
        }
        view.setFrameSize(NSSize(width: 240, height: y+8))
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
            row.frame = NSRect(x: 14, y: y-4, width: 216, height: 43); view.addSubview(row); rows["Add to Rise"] = row
            y += 45
        }
        return y
    }
}

final class PermissionPromptController: NSViewController {
    let message: String
    let symbol: String
    let reply: (Bool) -> Void
    private(set) var allowButton: NSButton!
    private(set) var notNowButton: NSButton!
    init(host: String, capabilities: [SiteCapability], reply: @escaping (Bool) -> Void) {
        let use: String
        if capabilities == [.notifications] { use = "send you notifications?" }
        else if capabilities == [.location] { use = "use your location?" }
        else if capabilities.count == 2 { use = "use your camera and microphone?" }
        else { use = "use your \(capabilities.first == .camera ? "camera" : "microphone")?" }
        message = "Allow \(host) to \(use)"; symbol = capabilities.first?.symbol ?? "gearshape.fill"; self.reply = reply
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let text = NSTextField(wrappingLabelWithString: message); text.font = .systemFont(ofSize: 14)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        text.textColor = NSColor(hex: dark ? 0xD1D1D1 : 0x575757); text.preferredMaxLayoutWidth = 176
        let height = max(62, ceil((message as NSString).boundingRect(with: NSSize(width: 176, height: 300), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!]).height)+4)
        view = PopoverContentView(frame: NSRect(x: 0, y: 0, width: 236, height: height+60))
        let icon = NSImageView(frame: NSRect(x: 10, y: 10, width: 32, height: 32)); icon.wantsLayer = true
        icon.layer?.cornerRadius = 16; icon.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor; view.addSubview(icon)
        text.frame = NSRect(x: 50, y: 10, width: 176, height: height); view.addSubview(text)
        notNowButton = NSButton(title: "Not Now", target: self, action: #selector(decline))
        allowButton = NSButton(title: "Allow", target: self, action: #selector(allow))
        for (i, button) in [notNowButton!, allowButton!].enumerated() {
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 14, weight: .semibold)
            button.frame = NSRect(x: 10+CGFloat(i)*111, y: height+20, width: 105, height: 32); view.addSubview(button)
        }
        notNowButton.isBordered = false; notNowButton.wantsLayer = true
        notNowButton.layer?.cornerRadius = 6; notNowButton.layer?.cornerCurve = .continuous
        notNowButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.13).cgColor
        allowButton.isBordered = false; allowButton.wantsLayer = true
        allowButton.layer?.cornerRadius = 6; allowButton.layer?.cornerCurve = .continuous
        allowButton.layer?.backgroundColor = (dark ? NSColor(hex: 0x404040) : NSColor.white.withAlphaComponent(0.8)).cgColor
        allowButton.layer?.borderWidth = 0.5; allowButton.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.28).cgColor
        allowButton.layer?.shadowColor = NSColor.black.cgColor; allowButton.layer?.shadowOpacity = 0.1
        allowButton.layer?.shadowRadius = 2; allowButton.layer?.shadowOffset = NSSize(width: 0, height: -1)
        // Never assign Return to Allow: granting access requires choosing it.
        notNowButton.keyEquivalent = "\u{1b}"
    }
    @objc private func decline() { reply(false) }
    @objc private func allow() { reply(true) }
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
