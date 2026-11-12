import AppKit
import RiseCore

@MainActor final class TabRow: NSButton, NSTextFieldDelegate {
    let tabID: UUID
    let icon = FaviconView(frame: .zero)
    let titleField = TabTitleField(frame: .zero)
    let subtitle = label("", size: 11, color: .secondaryLabelColor)
    let close: ChromeButton
    /// Plays or pauses the tab's media, beside the close button on hover.
    let playback = PlayPauseButton()
    /// Whether the tab's media is paused; nil when the tab has none.
    private(set) var playbackPaused: Bool?
    var onTogglePlayback: (() -> Void)?
    /// Between the favicon and the title while the tab plays sound or is muted.
    let audio = TabAudioButton()
    let peekIndicator = PeekFaviconIndicator(frame: .zero)
    /// After the title: when a Calendar tab's next event starts, such as "in 17m".
    let badge = TabBadge()
    private(set) var badgeText: String?
    private(set) var showsPeek = false
    private(set) var showsAudio = false
    var onToggleMute: (() -> Void)?
    private var audioHideWork: DispatchWorkItem?
    private var slideText = false
    private var toggleConfirmationDeadline: CFTimeInterval = 0
    let subtitleAccessory = NSImageView(frame: .zero)
    /// Kero's chosen row and hover, fading.
    let plainBackground = PlainTabBackground()
    /// Developer mode's yellow and black border, over the chosen tab's card.
    let constructionBorder = ConstructionBorder()
    /// The find bar's shimmer over the title, for Smart Rename.
    let titleShimmer = InputShimmer()
    var selected = false
    private(set) var configuration = TabRowConfiguration()
    var showsSubtitle: Bool { configuration.subtitle != nil }
    var rowHeight: CGFloat { showsSubtitle ? TabAppearance.subtitleRowHeight : TabAppearance.height }
    var isSplitMember = false {
        didSet {
            guard isSplitMember != oldValue else { return }
            // Half a row is narrower, so its close button is smaller too.
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: close.toolTip)?
                .withSymbolConfiguration(.init(pointSize: isSplitMember ? Self.splitCloseSymbol : 13, weight: .regular))
            close.layer?.cornerRadius = isSplitMember ? 5 : 6
            style()
        }
    }
    static let splitCloseSize: CGFloat = 20, splitCloseSymbol: CGFloat = 11
    var theme = RiseTheme.neutral
    var dragFill: NSColor? { didSet { style() } }
    var onSelect: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onRename: ((String) -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private var pressEvent: NSEvent?
    private var dragging = false
    private(set) var isRenaming = false
    private var originalTitle = ""
    private var hover = false
    /// Chosen with the arrow keys while searching tabs: lit as a hovered row is, close button aside.
    var isKeyboardFocused = false { didSet { if isKeyboardFocused != oldValue { style() } } }
    /// Nil follows the pointer; while scroll-choosing, only its candidate has the hover fill.
    var scrollFocus: Bool? {
        didSet {
            guard scrollFocus != oldValue else { return }
            if scrollFocus != nil { setHovered(false) }
            style()
        }
    }
    /// While searching tabs, the pointer lights a row by focusing it, as the arrow keys do, so
    /// only one row is ever lit: the one the pointer or the keys moved to last.
    var hoverFocuses = false { didSet { if hoverFocuses != oldValue { style() } } }
    var onPointerMove: (() -> Void)?
    /// AppKit turns a button's clipping back on; the chosen row draws its ring and shadow
    /// just outside it.
    override var clipsToBounds: Bool { get { false } set {} }
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
        addSubview(plainBackground); addSubview(constructionBorder); addSubview(icon); addSubview(titleField); addSubview(subtitle); addSubview(subtitleAccessory); addSubview(close); addSubview(playback); addSubview(audio)
        addSubview(peekIndicator, positioned: .below, relativeTo: close)
        addSubview(badge); badge.isHidden = true
        peekIndicator.isHidden = true; peekIndicator.alphaValue = 0
        audio.acceptsFirstClick = false; audio.isHidden = true; audio.alphaValue = 0
        audio.action = { [weak self] in
            guard let self else { return }
            self.audio.setMuted(!self.audio.muted, animated: true); self.onToggleMute?()
        }
        playback.pointSize = 11; playback.weight = .regular
        // The symbol's bars are 2.5 by 9.4 pt with 0.55 pt corners: these are a touch slimmer, taller and squarer.
        playback.pauseBars = .init(width: 2.3, height: 9.9, radius: 0.4, spacing: 4.125)
        playback.acceptsFirstClick = false; playback.isHidden = true
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
        // Inside the title, so its fading edge fades the shimmer too.
        titleShimmer.configureForSmartRename(field: titleField)
        setAccessibilityLabel(tab.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc func selectTab() { onSelect?() }
    var isHovered: Bool { hover }
    /// Shimmers the title for a few sweeps, then eases it back to its own color.
    func shimmerTitle() {
        guard !isRenaming else { return }
        titleShimmer.startSmartRename()
    }
    /// What the row last showed. Rows are updated on every change to any tab, and each update
    /// redraws the row, so an unchanged row is left alone: redrawing them all made the commit that
    /// starts a close's slide heavy enough to miss its first frames.
    private struct Shown: Equatable {
        var title: String, selected: Bool, theme: RiseTheme, renaming: Bool, splitMember: Bool
        var subtitle: String?, subtitleColor: NSColor?, subtitleRange: NSRange?, subtitleIcon: ObjectIdentifier?, constructionBorder: Bool
        var accessory: ObjectIdentifier?, peekIcon: ObjectIdentifier?, peekTitle: String?
        var favicon: ObjectIdentifier?, host: String?
        var playing: Bool, muted: Bool, loading: Bool, progress: Double, hardReloading: Bool
    }
    private var shown: Shown?
    func update(tab: BrowserTab, selected: Bool, theme: RiseTheme, configuration: TabRowConfiguration) {
        let now = Shown(title: tab.title, selected: selected, theme: theme, renaming: isRenaming, splitMember: isSplitMember,
                        subtitle: configuration.subtitle?.text, subtitleColor: configuration.subtitle?.color,
                        subtitleRange: configuration.subtitle?.highlightRange, subtitleIcon: configuration.subtitle?.icon.map(ObjectIdentifier.init),
                        constructionBorder: configuration.constructionBorder,
                        accessory: configuration.subtitleAccessory.map(ObjectIdentifier.init),
                        peekIcon: configuration.peek?.favicon.map(ObjectIdentifier.init), peekTitle: configuration.peek?.title,
                        favicon: tab.favicon(for: theme).map(ObjectIdentifier.init), host: tab.url?.host,
                        playing: tab.isPlayingAudio, muted: tab.isAudioMuted, loading: tab.isLoading,
                        progress: tab.page.estimatedProgress, hardReloading: tab.isHardReloading)
        guard now != shown else { return }
        shown = now
        let previouslyShowedSubtitle = showsSubtitle
        self.selected = selected; self.theme = theme; self.configuration = configuration
        if previouslyShowedSubtitle != showsSubtitle {
            subtitleHideWork?.cancel(); subtitleHideWork = nil
            animateSubtitleLayout = hasLaidOut && window?.isVisible == true && !isRenaming && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        if !isRenaming { titleField.stringValue = tab.title }
        let titleColor = TabAppearance.text(theme, selected: selected)
        if titleShimmer.isRunning { titleShimmer.setRestingColor(titleColor) } else { titleField.textColor = titleColor }
        titleShimmer.baseColor = theme.muted; titleShimmer.bandColor = theme.selectedText
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
        audio.color = playback.color; audio.hoverColor = close.hoverColor
        setAudio(playing: tab.isPlayingAudio, muted: tab.isAudioMuted)
        badge.apply(theme, selected: selected)
        setPeek(configuration.peek)
        setAccessibilityLabel(tab.title + (configuration.subtitle.map { ", \($0.text)" } ?? "") + (configuration.pullRequestState.map { ", \($0.title)" } ?? "") + (configuration.peek.map { ", Peek: \($0.title)" } ?? "") + (selected ? ", selected" : ""))
        close.toolTip = "Close \(tab.title)"
        style(); needsLayout = true; needsDisplay = true
    }
    func setBadge(_ text: String?) {
        guard text != badgeText else { return }
        let appearing = badgeText == nil && text != nil
        badgeText = text
        if let text { badge.text = text }
        setAccessibilityValue(text)
        if appearing, hasLaidOut, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            badge.alphaValue = 0; slideText = false
            needsLayout = true; layoutSubtreeIfNeeded()
            TabListMotion.fadeAccessory(badge, visible: true, animated: true) {}
        } else { badge.alphaValue = 1; needsLayout = true }
    }
    /// Shows the button while the tab plays sound or is muted. It stays a
    /// moment after the sound stops, so a brief pause does not move the title.
    func setAudio(playing: Bool, muted: Bool) {
        audio.setMuted(muted, animated: showsAudio)
        if playing || muted {
            audioHideWork?.cancel(); audioHideWork = nil
            setShowsAudio(true)
        } else if showsAudio, audioHideWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.audioHideWork = nil; self?.setShowsAudio(false) }
            audioHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now()+Self.audioHideDelay, execute: work)
        }
    }
    static let audioHideDelay: TimeInterval = 1.5
    private func setShowsAudio(_ shows: Bool) {
        guard shows != showsAudio else { return }
        showsAudio = shows
        let animated = hasLaidOut && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        slideText = animated
        if shows { audio.isHidden = isSplitMember }
        TabListMotion.fadeAccessory(audio, visible: shows, animated: animated) { [weak self] in
            if let self, !self.showsAudio { self.audio.isHidden = true }
        }
        needsLayout = true
        if shows { audio.refreshHover() }
    }
    private func setPeek(_ peek: TabRowConfiguration.Peek?) {
        if let peek { peekIndicator.update(image: peek.favicon, theme: theme) }
        let shows = peek != nil
        guard shows != showsPeek else { return }
        showsPeek = shows
        let animated = hasLaidOut && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shows { peekIndicator.isHidden = false }
        TabListMotion.fadeAccessory(peekIndicator, visible: shows, animated: animated) { [weak self] in
            if let self, !self.showsPeek { self.peekIndicator.isHidden = true }
        }
        needsLayout = true
    }
    /// The page's state. After a press, only its answer (`confirmed`) replaces
    /// the button's new state for a moment, so an earlier report cannot undo it.
    func setPlayback(paused: Bool?, confirmed: Bool = false) {
        if confirmed { toggleConfirmationDeadline = 0 }
        else if paused != nil, CACurrentMediaTime() < toggleConfirmationDeadline { return }
        let wasShown = playbackPaused != nil
        playbackPaused = paused
        if let paused { playback.setPaused(paused, animated: !playback.isHidden) }
        playback.setAccessibilityLabel(paused == true ? "Play" : "Pause")
        if wasShown != (paused != nil) { style() }
    }
    func style() {
        layer?.cornerRadius = isSplitMember ? 8 : TabAppearance.radius
        // The chosen row and hover are their own layers, fading; a dragged row keeps its fill.
        // A split's halves are inside its row's, so theirs are plain fills.
        let plain = !isSplitMember, lit = scrollFocus ?? (hover && !hoverFocuses || isKeyboardFocused)
        plainBackground.isHidden = !plain
        let background = (plain ? (selected ? nil : dragFill) ?? .clear
            : selected ? theme.pill : dragFill ?? (lit ? TabAppearance.hoverFill(theme) : .clear)).cgColor
        if layer?.backgroundColor != background { layer?.removeAnimation(forKey: TabDragMotion.backgroundKey) }
        layer?.backgroundColor = background
        if plain {
            plainBackground.radius = layer?.cornerRadius ?? TabAppearance.radius; plainBackground.dark = theme == .dark
            plainBackground.show(chosen: selected, hovered: lit && !selected && dragFill == nil, animated: hasLaidOut && window != nil)
        }
        close.isHidden = !hover
        // A split half has room for its close button only.
        playback.isHidden = close.isHidden || playbackPaused == nil || isSplitMember
        if !playback.isHidden { playback.refreshHover() }
        subtitleAccessory.isHidden = configuration.subtitleAccessory == nil || hover || isSplitMember || showsPeek
        constructionBorder.isHidden = !(selected && configuration.constructionBorder)
        constructionBorder.radius = isSplitMember ? 8 : TabAppearance.radius
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let animated = animateSubtitleLayout
        animateSubtitleLayout = false; hasLaidOut = bounds.width > 0 && bounds.height > 0
        let time = CACurrentMediaTime()
        let subtitleOpacity = subtitle.layer?.presentation()?.opacity ?? Float(subtitle.alphaValue)
        plainBackground.frame = bounds; constructionBorder.frame = bounds
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        let subtitleHeight = ceil(subtitle.intrinsicContentSize.height)
        let textHeight = showsSubtitle ? titleHeight + 1 + subtitleHeight : titleHeight
        let textY = (bounds.height - textHeight) / 2
        let slide = slideText; slideText = false
        // The audio button takes the 24 points after the favicon; split rows have no room for it.
        let audioWidth: CGFloat = showsAudio && !isSplitMember ? 24 : 0
        let textX: CGFloat = (isSplitMember ? 28 : 30) + audioWidth
        func place(_ view: NSView, _ frame: NSRect) {
            if slide { TabListMotion.slide(view, to: frame) } else { TabListMotion.move(view, to: frame, animated: animated) }
        }
        let closeRoom: CGFloat = isSplitMember ? Self.splitCloseSize+6 : 32
        let trailingRoom: CGFloat = close.isHidden ? (showsPeek ? closeRoom : 8) : (playback.isHidden ? closeRoom : 58) + (showsPeek ? 26 : 0)
        let textWidth = max(0, bounds.width - textX - trailingRoom)
        let badgeSize = badge.fittingSize
        let showsBadge = badgeText != nil && !isRenaming && !isSplitMember && textWidth >= badgeSize.width+40
        badge.isHidden = !showsBadge
        if showsBadge {
            // The pill follows the title's text, which gives up its room first.
            let titleWidth = min(ceil(titleField.attributedStringValue.size().width)+2, textWidth-badgeSize.width-6)
            place(titleField, NSRect(x: textX, y: textY, width: titleWidth, height: titleHeight))
            place(badge, NSRect(x: textX+titleWidth+4, y: (textY+(titleHeight-badgeSize.height)/2).rounded(),
                                width: badgeSize.width, height: badgeSize.height))
        } else {
            place(titleField, NSRect(x: textX, y: textY, width: textWidth, height: titleHeight))
        }
        let subtitleWidth = max(0, textWidth - (subtitleAccessory.isHidden ? 0 : 24))
        titleField.setFadeBoundary(subtitleAccessory.isHidden ? nil : subtitleWidth)
        let subtitleY = showsSubtitle ? textY + titleHeight + 1 : max(0, bounds.height-subtitleHeight-2)
        let iconX: CGFloat = isSplitMember ? 6 : 8
        let iconY = showsSubtitle ? textY + (titleHeight-16)/2 + 2 : (bounds.height-16)/2
        TabListMotion.move(icon, to: NSRect(x: iconX, y: iconY, width: 16, height: 16), animated: animated)
        let subtitleFrame = NSRect(x: textX, y: subtitleY, width: subtitleWidth, height: subtitleHeight)
        if animated && showsSubtitle && subtitleOpacity == 0 { subtitle.frame = subtitleFrame.offsetBy(dx: 0, dy: -2) }
        place(subtitle, subtitleFrame)
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
        let normalClose = isSplitMember
            ? NSRect(x: bounds.width-Self.splitCloseSize-4, y: (bounds.height-Self.splitCloseSize)/2, width: Self.splitCloseSize, height: Self.splitCloseSize)
            : NSRect(x: bounds.width-28.5, y: (bounds.height-24)/2-0.5, width: 24, height: 24)
        let closeFrame = normalClose.offsetBy(dx: showsPeek ? -26 : 0, dy: 0)
        let animatesAccessories = hasLaidOut && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (view, frame) in [(close as NSView, closeFrame), (playback, closeFrame.offsetBy(dx: -26, dy: 0))] {
            if animatesAccessories && hover && view.frame.size == frame.size {
                TabListMotion.slide(view, to: frame)
            } else {
                view.layer?.removeAnimation(forKey: TabListMotion.slideKey)
                view.frame = frame
            }
        }
        let peekFrame = NSRect(x: normalClose.midX-PeekFaviconIndicator.side/2, y: normalClose.midY-PeekFaviconIndicator.side/2,
                               width: PeekFaviconIndicator.side, height: PeekFaviconIndicator.side)
        peekIndicator.frame = peekFrame
        audio.frame = NSRect(x: iconX+21, y: (iconY+8-12).rounded(), width: 24, height: 24)
        let accessorySize = subtitleAccessory.image?.size ?? .zero
        subtitleAccessory.frame = NSRect(x: close.frame.midX - accessorySize.width/2,
            y: close.frame.midY - accessorySize.height/2, width: accessorySize.width, height: accessorySize.height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        refreshHover()
    }
    private func setHovered(_ hovered: Bool) {
        let hovered = scrollFocus == nil && hovered
        guard hover != hovered else { return }
        hover = hovered; style(); onHover?(hovered)
    }
    /// Moving or releasing a row can leave its tracking state at the old geometry.
    func refreshHover(at location: NSPoint? = nil) {
        guard pressEvent == nil else { return }
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { setHovered(false); return }
        let location = location ?? window.mouseLocationOutsideOfEventStream
        setHovered(visibleRect.intersection(bounds).contains(convert(location, from: nil)) && isFrontmost(at: location))
    }
    /// Only where the row is in front: under the current-tab pill, or anything else over the list,
    /// it isn't hovered, as tracking areas report the pointer either way.
    override func mouseEntered(with event: NSEvent) {
        setHovered(takesPointer(event)); if hover { onPointerMove?() }
    }
    override func mouseMoved(with event: NSEvent) {
        setHovered(takesPointer(event)); if hover { onPointerMove?() }
    }
    private func takesPointer(_ event: NSEvent) -> Bool { window == nil || isFrontmost(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { if pressEvent == nil { setHovered(false) } else { onHover?(false) } }
    override func rightMouseDown(with event: NSEvent) { onPress?(); onMenu?(event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !close.isHidden && close.frame.contains(local) { return close.hitTest(local) }
        if !playback.isHidden && playback.frame.contains(local) { return playback }
        if showsAudio && !audio.isHidden && audio.frame.contains(local) { return audio }
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
        if !dragging && (abs(event.locationInWindow.y-pressEvent.locationInWindow.y) >= 3 || event.locationInWindow.x-pressEvent.locationInWindow.x >= 3) {
            dragging = true; onDragStart?(pressEvent)
        }
        if dragging { onDragMove?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        let wasDragging = dragging
        cancelPress()
        if wasDragging { onDragEnd?(event) }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
        refreshHover(at: event.locationInWindow)
    }
    func cancelPress() {
        pressEvent = nil; dragging = false
    }
    func beginRename() {
        guard !isRenaming else { return }
        onPress?()
        onSelect?()
        titleShimmer.cancel()
        titleField.layer?.removeAnimation(forKey: TabListMotion.movementKey)
        originalTitle = titleField.stringValue; isRenaming = true; needsLayout = true
        titleField.isEditable = true; titleField.isSelectable = true
        titleField.selectText(nil)
    }
    func finishRename(save: Bool) {
        guard isRenaming else { return }
        let value = (titleField.currentEditor()?.string ?? titleField.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false; needsLayout = true
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

/// A small rounded pill of text, a shade off the row behind it.
final class TabBadge: FlippedView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    var text = "" { didSet { needsDisplay = true } }
    private var color = NSColor.labelColor
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 5; layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var attributed: NSAttributedString { NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color]) }
    override var fittingSize: NSSize { NSSize(width: ceil(attributed.size().width)+12, height: 17) }
    func apply(_ theme: RiseTheme, selected: Bool) {
        layer?.backgroundColor = theme.text.withAlphaComponent(theme == .dark ? 0.14 : selected ? 0.07 : 0.08).cgColor
        color = TabAppearance.text(theme, selected: selected).withAlphaComponent(theme == .dark ? 0.8 : 0.72)
        needsDisplay = true
    }
    /// A fill of its own in place of the grey, as a pinned tile's wash of its favicon's colour.
    func setFill(_ fill: NSColor) { layer?.backgroundColor = fill.cgColor }
    /// Centred on the glyphs' cap height, not the line's box, which sits low in a short pill.
    override func draw(_ dirtyRect: NSRect) {
        let font = Self.font, string = attributed
        let width = ceil(string.size().width)
        let baseline = ((bounds.height+font.capHeight)/2).rounded()
        // In a flipped view, a string draws from the top of its line, its ascender above the baseline.
        string.draw(at: NSPoint(x: ((bounds.width-width)/2).rounded(), y: baseline-font.ascender))
    }
}

/// Developer mode's border on the chosen tab: a yellow line dashed with near-black, as on a
/// building site, over the tab's card so the card doesn't cover it.
final class ConstructionBorder: FlippedView {
    private let yellow = CAShapeLayer(), dashes = CAShapeLayer()
    /// A whole pixel on any screen, two on a Retina one, so it draws crisp.
    static let width: CGFloat = 1
    var radius: CGFloat = TabAppearance.radius { didSet { if radius != oldValue { needsLayout = true } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; isHidden = true
        let scale = TabAppearance.height/37
        for (line, color) in [(yellow, NSColor(hex: 0xFFD73D)), (dashes, NSColor(hex: 0x332D25))] {
            line.fillColor = nil; line.strokeColor = color.cgColor; line.lineWidth = Self.width
            layer?.addSublayer(line)
        }
        dashes.lineDashPattern = [NSNumber(value: Double(5*scale)), NSNumber(value: Double(6*scale))]
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // On the card's own continuous corners, its outer edge on the card's.
        let inset = Self.width/2
        let path = PageOutline.path(in: bounds.insetBy(dx: inset, dy: inset), radius: max(0, radius-inset), continuous: true)
        for line in [yellow, dashes] { line.frame = bounds; line.path = path }
        CATransaction.commit()
    }
}
