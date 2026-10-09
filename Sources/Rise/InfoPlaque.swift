import AppKit

/// A short notice in the find bar's panel: it drops into the page's top-right corner on
/// the same springs, holds for a moment and goes back up the way the find bar leaves.
/// Its width fits the message. A new message while it's showing swaps only the words
/// that changed, on the find bar's keyed swap, while the rest slides to make room. It
/// never takes clicks.
@MainActor final class InfoPlaque: FlippedView {
    /// How long the notice stays before it goes back up.
    static let hold: Duration = .seconds(1)
    static let iconSize: CGFloat = 14, iconGap: CGFloat = 7, inset: CGFloat = 12
    static let font = NSFont.systemFont(ofSize: 13)

    let panel = Surface(radius: FindBar.radius)
    private let content = FlippedView()
    static let infoIcon = TablerIcon.image(TablerIcon.infoCircle, size: iconSize)
    /// Picture in Picture's return arrows, still, at the weight of the info icon's strokes.
    static let fullScreenIcon = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)) ?? infoIcon
    /// The arrows sit a little high, level with the text's capitals rather than its center.
    static let fullScreenIconLift: CGFloat = 0.5
    private let icon = NSImageView(image: InfoPlaque.infoIcon)
    private var iconLift: CGFloat = 0
    /// The changing words, keyed by their text, so one coming back mid-exit springs from where it is.
    private var leads: [String: PresenceItem] = [:]
    /// The words both messages end with, which stay put.
    private let restLabel = label("", size: 13)
    private(set) var lead = "", rest = ""
    private var leadWidth = MotionSpring(0)
    private var slide = MotionSpring(0)
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var holdTask: Task<Void, Never>?
    private var textColor = NSColor.labelColor
    private(set) var isPresented = false
    /// The message showing, or last shown.
    var text: String { rest.isEmpty ? lead : lead + " " + rest }
    /// Space at the top of the page taken by the developer header.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.cornerRadius = PageAppearance.radius; layer?.cornerCurve = .continuous
        isHidden = true
        FindBar.stylePanel(panel, content: content)
        icon.imageScaling = .scaleNone
        restLabel.lineBreakMode = .byClipping
        [icon, restLabel].forEach(content.addSubview)
        panel.addSubview(content); addSubview(panel)
        leadWidth.configure(response: FindMotion.swapResponse, bounce: 0)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); render() }

    /// Blue, so a notice stands out from the gray panels: a pale fill and deep ink in light
    /// themes (Tailwind's blue-50 and blue-800), a navy fill and soft blue ink in dark.
    static func colors(for theme: RiseTheme) -> (fill: NSColor, border: NSColor, ink: NSColor) {
        theme == .dark
            ? (NSColor(hex: 0x172036), NSColor(hex: 0x60A5FA).withAlphaComponent(0.35), NSColor(hex: 0x7DB4FC))
            : (NSColor(hex: 0xEFF6FF), NSColor(hex: 0x3B82F6).withAlphaComponent(0.35), NSColor(hex: 0x1E40AF))
    }

    func applyTheme(_ theme: RiseTheme) {
        FindBar.applyPanelTheme(panel, theme: theme)
        let colors = Self.colors(for: theme)
        panel.fill = colors.fill; panel.layer?.borderColor = colors.border.cgColor
        icon.contentTintColor = colors.ink; textColor = colors.ink
        restLabel.textColor = textColor
        leads.values.forEach { ($0.view as? NSTextField)?.textColor = textColor }
    }

    static func width(of text: String) -> CGFloat {
        text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    private static let space = width(of: "a b")-width(of: "ab")
    /// Where the message starts, after the icon.
    private static let textX = inset+iconSize+iconGap
    private func restWidth(_ rest: String) -> CGFloat { rest.isEmpty ? 0 : Self.space+Self.width(of: rest) }
    /// The panel's width once any swap settles: the message with the icon before it.
    var panelWidth: CGFloat { width(lead: leadWidth.target) }
    private func width(lead: CGFloat) -> CGFloat { Self.textX+lead+restWidth(rest)+Self.inset+2 }
    /// The message's width once any swap settles.
    var textWidth: CGFloat { leadWidth.target+restWidth(rest) }

    /// Splits two messages into the words that differ at the start and the words they end with.
    nonisolated static func split(_ old: String, _ new: String) -> (old: String, new: String, rest: String) {
        let a = old.split(separator: " ").map(String.init), b = new.split(separator: " ").map(String.init)
        var shared = 0
        while shared < min(a.count, b.count)-1 && a[a.count-1-shared] == b[b.count-1-shared] { shared += 1 }
        return (a.dropLast(shared).joined(separator: " "), b.dropLast(shared).joined(separator: " "), b.suffix(shared).joined(separator: " "))
    }

    private func leadLabel(_ text: String) -> NSTextField {
        let field = label(text, size: 13, color: textColor)
        field.lineBreakMode = .byClipping
        content.addSubview(field)
        return field
    }
    private func clearLeads() { leads.values.forEach { $0.view.removeFromSuperview() }; leads = [:] }

    /// Drops in with `text` beside `image`. One already showing swaps the words that changed and starts its hold again.
    func show(_ text: String, image: NSImage? = nil) {
        icon.image = image ?? Self.infoIcon; iconLift = image === Self.fullScreenIcon ? Self.fullScreenIconLift : 0
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if !isPresented || lead.isEmpty {
            clearLeads()
            lead = text; rest = ""; restLabel.stringValue = ""
            leads[text] = PresenceItem(leadLabel(text), shown: true)
            leadWidth.target = Self.width(of: text); leadWidth.settle()
        } else if text != self.text {
            let parts = Self.split(self.text, text)
            if parts.rest != rest {
                // Regroup what's showing around the shared words; it reads the same, so nothing moves.
                clearLeads()
                leads[parts.old] = PresenceItem(leadLabel(parts.old), shown: true)
                rest = parts.rest; restLabel.stringValue = rest
                leadWidth.target = Self.width(of: parts.old); leadWidth.settle()
            } else {
                leads[lead]?.set(false)
            }
            if leads[parts.new] == nil { leads[parts.new] = PresenceItem(leadLabel(parts.new), shown: false) }
            leads[parts.old]?.set(false)
            leads[parts.new]?.set(true)
            lead = parts.new
            leadWidth.target = Self.width(of: parts.new)
            animate()
        }
        if !isPresented {
            isPresented = true; isHidden = false
            slide.configure(response: DownloadMotion.trayInResponse, bounce: DownloadMotion.trayInBounce)
            slide.target = 1; animate()
        }
        render()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hold)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
    func hide() {
        holdTask?.cancel(); holdTask = nil
        guard isPresented else { return }
        isPresented = false
        slide.configure(response: FindMotion.outResponse, bounce: DownloadMotion.trayOutBounce)
        slide.target = 0; animate()
    }

    private func render() {
        let width = width(lead: leadWidth.value), height = FindBar.rowHeight
        panel.frame = NSRect(origin: FindBar.panelOrigin(in: bounds, width: width, height: height, slide: slide.value, topInset: topInset),
                             size: NSSize(width: width, height: height))
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        content.frame = panel.bounds
        icon.frame = NSRect(x: Self.inset, y: (height-Self.iconSize)/2-iconLift, width: Self.iconSize, height: Self.iconSize)
        let textHeight = ceil(restLabel.intrinsicContentSize.height)
        let y = (height-textHeight)/2
        // Label cells pad their text by 2 pt on each side.
        for (text, item) in leads {
            item.render(at: NSRect(x: Self.textX-2, y: y, width: Self.width(of: text)+4, height: textHeight))
        }
        restLabel.frame = NSRect(x: Self.textX+leadWidth.value+Self.space-2, y: y, width: Self.width(of: rest)+4, height: textHeight)
    }
    private func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { settle(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    private func settle() {
        link?.invalidate(); link = nil
        slide.settle(); leadWidth.settle()
        for key in leads.keys { leads[key]?.settle() }
        // Words that have left are done with.
        for (key, item) in leads where !item.shown { item.view.removeFromSuperview(); leads[key] = nil }
        render()
        if !isPresented { isHidden = true }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        slide.step(dt); leadWidth.step(dt)
        for key in leads.keys { leads[key]?.step(dt) }
        let resting = slide.isResting(within: 0.001) && leadWidth.isResting(within: 0.05) && leads.values.allSatisfy(\.isResting)
        if resting { settle() } else { render() }
    }
}

@MainActor extension BrowserController {
    /// ⇧⌘F switches page fullscreen between WebKit's own and simulated, for pages
    /// already open too, and says which one is now on.
    @objc func toggleSimulatedFullscreen() {
        let simulated = !pageFullscreen.isSimulated
        let webViews = tabs.map(\.webView) + (peekTab.map { [$0.webView] } ?? [])
        pageFullscreen.setSimulated(simulated, in: webViews)
        showInfo(simulated ? "Simulated full screen enabled" : "Native full screen enabled", image: InfoPlaque.fullScreenIcon)
    }
    func showInfo(_ text: String, image: NSImage? = nil) {
        // Above the find bar, which is inserted under the link status as well.
        root.addSubview(infoPlaque, positioned: .below, relativeTo: linkStatus)
        layoutChrome()
        infoPlaque.show(text, image: image)
    }
}
