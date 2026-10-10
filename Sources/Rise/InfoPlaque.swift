import AppKit

/// Short notices in the find bar's panel: each drops into the page's top-right corner on the
/// same springs, holds for a moment and goes back up the way the find bar leaves. A notice of
/// another kind arriving while one shows sits to its left, and when one leaves, those after it
/// spring right into its place at once, while it's still going up (Motion's popLayout). A new
/// message for a notice already showing swaps only the words that changed, on the find bar's
/// keyed swap. Only an action button takes clicks, and the pointer over that notice holds it.
@MainActor final class InfoPlaque: FlippedView {
    /// How long a notice stays before it goes back up.
    static let hold: Duration = .seconds(1)
    static let iconSize: CGFloat = 14, iconGap: CGFloat = 7, inset: CGFloat = 12
    static let font = NSFont.systemFont(ofSize: 13)
    /// The space between notices side by side.
    static let spacing: CGFloat = 8
    /// Quick, with a little spring, as a notice moves over into the place of one that left.
    static let shiftResponse = 0.3, shiftBounce = 0.2
    static let infoIcon = TablerIcon.image(TablerIcon.infoCircle, size: iconSize)
    /// The sidebar copy button's confirmation glyph.
    static let linkCopiedIcon = TablerIcon.image(TablerIcon.linkCopied, size: iconSize)
    /// Picture in Picture's return arrows, still, a little smaller than the text so they sit
    /// centered on it.
    static let fullScreenIcon = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)) ?? infoIcon
    /// The arrows' image sits high in its frame; this lowers them onto the text's center.
    static let fullScreenIconDrop: CGFloat = 0.5
    /// A button after the text, such as sharing a copied link.
    struct Action { let symbol: String; let title: String; let perform: () -> Void }
    static let buttonSize = NSSize(width: 30, height: 26), buttonGap: CGFloat = 8

    /// Oldest first, which is rightmost; notices still going up stay until they're out of sight.
    private(set) var notices: [InfoNotice] = []
    /// The notice shown last, which the properties below describe.
    private var recent = InfoNotice(kind: "")
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var theme = RiseTheme.neutral
    /// The pointer came over or left a notice with a button.
    var onPointer: ((Bool) -> Void)?
    /// Space at the top of the page taken by the developer header.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }

    var isPresented: Bool { notices.contains(where: \.isPresented) }
    var panel: Surface { recent.panel }
    var text: String { recent.text }
    var lead: String { recent.lead }
    var rest: String { recent.rest }
    var panelWidth: CGFloat { recent.panelWidth }
    var textWidth: CGFloat { recent.textWidth }
    var actionButton: PopoverActionButton? { recent.actionButton }
    var isHovered: Bool { notices.contains(where: \.isHovered) }
    func setHovered(_ hovered: Bool) { recent.setHovered(hovered) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.cornerRadius = PageAppearance.radius; layer?.cornerCurve = .continuous
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for notice in notices.reversed() { if let hit = notice.hitTest(local) { return hit } }
        return nil
    }
    override func layout() {
        super.layout()
        for notice in notices { notice.frame = bounds; notice.topInset = topInset; notice.render() }
    }

    /// Blue, so a notice stands out from the gray panels: a pale fill and deep ink in light
    /// themes (Tailwind's blue-50 and blue-800), a navy fill and soft blue ink in dark.
    static func colors(for theme: RiseTheme) -> (fill: NSColor, border: NSColor, ink: NSColor) {
        theme == .dark
            ? (NSColor(hex: 0x172036), NSColor(hex: 0x60A5FA).withAlphaComponent(0.35), NSColor(hex: 0x7DB4FC))
            : (NSColor(hex: 0xEFF6FF), NSColor(hex: 0x3B82F6).withAlphaComponent(0.35), NSColor(hex: 0x1E40AF))
    }
    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme
        notices.forEach { $0.applyTheme(theme) }
    }

    static func width(of text: String) -> CGFloat {
        text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    /// Splits two messages into the words that differ at the start and the words they end with.
    nonisolated static func split(_ old: String, _ new: String) -> (old: String, new: String, rest: String) {
        let a = old.split(separator: " ").map(String.init), b = new.split(separator: " ").map(String.init)
        var shared = 0
        while shared < min(a.count, b.count)-1 && a[a.count-1-shared] == b[b.count-1-shared] { shared += 1 }
        return (a.dropLast(shared).joined(separator: " "), b.dropLast(shared).joined(separator: " "), b.suffix(shared).joined(separator: " "))
    }

    /// Shows `text` beside `image`, with `action`'s button after it. A notice of the same `kind`
    /// already showing takes the new message and starts its hold again; otherwise a new notice
    /// drops in to the left of those showing.
    func show(_ text: String, image: NSImage? = nil, action: Action? = nil, kind: String = "info") {
        let notice: InfoNotice
        if let showing = notices.last(where: { $0.kind == kind && $0.isPresented }) { notice = showing }
        else {
            notice = InfoNotice(kind: kind); notice.row = self
            notice.applyTheme(theme); notice.frame = bounds; notice.topInset = topInset
            addSubview(notice); notices.append(notice)
        }
        recent = notice; isHidden = false
        notice.show(text, image: image, action: action)
        // A new notice drops straight into its place rather than sliding over to it.
        retarget(); if notice.shift.velocity == 0, notice.slide.value == 0 { notice.shift.settle() }
        notice.render(); animate()
    }
    func hide() { notices.forEach { $0.hide() } }

    /// Lays the showing notices out from the corner, oldest rightmost. A leaving notice no
    /// longer takes room, so those after it start moving into its place as it goes.
    func retarget() {
        var offset: CGFloat = 0
        for notice in notices where notice.isPresented {
            notice.shift.target = offset; offset += notice.panelWidth+Self.spacing
        }
    }
    func pointerChanged() { onPointer?(notices.contains { $0.isHovered && $0.actionButton != nil }) }

    func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { settle(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    private func settle() {
        link?.invalidate(); link = nil
        notices.forEach { $0.settle() }
        removeGone()
    }
    /// Notices that have gone back up are done with.
    private func removeGone() {
        for notice in notices where !notice.isPresented && notice.isOut { notice.removeFromSuperview() }
        notices.removeAll { !$0.isPresented && $0.isOut }
        if notices.isEmpty { isHidden = true }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        notices.forEach { $0.step(dt) }
        if notices.allSatisfy(\.isResting) { settle() }
        else { removeGone(); notices.forEach { $0.render() } }
    }
}

/// One notice in the row: its panel, icon, message and optional button. It drops in, holds and
/// goes back up on its own; the row places it and runs its springs.
@MainActor final class InfoNotice: FlippedView {
    let kind: String
    weak var row: InfoPlaque?
    let panel = Surface(radius: FindBar.radius)
    private let content = FlippedView()
    private let icon = NSImageView(image: InfoPlaque.infoIcon)
    private var iconDrop: CGFloat = 0
    /// The changing words, keyed by their text, so one coming back mid-exit springs from where it is.
    private var leads: [String: PresenceItem] = [:]
    /// The words both messages end with, which stay put.
    private let restLabel = label("", size: 13)
    private(set) var lead = "", rest = ""
    private var leadWidth = MotionSpring(0)
    private(set) var slide = MotionSpring(0)
    /// How far left of the corner it sits, past the notices that came before it.
    var shift = MotionSpring(0)
    private var holdTask: Task<Void, Never>?
    private var textColor = NSColor.labelColor
    private(set) var isPresented = false
    private(set) var actionButton: PopoverActionButton?
    private var theme = RiseTheme.neutral
    private(set) var isHovered = false
    var topInset: CGFloat = 0
    /// The message showing, or last shown.
    var text: String { rest.isEmpty ? lead : lead + " " + rest }

    init(kind: String) {
        self.kind = kind
        super.init(frame: .zero)
        FindBar.stylePanel(panel, content: content)
        icon.imageScaling = .scaleNone
        restLabel.lineBreakMode = .byClipping
        [icon, restLabel].forEach(content.addSubview)
        panel.addSubview(content); addSubview(panel)
        leadWidth.configure(response: FindMotion.swapResponse, bounce: 0)
        shift.configure(response: InfoPlaque.shiftResponse, bounce: InfoPlaque.shiftBounce)
        setAccessibilityElement(false)
        panel.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isPresented, let button = actionButton else { return nil }
        return button.bounds.contains(button.convert(point, from: superview)) ? button : nil
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    /// Only a notice with a button waits for the pointer to leave it.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered; row?.pointerChanged()
        guard actionButton != nil, isPresented else { return }
        if hovered { holdTask?.cancel(); holdTask = nil } else { startHold() }
    }
    private func startHold() {
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: InfoPlaque.hold)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme
        FindBar.applyPanelTheme(panel, theme: theme)
        let colors = InfoPlaque.colors(for: theme)
        panel.fill = colors.fill; panel.layer?.borderColor = colors.border.cgColor
        icon.contentTintColor = colors.ink; textColor = colors.ink
        restLabel.textColor = textColor
        leads.values.forEach { ($0.view as? NSTextField)?.textColor = textColor }
    }

    private static let space = InfoPlaque.width(of: "a b")-InfoPlaque.width(of: "ab")
    /// Where the message starts, after the icon.
    private static let textX = InfoPlaque.inset+InfoPlaque.iconSize+InfoPlaque.iconGap
    private func restWidth(_ rest: String) -> CGFloat { rest.isEmpty ? 0 : Self.space+InfoPlaque.width(of: rest) }
    /// The panel's width once any swap settles: the message with the icon before it.
    var panelWidth: CGFloat { width(lead: leadWidth.target) }
    private func width(lead: CGFloat) -> CGFloat {
        let end = actionButton == nil ? InfoPlaque.inset+2
            : InfoPlaque.buttonGap+InfoPlaque.buttonSize.width+(FindBar.rowHeight-InfoPlaque.buttonSize.height)/2
        return Self.textX+lead+restWidth(rest)+end
    }
    /// The message's width once any swap settles.
    var textWidth: CGFloat { leadWidth.target+restWidth(rest) }

    private func leadLabel(_ text: String) -> NSTextField {
        let field = label(text, size: 13, color: textColor)
        field.lineBreakMode = .byClipping
        content.addSubview(field)
        return field
    }
    private func clearLeads() { leads.values.forEach { $0.view.removeFromSuperview() }; leads = [:] }

    func show(_ text: String, image: NSImage?, action: InfoPlaque.Action?) {
        actionButton?.removeFromSuperview(); actionButton = nil
        if let action {
            let button = PopoverActionButton(symbol: action.symbol, size: 13, title: action.title, theme: theme) { [weak self] in
                self?.hide(); action.perform()
            }
            content.addSubview(button); actionButton = button
        }
        icon.image = image ?? InfoPlaque.infoIcon; iconDrop = image === InfoPlaque.fullScreenIcon ? InfoPlaque.fullScreenIconDrop : 0
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if !isPresented || lead.isEmpty {
            clearLeads()
            lead = text; rest = ""; restLabel.stringValue = ""
            leads[text] = PresenceItem(leadLabel(text), shown: true)
            leadWidth.target = InfoPlaque.width(of: text); leadWidth.settle()
        } else if text != self.text {
            let parts = InfoPlaque.split(self.text, text)
            if parts.rest != rest {
                // Regroup what's showing around the shared words; it reads the same, so nothing moves.
                clearLeads()
                leads[parts.old] = PresenceItem(leadLabel(parts.old), shown: true)
                rest = parts.rest; restLabel.stringValue = rest
                leadWidth.target = InfoPlaque.width(of: parts.old); leadWidth.settle()
            } else {
                leads[lead]?.set(false)
            }
            if leads[parts.new] == nil { leads[parts.new] = PresenceItem(leadLabel(parts.new), shown: false) }
            leads[parts.old]?.set(false)
            leads[parts.new]?.set(true)
            lead = parts.new
            leadWidth.target = InfoPlaque.width(of: parts.new)
        }
        if !isPresented {
            isPresented = true
            slide.configure(response: DownloadMotion.trayInResponse, bounce: DownloadMotion.trayInBounce)
            slide.target = 1
        }
        if isHovered, actionButton != nil { holdTask?.cancel(); holdTask = nil } else { startHold() }
    }
    func hide() {
        holdTask?.cancel(); holdTask = nil
        guard isPresented else { return }
        isPresented = false
        slide.configure(response: FindMotion.outResponse, bounce: DownloadMotion.trayOutBounce)
        slide.target = 0
        row?.retarget(); row?.animate()
    }

    /// Back up out of sight.
    var isOut: Bool { slide.target == 0 && slide.isResting(within: 0.001) }
    var isResting: Bool {
        slide.isResting(within: 0.001) && leadWidth.isResting(within: 0.05) && shift.isResting(within: 0.05) && leads.values.allSatisfy(\.isResting)
    }
    func step(_ dt: Double) {
        slide.step(dt); leadWidth.step(dt); shift.step(dt)
        for key in leads.keys { leads[key]?.step(dt) }
    }
    func settle() {
        slide.settle(); leadWidth.settle(); shift.settle()
        for key in leads.keys { leads[key]?.settle() }
        // Words that have left are done with.
        for (key, item) in leads where !item.shown { item.view.removeFromSuperview(); leads[key] = nil }
        render()
    }
    func render() {
        let width = width(lead: leadWidth.value), height = FindBar.rowHeight
        var origin = FindBar.panelOrigin(in: bounds, width: width, height: height, slide: slide.value, topInset: topInset)
        origin.x -= shift.value
        panel.frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        content.frame = panel.bounds
        icon.frame = NSRect(x: InfoPlaque.inset, y: (height-InfoPlaque.iconSize)/2+iconDrop, width: InfoPlaque.iconSize, height: InfoPlaque.iconSize)
        let textHeight = ceil(restLabel.intrinsicContentSize.height)
        let y = (height-textHeight)/2
        // Label cells pad their text by 2 pt on each side.
        for (text, item) in leads {
            item.render(at: NSRect(x: Self.textX-2, y: y, width: InfoPlaque.width(of: text)+4, height: textHeight))
        }
        restLabel.frame = NSRect(x: Self.textX+leadWidth.value+Self.space-2, y: y, width: InfoPlaque.width(of: rest)+4, height: textHeight)
        actionButton?.frame = NSRect(origin: NSPoint(x: Self.textX+leadWidth.value+restWidth(rest)+InfoPlaque.buttonGap, y: (height-InfoPlaque.buttonSize.height)/2),
                                     size: InfoPlaque.buttonSize)
    }
}

@MainActor extension BrowserController {
    /// ⇧⌘F switches page fullscreen between WebKit's own and simulated, for pages
    /// already open too, and says which one is now on.
    @objc func toggleSimulatedFullscreen() {
        let simulated = !pageFullscreen.isSimulated
        let webViews = tabs.map(\.webView) + (peekTab.map { [$0.webView] } ?? [])
        pageFullscreen.setSimulated(simulated, in: webViews)
        showInfo(simulated ? "Simulated full screen enabled" : "Native full screen enabled", image: InfoPlaque.fullScreenIcon, kind: "fullscreen")
    }
    func showInfo(_ text: String, image: NSImage? = nil, action: InfoPlaque.Action? = nil, kind: String = "info") {
        // Above the find bar, which is inserted under the link status as well.
        root.addSubview(infoPlaque, positioned: .below, relativeTo: linkStatus)
        layoutChrome()
        infoPlaque.show(text, image: image, action: action, kind: kind)
    }
}
