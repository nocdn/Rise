import AppKit
import RiseCore

@MainActor final class TabRow: NSButton, NSTextFieldDelegate {
    let tabID: UUID
    let icon = FaviconView(frame: .zero)
    let titleField = TabTitleField(frame: .zero)
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
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private var pressEvent: NSEvent?
    private var dragging = false
    private(set) var isRenaming = false
    private var originalTitle = ""
    private var hover = false
    private var hasLaidOut = false
    private var animateDeveloperLayout = false
    private var subtitleHideWork: DispatchWorkItem?
    init(tab: BrowserTab, onClose: @escaping () -> Void) {
        tabID = tab.id
        close = ChromeButton(symbol: "xmark", size: 13, title: "Close \(tab.title)", action: onClose)
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true; clipsToBounds = false
        layer?.cornerRadius = TabAppearance.radius; layer?.cornerCurve = .continuous
        target = self; action = #selector(selectTab)
        addSubview(loadingBackground); addSubview(icon); addSubview(titleField); addSubview(subtitle); addSubview(close)
        icon.wantsLayer = true; subtitle.wantsLayer = true; subtitle.alphaValue = 0
        titleField.delegate = self; titleField.focusRingType = .none
        titleField.cell?.usesSingleLineMode = true
        setAccessibilityLabel(tab.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc func selectTab() { onSelect?() }
    func update(tab: BrowserTab, selected: Bool, theme: RiseTheme) {
        let changedDeveloper = developer != tab.developer
        if changedDeveloper {
            subtitleHideWork?.cancel(); subtitleHideWork = nil
            animateDeveloperLayout = hasLaidOut && window?.isVisible == true && !isRenaming && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        self.selected = selected; self.theme = theme; developer = tab.developer
        if !isRenaming { titleField.stringValue = tab.title }
        titleField.textColor = TabAppearance.text(theme, selected: selected)
        subtitle.stringValue = AddressResolver.displayHost(tab.url) + (tab.url?.port.map { ":\($0)" } ?? "")
        subtitle.textColor = theme.muted
        if developer { subtitle.isHidden = false }
        if !animateDeveloperLayout && subtitleHideWork == nil {
            subtitle.alphaValue = developer ? 1 : 0; subtitle.isHidden = !developer
        }
        if let favicon = tab.favicon(for: theme) { icon.image = favicon }
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
        icon.contentTintColor = theme.sidebarIcon
        close.contentTintColor = theme == .dark ? NSColor.white.withAlphaComponent(0.8) : theme.sidebarIcon
        close.hoverColor = theme == .dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
        setAccessibilityLabel(tab.title + (selected ? ", selected" : ""))
        close.toolTip = "Close \(tab.title)"
        loadingBackground.update(loading: tab.isLoading, progress: tab.isPreparingNavigation ? 0.05 : tab.webView.estimatedProgress, theme: theme)
        style(); needsLayout = true; needsDisplay = true
    }
    func style() {
        layer?.cornerRadius = isSplitMember ? 8 : TabAppearance.radius
        loadingBackground.layer?.cornerRadius = isSplitMember ? 8 : TabAppearance.radius
        loadingBackground.layer?.cornerCurve = .continuous
        layer?.backgroundColor = (selected ? (isSplitMember ? theme.pill : TabAppearance.selectedFill(theme)) : hover ? TabAppearance.hoverFill(theme) : .clear).cgColor
        // The border follows the same continuous contour as the background.
        layer?.borderColor = NSColor.white.withAlphaComponent(theme == .dark ? 0.08 : 0.7).cgColor
        layer?.borderWidth = selected && !isSplitMember ? 0.5 : 0
        close.isHidden = !hover || isSplitMember
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let animated = animateDeveloperLayout
        animateDeveloperLayout = false; hasLaidOut = bounds.width > 0 && bounds.height > 0
        let time = CACurrentMediaTime()
        let subtitleOpacity = subtitle.layer?.presentation()?.opacity ?? Float(subtitle.alphaValue)
        loadingBackground.frame = bounds
        TabListMotion.move(icon, to: NSRect(x: isSplitMember ? 6 : 8, y: (bounds.height-16)/2, width: 16, height: 16), animated: animated, at: time)
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let textHeight = developer ? titleHeight + 1 + subtitleHeight : titleHeight
        let textY = (bounds.height - textHeight) / 2
        let textX: CGFloat = isSplitMember ? 28 : 30
        let textWidth = max(0, bounds.width - textX - (close.isHidden ? 8 : 32))
        TabListMotion.move(titleField, to: NSRect(x: textX, y: textY, width: textWidth, height: titleHeight), animated: animated, at: time)
        let subtitleY = developer ? textY + titleHeight + 1 : max(0, bounds.height-subtitleHeight-2)
        let subtitleFrame = NSRect(x: textX, y: subtitleY, width: textWidth, height: subtitleHeight)
        if animated && developer && subtitleOpacity == 0 { subtitle.frame = subtitleFrame.offsetBy(dx: 0, dy: -2) }
        TabListMotion.move(subtitle, to: subtitleFrame, animated: animated, at: time)
        if animated {
            subtitle.isHidden = false
            DeveloperModeMotion.fade(subtitle, from: subtitleOpacity, to: developer ? 1 : 0, at: time)
            if !developer {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.developer else { return }
                    self.subtitle.isHidden = true; self.subtitleHideWork = nil
                }
                subtitleHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now()+DeveloperModeMotion.duration, execute: work)
            }
        }
        close.frame = NSRect(x: bounds.width-28.5, y: (bounds.height-24)/2-0.5, width: 24, height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        // The layer and child views draw this custom row, without a button bezel.
        if selected && developer {
            let radius: CGFloat = isSplitMember ? 8 : TabAppearance.radius
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), xRadius: radius, yRadius: radius)
            let scale = TabAppearance.height / 37
            NSColor(hex: 0xFFD73D).setStroke(); path.lineWidth = 2*scale; path.stroke()
            NSColor(hex: 0x332D25).setStroke(); path.setLineDash([5*scale, 6*scale], count: 2, phase: 0); path.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; style(); onHover?(true) }
    override func mouseExited(with event: NSEvent) { if pressEvent == nil { hover = false; style() }; onHover?(false) }
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
        onPress?()
        guard event.clickCount < 2 else {
            cancelPress(); beginRename(); return
        }
        if isRenaming { finishRename(save: true) }
        pressEvent = event; dragging = false
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
    func cancelPress() {
        pressEvent = nil; dragging = false
    }
    func beginRename() {
        guard !isRenaming else { return }
        onSelect?()
        titleField.layer?.removeAnimation(forKey: TabListMotion.movementKey)
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
