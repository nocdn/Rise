import AppKit
import RiseCore

@MainActor final class TabRow: NSButton, NSTextFieldDelegate {
    let tabID: UUID
    let icon = NSImageView()
    let titleField = label("", size: 13)
    let subtitle = label("", size: 11, color: .secondaryLabelColor)
    let close: ChromeButton
    let loadingBackground = TabLoadingBackground()
    var selected = false
    var developer = false
    var isSplitMember = false
    var theme = RiseTheme.neutral
    var onSelect: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onRename: ((String) -> Void)?
    var onPress: ((Bool, Bool) -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private var pressEvent: NSEvent?
    private var dragging = false
    private(set) var isRenaming = false
    private var originalTitle = ""
    private var hover = false
    init(tab: BrowserTab, onClose: @escaping () -> Void) {
        tabID = tab.id
        close = ChromeButton(symbol: "xmark", size: 10, title: "Close \(tab.title)", action: onClose)
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true; clipsToBounds = false
        layer?.cornerRadius = 12; layer?.cornerCurve = .continuous
        target = self; action = #selector(selectTab)
        addSubview(loadingBackground); addSubview(icon); addSubview(titleField); addSubview(subtitle); addSubview(close)
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleField.delegate = self; titleField.focusRingType = .none
        titleField.cell?.usesSingleLineMode = true
        setAccessibilityLabel(tab.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc func selectTab() { onSelect?() }
    func update(tab: BrowserTab, selected: Bool, theme: RiseTheme) {
        self.selected = selected; self.theme = theme; developer = tab.developer
        if !isRenaming { titleField.stringValue = tab.title }
        titleField.textColor = selected ? theme.selectedText : theme.text
        subtitle.stringValue = AddressResolver.displayHost(tab.url) + (tab.url?.port.map { ":\($0)" } ?? "")
        subtitle.textColor = theme.muted; subtitle.isHidden = !developer
        if let favicon = tab.favicon { icon.image = favicon }
        else if AddressResolver.isLocal(tab.url) {
            icon.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(hex: 0xEAA8B3).setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill(); return true
            }
        }
        else if tab.url?.host == "news.ycombinator.com" {
            let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(hex: 0xFF6600).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                ("Y" as NSString).draw(at: NSPoint(x: 4, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]); return true
            }; icon.image = image
        } else { icon.image = NSImage(systemSymbolName: tab.pinned ? "pin.fill" : "globe", accessibilityDescription: nil) }
        icon.contentTintColor = theme.muted
        close.contentTintColor = theme.muted
        close.hoverColor = theme == .dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
        setAccessibilityLabel(tab.title + (selected ? ", selected" : ""))
        close.toolTip = "Close \(tab.title)"
        loadingBackground.update(loading: tab.isLoading, progress: tab.isPreparingNavigation ? 0.05 : tab.webView.estimatedProgress, theme: theme)
        style(); needsLayout = true; needsDisplay = true
    }
    func style() {
        layer?.cornerRadius = isSplitMember ? 8 : 12
        layer?.backgroundColor = (selected ? (isSplitMember ? theme.pill : theme.selectedTab) : hover ? theme.hoveredTab : .clear).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(selected ? (theme == .dark ? 0.08 : 0.7) : 0).cgColor
        layer?.borderWidth = selected && !isSplitMember ? 0.5 : 0
        close.isHidden = !hover || isSplitMember
    }
    override func layout() {
        super.layout()
        loadingBackground.frame = bounds
        icon.frame = NSRect(x: isSplitMember ? 6 : 10, y: (bounds.height-16)/2, width: 16, height: 16)
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let textHeight = developer ? titleHeight + 1 + subtitleHeight : titleHeight
        let textY = (bounds.height - textHeight) / 2
        let textX: CGFloat = isSplitMember ? 30 : 34
        let textWidth = max(0, bounds.width - (isSplitMember ? 38 : 62))
        titleField.frame = NSRect(x: textX, y: textY, width: textWidth, height: titleHeight)
        subtitle.frame = NSRect(x: textX, y: textY + titleHeight + 1, width: textWidth, height: subtitleHeight)
        close.frame = NSRect(x: bounds.width-30, y: (bounds.height-24)/2, width: 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected && developer {
            let radius: CGFloat = isSplitMember ? 8 : 12
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), xRadius: radius, yRadius: radius)
            NSColor(hex: 0xFFD73D).setStroke(); path.lineWidth = 2; path.stroke()
            NSColor(hex: 0x332D25).setStroke(); path.setLineDash([5, 6], count: 2, phase: 0); path.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; style() }
    override func mouseExited(with event: NSEvent) { if pressEvent == nil { hover = false; style() } }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !close.isHidden && close.frame.contains(local) { return close.hitTest(local) }
        if isRenaming && titleField.frame.contains(local) { return titleField.hitTest(local) }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            cancelPress(animated: false); beginRename(); return
        }
        if isRenaming { finishRename(save: true) }
        pressEvent = event; dragging = false; onPress?(true, true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressEvent else { return }
        if !dragging && abs(event.locationInWindow.y-pressEvent.locationInWindow.y) >= 3 {
            dragging = true; onDragStart?(pressEvent)
        }
        if dragging { onDragMove?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        let wasDragging = dragging
        cancelPress()
        hover = bounds.contains(convert(event.locationInWindow, from: nil)); style()
        if wasDragging { onDragEnd?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }
    func cancelPress(animated: Bool = true) {
        pressEvent = nil; dragging = false; onPress?(false, animated)
    }
    func beginRename() {
        guard !isRenaming else { return }
        onSelect?(); onPress?(false, false)
        originalTitle = titleField.stringValue; isRenaming = true
        titleField.isEditable = true; titleField.isSelectable = true
        titleField.selectText(nil)
    }
    func finishRename(save: Bool) {
        guard isRenaming else { return }
        let value = (titleField.currentEditor()?.string ?? titleField.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        window?.makeFirstResponder(nil)
        titleField.isEditable = false; titleField.isSelectable = false
        titleField.stringValue = save && !value.isEmpty ? value : originalTitle
        if save && !value.isEmpty { onRename?(value) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishRename(save: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishRename(save: false); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishRename(save: true) }
}
