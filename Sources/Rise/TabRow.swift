import AppKit
import RiseCore

@MainActor final class TabRow: NSButton, NSTextFieldDelegate {
    let tabID: UUID
    let icon = FaviconView(frame: .zero)
    let titleField = TabTitleField(frame: .zero)
    let subtitle = label("", size: 11, color: .secondaryLabelColor)
    let close: ChromeButton
    /// Plays or pauses the tab's YouTube video, beside the close button on hover.
    let playback = PlayPauseButton()
    /// Whether the tab's video is paused; nil when the tab shows no video.
    private(set) var playbackPaused: Bool?
    var onTogglePlayback: (() -> Void)?
    private var toggleConfirmationDeadline: CFTimeInterval = 0
    let subtitleAccessory = NSImageView(frame: .zero)
    let loadingBackground = TabLoadingBackground()
    var selected = false
    private(set) var configuration = TabRowConfiguration()
    var showsSubtitle: Bool { configuration.subtitle != nil }
    var rowHeight: CGFloat { showsSubtitle ? TabAppearance.subtitleRowHeight : TabAppearance.height }
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
    private var animateSubtitleLayout = false
    private var subtitleHideWork: DispatchWorkItem?
    init(tab: BrowserTab, onClose: @escaping () -> Void) {
        tabID = tab.id
        close = ChromeButton(symbol: "xmark", size: 13, title: "Close \(tab.title)", action: onClose)
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true; clipsToBounds = false
        layer?.cornerRadius = TabAppearance.radius; layer?.cornerCurve = .continuous
        target = self; action = #selector(selectTab)
        addSubview(loadingBackground); addSubview(icon); addSubview(titleField); addSubview(subtitle); addSubview(subtitleAccessory); addSubview(close); addSubview(playback)
        playback.pointSize = 11; playback.weight = .regular; playback.acceptsFirstClick = false; playback.isHidden = true
        playback.action = { [weak self] in
            guard let self, let paused = self.playbackPaused else { return }
            // Shows the new state at once; the page's report confirms or corrects it.
            self.setPlayback(paused: !paused, confirmed: true)
            self.toggleConfirmationDeadline = CACurrentMediaTime()+1
            self.onTogglePlayback?()
        }
        subtitleAccessory.imageScaling = .scaleNone; subtitleAccessory.isHidden = true
        subtitleAccessory.setAccessibilityElement(false)
        icon.wantsLayer = true; subtitle.wantsLayer = true; subtitle.alphaValue = 0
        titleField.delegate = self; titleField.focusRingType = .none
        titleField.cell?.usesSingleLineMode = true
        setAccessibilityLabel(tab.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc func selectTab() { onSelect?() }
    func update(tab: BrowserTab, selected: Bool, theme: RiseTheme, configuration: TabRowConfiguration) {
        let previouslyShowedSubtitle = showsSubtitle
        self.selected = selected; self.theme = theme; self.configuration = configuration
        if previouslyShowedSubtitle != showsSubtitle {
            subtitleHideWork?.cancel(); subtitleHideWork = nil
            animateSubtitleLayout = hasLaidOut && window?.isVisible == true && !isRenaming && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        if !isRenaming { titleField.stringValue = tab.title }
        titleField.textColor = TabAppearance.text(theme, selected: selected)
        subtitle.textColor = theme.muted
        if let detail = configuration.subtitle {
            subtitle.attributedStringValue = detail.attributedString(font: subtitle.font ?? .systemFont(ofSize: 11), defaultColor: theme.muted)
        }
        if showsSubtitle { subtitle.isHidden = false }
        if !animateSubtitleLayout && subtitleHideWork == nil {
            subtitle.alphaValue = showsSubtitle ? 1 : 0; subtitle.isHidden = !showsSubtitle
        }
        if let favicon = tab.favicon(for: theme) { icon.image = favicon }
        else if tab.url?.host == "news.ycombinator.com" {
            let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(hex: 0xFF6600).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                ("Y" as NSString).draw(at: NSPoint(x: 4, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]); return true
            }; icon.image = image
        } else { icon.showEmptyPlaceholder(theme: theme) }
        icon.contentTintColor = theme.sidebarIcon
        subtitleAccessory.image = configuration.subtitleAccessory
        subtitleAccessory.contentTintColor = theme.sidebarIcon
        close.contentTintColor = theme == .dark ? NSColor.white.withAlphaComponent(0.8) : theme.sidebarIcon
        close.hoverColor = theme == .dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
        playback.color = close.contentTintColor ?? theme.sidebarIcon; playback.hoverColor = close.hoverColor
        setAccessibilityLabel(tab.title + (configuration.subtitle.map { ", \($0.text)" } ?? "") + (selected ? ", selected" : ""))
        close.toolTip = "Close \(tab.title)"
        loadingBackground.update(loading: tab.isLoading, progress: tab.isPreparingNavigation ? 0.05 : tab.webView.estimatedProgress, theme: theme)
        style(); needsLayout = true; needsDisplay = true
    }
    /// The page's state. After a press, only its answer (`confirmed`) replaces
    /// the button's new state for a moment, so an earlier report cannot undo it.
    func setPlayback(paused: Bool?, confirmed: Bool = false) {
        if confirmed { toggleConfirmationDeadline = 0 }
        else if paused != nil, CACurrentMediaTime() < toggleConfirmationDeadline { return }
        let wasShown = playbackPaused != nil
        playbackPaused = paused
        if let paused { playback.setPaused(paused, animated: !playback.isHidden) }
        playback.setAccessibilityLabel(paused == true ? "Play video" : "Pause video")
        if wasShown != (paused != nil) { style() }
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
        playback.isHidden = close.isHidden || playbackPaused == nil
        if !playback.isHidden { playback.refreshHover() }
        subtitleAccessory.isHidden = !showsSubtitle || configuration.subtitleAccessory == nil || hover || isSplitMember
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let animated = animateSubtitleLayout
        animateSubtitleLayout = false; hasLaidOut = bounds.width > 0 && bounds.height > 0
        let time = CACurrentMediaTime()
        let subtitleOpacity = subtitle.layer?.presentation()?.opacity ?? Float(subtitle.alphaValue)
        loadingBackground.frame = bounds
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let textHeight = showsSubtitle ? titleHeight + 1 + subtitleHeight : titleHeight
        let textY = (bounds.height - textHeight) / 2
        let textX: CGFloat = isSplitMember ? 28 : 30
        let textWidth = max(0, bounds.width - textX - (close.isHidden ? 8 : playback.isHidden ? 32 : 58))
        TabListMotion.move(titleField, to: NSRect(x: textX, y: textY, width: textWidth, height: titleHeight), animated: animated, at: time)
        let subtitleWidth = max(0, textWidth - (subtitleAccessory.isHidden ? 0 : 24))
        titleField.setFadeBoundary(subtitleAccessory.isHidden ? nil : subtitleWidth)
        let subtitleY = showsSubtitle ? textY + titleHeight + 1 : max(0, bounds.height-subtitleHeight-2)
        let iconX: CGFloat = isSplitMember ? 6 : 8
        let iconY = showsSubtitle ? textY + (titleHeight-16)/2 + 2 : (bounds.height-16)/2
        TabListMotion.move(icon, to: NSRect(x: iconX, y: iconY, width: 16, height: 16), animated: animated, at: time)
        let subtitleFrame = NSRect(x: textX, y: subtitleY, width: subtitleWidth, height: subtitleHeight)
        if animated && showsSubtitle && subtitleOpacity == 0 { subtitle.frame = subtitleFrame.offsetBy(dx: 0, dy: -2) }
        TabListMotion.move(subtitle, to: subtitleFrame, animated: animated, at: time)
        if animated {
            subtitle.isHidden = false
            DeveloperModeMotion.fade(subtitle, from: subtitleOpacity, to: showsSubtitle ? 1 : 0, at: time)
            if !showsSubtitle {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.showsSubtitle else { return }
                    self.subtitle.isHidden = true; self.subtitleHideWork = nil
                }
                subtitleHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now()+DeveloperModeMotion.duration, execute: work)
            }
        }
        close.frame = NSRect(x: bounds.width-28.5, y: (bounds.height-24)/2-0.5, width: 24, height: 24)
        playback.frame = close.frame.offsetBy(dx: -26, dy: 0)
        let accessorySize = subtitleAccessory.image?.size ?? .zero
        subtitleAccessory.frame = NSRect(x: close.frame.midX - accessorySize.width/2,
            y: close.frame.midY - accessorySize.height/2, width: accessorySize.width, height: accessorySize.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        // The layer and child views draw this custom row, without a button bezel.
        if selected && configuration.constructionBorder {
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
        if !playback.isHidden && playback.frame.contains(local) { return playback }
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
