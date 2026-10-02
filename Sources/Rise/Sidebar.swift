import AppKit
import RiseCore

@MainActor final class TabRow: NSButton {
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
        setAccessibilityLabel(tab.title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc func selectTab() { onSelect?() }
    func update(tab: BrowserTab, selected: Bool, theme: RiseTheme) {
        self.selected = selected; self.theme = theme; developer = tab.developer
        titleField.stringValue = tab.title; titleField.textColor = selected ? theme.selectedText : theme.text
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
        loadingBackground.update(loading: tab.webView.isLoading, progress: tab.webView.estimatedProgress, theme: theme)
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
    override func mouseExited(with event: NSEvent) { hover = false; style() }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

@MainActor final class SidebarView: Surface {
    let address = NSButton()
    let addressText = FadingTextField(frame: .zero)
    let searchIcon = NSImageView()
    let copyButton: ChromeButton
    let settingsButton: ChromeButton
    let newTab = NewTabButton()
    let scroll = NSScrollView()
    let rowsHost = FlippedView()
    // The shadow is a sibling of the scroller, so NSClipView cannot crop it.
    let selectedTabShadow = Surface(radius: 12)
    var selectedTabID: UUID?
    let archiveButton: ChromeButton
    let themeButton: ChromeButton
    let clearButton: ChromeButton
    var rows: [UUID: TabRow] = [:]
    var splitRows: [UUID: SplitTabRow] = [:]
    private var displayedRows: [NSView] = []
    var onAddress: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onTabMenu: ((UUID, NSEvent) -> Void)?
    init(copy: @escaping () -> Void, settings: @escaping () -> Void, archive: @escaping () -> Void, theme: @escaping () -> Void, clear: @escaping () -> Void) {
        copyButton = ChromeButton(symbol: "link", size: 15, title: "Copy current URL", action: copy)
        settingsButton = ChromeButton(symbol: "slider.horizontal.3", size: 15, title: "Site controls", action: settings)
        archiveButton = ChromeButton(symbol: "archivebox.fill", size: 15, title: "Recently closed tabs", action: archive)
        themeButton = ChromeButton(symbol: "paintpalette.fill", size: 13, title: "Change theme", action: theme)
        clearButton = ChromeButton(symbol: "broom", size: 17, title: "Clear unpinned tabs", action: clear)
        if clearButton.image == nil { clearButton.image = broomIcon() }
        super.init()
        address.isBordered = false; address.title = ""; address.wantsLayer = true; address.layer?.cornerRadius = 12
        address.target = self; address.action = #selector(openAddress); address.setAccessibilityLabel("Search or Enter URL")
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = NSColor(hex: 0xA09E9E)
        address.addSubview(searchIcon); address.addSubview(addressText)
        addressText.font = .systemFont(ofSize: 13)
        newTab.target = self; newTab.action = #selector(createTab)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = rowsHost
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(positionSelectedTabShadow), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        selectedTabShadow.layer?.cornerCurve = .continuous
        selectedTabShadow.shadow = chromeShadow(opacity: 0.09, blur: 5, offset: -1)
        selectedTabShadow.isHidden = true
        addSubview(selectedTabShadow)
        [address, copyButton, settingsButton, newTab, scroll, archiveButton, themeButton, clearButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func openAddress() { onAddress?() }
    @objc func createTab() { onNewTab?() }
    func update(tabs: [BrowserTab], selected: BrowserTab?, theme: RiseTheme, splits: [SplitTabGroup] = []) {
        fill = theme.background; gradientColors = theme.backgroundGradient; address.layer?.backgroundColor = theme.pill.cgColor
        selectedTabID = selected?.id
        selectedTabShadow.fill = theme.selectedTab
        selectedTabShadow.shadow = chromeShadow(opacity: 0.09, blur: 5, offset: -1, color: theme == .dark ? .white : .black)
        newTab.theme = theme
        addressText.stringValue = AddressResolver.displayHost(selected?.url)
        let blank = selected?.url == nil || selected?.url?.absoluteString == "about:blank"
        addressText.textColor = blank ? theme.muted : theme.text.withAlphaComponent(theme == .dark ? 0.95 : 0.7)
        searchIcon.isHidden = !blank; copyButton.isHidden = blank; settingsButton.isHidden = blank
        clearButton.isEnabled = tabs.contains { !$0.pinned }
        clearButton.contentTintColor = theme.muted
        [copyButton, settingsButton, archiveButton, themeButton].forEach {
            $0.contentTintColor = theme.muted
            $0.hoverColor = theme.text.withAlphaComponent(0.07)
        }
        searchIcon.contentTintColor = theme.muted
        for id in Array(rows.keys) where !tabs.contains(where: { $0.id == id }) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for tab in tabs {
            let row: TabRow
            if let existing = rows[tab.id] { row = existing }
            else {
                let id = tab.id
                row = TabRow(tab: tab) { [weak self] in self?.onClose?(id) }
                row.onSelect = { [weak self] in self?.onSelect?(id) }
                row.onMenu = { [weak self] event in self?.onTabMenu?(id, event) }
                rows[id] = row
            }
            let group = splits.first { $0.contains(tab.id) }
            row.isSplitMember = group != nil
            let isSelected = group.map { group in selected.map { group.contains($0.id) } ?? false } ?? (tab.id == selected?.id)
            row.update(tab: tab, selected: isSelected, theme: theme)
            if group == nil && row.superview !== rowsHost { rowsHost.addSubview(row) }
        }
        for id in Array(splitRows.keys) where !splits.contains(where: { $0.id == id }) { splitRows.removeValue(forKey: id)?.removeFromSuperview() }
        for group in splits {
            guard let left = rows[group.leftID], let right = rows[group.rightID] else { continue }
            let row = splitRows[group.id] ?? SplitTabRow(group: group, left: left, right: right)
            splitRows[group.id] = row
            if row.superview !== rowsHost { rowsHost.addSubview(row) }
            row.update(selected: selected.map { group.contains($0.id) } ?? false, theme: theme)
        }
        displayedRows = []; orderedIDs = []
        var seen = Set<UUID>()
        for tab in tabs.sorted(by: { $0.pinned && !$1.pinned }) where !seen.contains(tab.id) {
            if let group = splits.first(where: { $0.contains(tab.id) }), let row = splitRows[group.id] {
                displayedRows.append(row); orderedIDs.append(group.leftID); seen.formUnion([group.leftID, group.rightID])
            } else if let row = rows[tab.id] {
                displayedRows.append(row); orderedIDs.append(tab.id); seen.insert(tab.id)
            }
        }
        needsLayout = true
    }
    var orderedIDs: [UUID] = []
    func tabID(at point: NSPoint) -> UUID? {
        guard scroll.frame.contains(point) else { return nil }
        for row in displayedRows where row.convert(row.bounds, to: self).contains(point) {
            if let tab = row as? TabRow { return tab.tabID }
            if let pair = row as? SplitTabRow {
                return pair.convert(point, from: self).x < pair.bounds.midX ? pair.left.tabID : pair.right.tabID
            }
        }
        return nil
    }
    override func layout() {
        super.layout(); let w = bounds.width
        address.frame = NSRect(x: 8, y: 50, width: w-16, height: 36)
        searchIcon.frame = NSRect(x: 12, y: 10, width: 14, height: 16)
        addressText.frame = NSRect(x: searchIcon.isHidden ? 13 : 34, y: 10, width: w-(searchIcon.isHidden ? 90 : 60), height: 18)
        copyButton.frame = NSRect(x: w-67, y: 56, width: 27, height: 24)
        settingsButton.frame = NSRect(x: w-39, y: 56, width: 27, height: 24)
        let start: CGFloat = 98
        newTab.frame = NSRect(x: 8, y: start, width: w-16, height: 37)
        let scrollY = newTab.frame.maxY+8
        scroll.frame = NSRect(x: 0, y: scrollY, width: w, height: max(0, bounds.height-scrollY-44))
        var y: CGFloat = 8
        for row in displayedRows {
            let h: CGFloat = (row as? SplitTabRow)?.rowHeight ?? ((row as? TabRow)?.developer == true ? 40 : 37)
            row.frame = NSRect(x: 8, y: y, width: w-16, height: h); y += h+4
        }
        rowsHost.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.bounds.height))
        archiveButton.frame = NSRect(x: 10, y: bounds.height-39, width: 28, height: 28)
        themeButton.frame = NSRect(x: (w-28)/2, y: bounds.height-39, width: 28, height: 28)
        clearButton.frame = NSRect(x: w-37, y: bounds.height-39, width: 28, height: 28)
        positionSelectedTabShadow()
    }
    @objc func positionSelectedTabShadow() {
        guard let id = selectedTabID, let row: NSView = splitRows.values.first(where: { $0.group.contains(id) }) ?? rows[id] else { selectedTabShadow.isHidden = true; return }
        let rect = row.convert(row.bounds, to: self)
        // Avoid painting a full card behind a row clipped by vertical scrolling.
        selectedTabShadow.isHidden = !scroll.frame.contains(rect)
        selectedTabShadow.frame = rect
        // Let the continuous layer outline supply the shadow shape as well.
        selectedTabShadow.layer?.shadowPath = nil
    }
}
