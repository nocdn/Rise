import AppKit

/// What a site asks to use, in as few words as say it: a question ending in "?", its site in the
/// colour of what's asked for.
struct PermissionQuestion {
    let heading: String, message: String, host: String
    let icon: String, capability: SiteCapability
    init(host: String, capabilities: [SiteCapability]) {
        let (subject, use): (String, String)
        if capabilities == [.notifications] { (subject, use) = ("Notification", "send notifications") }
        else if capabilities == [.location] { (subject, use) = ("Location", "use your location") }
        else if Set(capabilities) == [.camera, .microphone] { (subject, use) = ("Camera and microphone", "use your camera and mic") }
        else if capabilities.first == .camera { (subject, use) = ("Camera", "use your camera") }
        else { (subject, use) = ("Microphone", "use your microphone") }
        heading = "\(subject) permissions"; message = "Let \(host) \(use)?"; self.host = host
        capability = capabilities.first ?? .camera; icon = capability.tablerIcon
    }
    func text(theme: RiseTheme, font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString(string: message, attributes: [.font: font, .foregroundColor: theme.text])
        let site = (message as NSString).range(of: host)
        if site.location != NSNotFound { text.addAttribute(.foregroundColor, value: capability.accent(theme), range: site) }
        return text
    }
}

/// Find's buttons, a check or a cross, which takes its colour while the pointer is on it.
final class PermissionChoiceButton: ChromeButton {
    var restingTint = NSColor.gray { didSet { tint() } }
    var hoverTint = NSColor.gray { didSet { tint() } }
    override func refreshHoverState(at point: NSPoint? = nil) { super.refreshHoverState(at: point); tint() }
    private func tint() { contentTintColor = hover ? hoverTint : restingTint }
}

/// A site asking to use something, in Find's panel, coming down from under the page bar as it
/// does: its icon in the colour of what's asked for, the question, then Allow and Don't Allow as
/// Find's chevrons and close are. Only they answer it; its icon in the bar puts it away and
/// brings it back. Covers the asking page and clips to it; only the panel takes clicks.
@MainActor final class PermissionPanel: FlippedView {
    static let iconSize: CGFloat = 16, textX: CGFloat = 12+16+7, buttonsWidth: CGFloat = 2*26+1
    static let font = NSFont.systemFont(ofSize: 13)
    let panel = Surface(radius: FindBar.radius)
    private let content = FlippedView()
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")
    let allowButton = PermissionChoiceButton(symbol: "checkmark", size: 11, title: "Allow", action: {})
    let denyButton = PermissionChoiceButton(symbol: "xmark", size: 11, title: "Don’t Allow", action: {})
    /// In place of both, for a notice: puts back what it tells of, turning blue as the check turns green.
    let revertButton = PermissionChoiceButton(symbol: "arrow.uturn.backward", size: 11, title: "Revert", action: {})
    /// Something done to the page, told in the same panel: its icon, what was done, and Revert.
    struct Notice {
        let image: NSImage, accent: (RiseTheme) -> NSColor
        let text: (RiseTheme, NSFont) -> NSAttributedString, message: String
    }
    private(set) var notice: Notice?
    /// A notice answered with the check and the cross, rather than told.
    private var noticeAsks = false
    private var hasChoice: Bool { notice == nil || noticeAsks }
    var onRevert: (() -> Void)?
    private var slide = MotionSpring(0), stack = MotionSpring(0)
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    private var theme = RiseTheme.neutral
    private(set) var question: PermissionQuestion?
    private(set) var isPresented = false
    /// The page bar's height, which the panel comes down from under.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    /// How far below Find's place it sits, clear of an open find panel.
    var stackOffset: CGFloat = 0 {
        didSet { guard stackOffset != oldValue else { return }; stack.target = stackOffset; if isPresented { animate() } else { stack.settle(); needsLayout = true } }
    }
    var answer: ((Bool) -> Void)?
    /// Once it has gone back under the bar, as far as anyone can see.
    var onGone: (() -> Void)?
    private var announcedGone = true

    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.cornerRadius = PageAppearance.radius; layer?.cornerCurve = .continuous
        isHidden = true
        FindBar.stylePanel(panel, content: content)
        icon.imageScaling = .scaleNone
        text.lineBreakMode = .byTruncatingTail; text.cell?.usesSingleLineMode = true
        // The toolbar's own hover hints, not the system's tooltip.
        setShortcuts(allow: KeyboardShortcut("Command+Alt+Enter")?.display ?? "", deny: KeyboardShortcut("Command+Alt+Backspace")?.display ?? "")
        allowButton.actionBlock = { [weak self] in self?.answer?(true) }
        denyButton.actionBlock = { [weak self] in self?.answer?(false) }
        revertButton.image = TablerIcon.revertImage()
        revertButton.actionBlock = { [weak self] in self?.onRevert?() }
        revertButton.isHidden = true
        [icon, text, allowButton, denyButton, revertButton].forEach(content.addSubview)
        panel.addSubview(content); addSubview(panel)
        panel.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        stack.configure(response: FindMotion.swapResponse, bounce: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    /// The pointer leaving the panel, for one held while it's on it.
    var onPointerExit: (() -> Void)?
    var isPointerInside: Bool {
        guard let window, !isHidden else { return false }
        return panel.bounds.contains(panel.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
    /// Allow and Don't Allow's hints, with the keys that answer while it shows.
    func setShortcuts(allow: String, deny: String, allowHint: String = "Allow", denyHint: String = "Don’t allow") {
        allowButton.setHoverHint(allowHint, shortcut: allow); denyButton.setHoverHint(denyHint, shortcut: deny)
    }

    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme
        FindBar.applyPanelTheme(panel, theme: theme)
        for button in [allowButton, denyButton, revertButton] {
            button.restingTint = theme.muted; button.hoverColor = theme.text.withAlphaComponent(0.07)
            button.hoverHint?.appearance = theme.appearance
        }
        allowButton.hoverTint = SiteCapability.camera.accent(theme); denyButton.hoverTint = SiteCapability.notifications.accent(theme)
        revertButton.hoverTint = SiteCapability.location.accent(theme)
        fill()
    }
    func ask(_ question: PermissionQuestion) { self.question = question; notice = nil; fill() }
    func tell(_ notice: Notice) { self.notice = notice; noticeAsks = false; question = nil; fill() }
    func offer(_ notice: Notice) { self.notice = notice; noticeAsks = true; question = nil; fill() }
    /// Revert's hint, with the key that reverts while it can.
    func setRevertShortcut(_ shortcut: String) { revertButton.setHoverHint("Revert", shortcut: shortcut) }
    private func fill() {
        allowButton.isHidden = !hasChoice; denyButton.isHidden = !hasChoice; revertButton.isHidden = hasChoice
        if let notice {
            icon.image = notice.image; icon.contentTintColor = notice.accent(theme)
            text.attributedStringValue = notice.text(theme, Self.font)
            panel.setAccessibilityLabel(notice.message)
            needsLayout = true
            return
        }
        guard let question else { return }
        icon.image = TablerIcon.image(question.icon, size: Self.iconSize, description: question.heading)
        icon.contentTintColor = question.capability.accent(theme)
        text.attributedStringValue = question.text(theme: theme, font: Self.font)
        panel.setAccessibilityLabel(question.message)
        allowButton.setAccessibilityLabel("Allow: \(question.message)")
        needsLayout = true
    }
    /// Its icon, the question in full where it fits, and the buttons.
    private var panelWidth: CGFloat {
        let words = ceil(text.attributedStringValue.size().width)+4
        let widest = max(FindBar.width, min(FindBar.width+140, bounds.width-2*FindBar.margin))
        return min(widest, Self.textX+words+10+(hasChoice ? Self.buttonsWidth : 26)+8)
    }

    // MARK: Presentation

    /// Comes down on the download tray's springs, as Find does.
    func present() {
        guard !isPresented else { return }
        isPresented = true; isHidden = false; announcedGone = false
        stack.settle()
        slide.configure(response: DownloadMotion.trayInResponse, bounce: DownloadMotion.trayInBounce)
        slide.target = 1; animate()
    }
    /// Goes back up under the bar, a little quicker, as Find does.
    func hide() {
        guard isPresented else { return }
        isPresented = false
        slide.configure(response: FindMotion.outResponse, bounce: DownloadMotion.trayOutBounce)
        slide.target = 0; animate()
    }
    /// Still on its way back up.
    var isLeaving: Bool { !isPresented && !announcedGone }
    var isMoving: Bool { link != nil }

    // MARK: Layout and motion

    override func layout() { super.layout(); render() }
    private func render() {
        let width = panelWidth, height = FindBar.rowHeight
        // Find's place, held down past an open find panel: the extra room is travel too, so it
        // still starts out of sight under the bar.
        var origin = FindBar.panelOrigin(in: bounds, width: width, height: height+stack.value, slide: slide.value, topInset: topInset, tuckedInset: topInset)
        origin.y += stack.value
        panel.frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        FindBar.tuck(self, under: topInset, panels: isHidden ? [] : [panel.frame])
        content.frame = panel.bounds
        icon.frame = NSRect(x: 12, y: (height-Self.iconSize)/2, width: Self.iconSize, height: Self.iconSize)
        let line = ceil(text.intrinsicContentSize.height)
        // As Find's chevrons and close.
        denyButton.frame = NSRect(x: width-8-26, y: (height-28)/2, width: 26, height: 28)
        allowButton.frame = NSRect(x: denyButton.frame.minX-27, y: denyButton.frame.minY, width: 26, height: 28)
        revertButton.frame = denyButton.frame
        let textEnd = hasChoice ? allowButton.frame.minX : revertButton.frame.minX
        text.frame = NSRect(x: Self.textX, y: (height-line)/2, width: max(0, textEnd-10-Self.textX), height: line)
        // The buttons slide under a still pointer; their hover follows.
        allowButton.refreshHoverState(); denyButton.refreshHoverState(); revertButton.refreshHoverState()
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
        slide.settle(); stack.settle(); render()
        if !isPresented { isHidden = true; goneIfOut() }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        slide.step(dt); stack.step(dt)
        if slide.isResting(within: 0.001) && stack.isResting(within: 0.05) { settle(); return }
        render()
        if panel.frame.maxY <= topInset+0.5 { goneIfOut() }
    }
    /// Out of sight under the bar before the spring has quite come to rest.
    private func goneIfOut() {
        guard !isPresented, !announcedGone else { return }
        announcedGone = true; onGone?()
    }
}
