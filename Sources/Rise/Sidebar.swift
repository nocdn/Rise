import AppKit
import RiseCore

@MainActor final class SidebarView: Surface {
    let address = SidebarAddressButton()
    let addressText = FadingTextField(frame: .zero)
    let searchIcon = NSImageView()
    let copyButton: SidebarCopyButton
    let settingsButton: SidebarHoverButton
    var isSidebarHovered = false
    var isSiteControlsOpen = false {
        didSet { updateAddressControlVisibility() }
    }
    var hasAddress = false
    /// Pinned extensions, in the address row (`SidebarExtensionButton`).
    var extensionButtons: [SidebarExtensionButton] = [] {
        didSet {
            for button in oldValue where !extensionButtons.contains(button) { button.removeFromSuperview() }
            for button in extensionButtons where button.superview !== self { addSubview(button) }
            needsLayout = true; updateAddressControlVisibility(animated: false)
        }
    }
    let newTab = NewTabButton()
    let scroll = NSScrollView()
    let rowsHost = FlippedView()
    // The shadow is a sibling of the scroller, so NSClipView cannot crop it.
    let selectedTabShadow = Surface(radius: TabAppearance.radius)
    var selectedTabID: UUID?
    let archiveButton: ArchiveButton
    let cleanUpButton: HoverHintButton
    var rows: [UUID: TabRow] = [:]
    var splitRows: [UUID: SplitTabRow] = [:]
    var displayedRows: [NSView] = []
    var targetFrames: [UUID: NSRect] = [:]
    var drag: SidebarDrag?
    var returningDrag: SidebarDrag?
    var dragScrollTimer: Timer?
    var shadowRowID: UUID?
    var crossingClick: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    var detachmentClick: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    var onAddress: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onTabMenu: ((UUID, NSEvent) -> Void)?
    var onReorder: (([UUID]) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onTabHover: ((UUID, Bool) -> Void)?
    /// Whether a tab's video is paused, or nil when it shows none.
    var playbackState: ((UUID) -> Bool?)?
    var peekState: ((UUID) -> BrowserTab?)?
    var onTogglePlayback: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var onTabPress: (() -> Void)?
    init(copy: @escaping () -> Void, settings: @escaping () -> Void, archive: @escaping () -> Void, cleanUp: @escaping () -> Void) {
        copyButton = SidebarCopyButton(action: copy)
        settingsButton = SidebarHoverButton(symbol: "slider.horizontal.3", size: 14, title: "Site controls", action: settings)
        settingsButton.image = TablerIcon.image(TablerIcon.adjustments, size: 16, description: "Site controls")
        archiveButton = ArchiveButton(title: "Downloads", action: archive)
        cleanUpButton = HoverHintButton(image: TablerIcon.image(TablerIcon.tabCleanup, size: 20, description: "Sort tabs by domain"),
                                        text: "Sort tabs by domain", shortcut: "⇧⌘K", action: cleanUp)
        super.init()
        address.isBordered = false; address.title = ""; address.wantsLayer = true
        address.layer?.cornerRadius = AddressAppearance.cornerRadius; address.layer?.cornerCurve = .continuous
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
        selectedTabShadow.shadow = TabAppearance.shadow(.neutral)
        selectedTabShadow.isHidden = true
        addSubview(selectedTabShadow)
        [address, copyButton, settingsButton, newTab, scroll, archiveButton, cleanUpButton].forEach(addSubview)
        updateAddressControlVisibility(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func openAddress() { onAddress?() }
    @objc func createTab() { onNewTab?() }
    func update(tabs: [BrowserTab], selected: BrowserTab?, theme: RiseTheme, splits: [SplitTabGroup] = []) {
        fill = theme.background; gradientColors = theme.backgroundGradient; address.layer?.backgroundColor = theme.addressFill.cgColor
        selectedTabID = selected?.id
        selectedTabShadow.fill = TabAppearance.selectedFill(theme)
        selectedTabShadow.shadow = TabAppearance.shadow(theme)
        newTab.theme = theme
        addressText.stringValue = AddressResolver.displayHost(selected?.url)
        let blank = selected?.url == nil || selected?.url?.absoluteString == "about:blank"
        addressText.textColor = blank ? theme.muted : theme.text.withAlphaComponent(theme == .dark ? 0.95 : 0.85)
        searchIcon.isHidden = !blank; hasAddress = !blank
        updateAddressControlVisibility()
        ([copyButton, settingsButton, archiveButton, cleanUpButton] + extensionButtons).forEach {
            $0.contentTintColor = $0 === archiveButton || $0 === cleanUpButton ? theme.sidebarIcon : theme.muted
            $0.hoverColor = theme.text.withAlphaComponent(0.07)
        }
        searchIcon.contentTintColor = theme.muted
        cleanUpButton.hintAppearance = theme.appearance
        for id in Array(rows.keys) where !tabs.contains(where: { $0.id == id }) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for tab in tabs {
            let row: TabRow
            if let existing = rows[tab.id] { row = existing }
            else {
                let id = tab.id
                row = TabRow(tab: tab) { [weak self] in self?.onClose?(id) }
                row.onSelect = { [weak self] in self?.onSelect?(id) }
                row.onMenu = { [weak self] event in self?.onTabMenu?(id, event) }
                row.onRename = { [weak self] title in self?.onRename?(id, title) }
                row.onDragStart = { [weak self] event in self?.beginTabDrag(id, event: event) }
                row.onDragMove = { [weak self] event in self?.moveTabDrag(event) }
                row.onDragEnd = { [weak self] event in self?.endTabDrag(at: event.locationInWindow) }
                row.onHover = { [weak self] hovering in self?.onTabHover?(id, hovering) }
                row.onPress = { [weak self] in self?.onTabPress?() }
                row.onTogglePlayback = { [weak self] in self?.onTogglePlayback?(id) }
                row.onToggleMute = { [weak self] in self?.onToggleMute?(id) }
                rows[id] = row
            }
            let group = splits.first { $0.contains(tab.id) }
            row.isSplitMember = group != nil
            let isSelected = group.map { group in selected.map { group.contains($0.id) } ?? false } ?? (tab.id == selected?.id)
            row.update(tab: tab, selected: isSelected, theme: theme, configuration: .forTab(tab, theme: theme, peek: peekState?(tab.id)))
            row.setPlayback(paused: playbackState?(tab.id))
            if group == nil && row.superview !== rowsHost && drag?.view !== row && returningDrag?.view !== row { rowsHost.addSubview(row) }
        }
        for id in Array(splitRows.keys) where !splits.contains(where: { $0.id == id }) { splitRows.removeValue(forKey: id)?.removeFromSuperview() }
        for group in splits {
            guard let left = rows[group.leftID], let right = rows[group.rightID] else { continue }
            let row = splitRows[group.id] ?? SplitTabRow(group: group, left: left, right: right)
            splitRows[group.id] = row
            if row.superview !== rowsHost && drag?.view !== row && returningDrag?.view !== row { rowsHost.addSubview(row) }
            row.update(selected: selected.map { group.contains($0.id) } ?? false, theme: theme)
        }
        displayedRows = []; orderedIDs = []
        var seen = Set<UUID>()
        for tab in tabs where !seen.contains(tab.id) {
            if let group = splits.first(where: { $0.contains(tab.id) }), let row = splitRows[group.id] {
                displayedRows.append(row); orderedIDs.append(group.leftID); seen.formUnion([group.leftID, group.rightID])
            } else if let row = rows[tab.id] {
                displayedRows.append(row); orderedIDs.append(tab.id); seen.insert(tab.id)
            }
        }
        if let drag, !displayedRows.contains(where: { $0 === drag.view }) { endTabDrag() }
        needsLayout = true
        if bounds.width > 0 { layoutSubtreeIfNeeded() }
    }
    var orderedIDs: [UUID] = []
    /// Rows glide to new places unless the change is meant to land at once.
    private var animatesRows = true
    func update(tabs: [BrowserTab], selected: BrowserTab?, theme: RiseTheme, splits: [SplitTabGroup] = [], animated: Bool) {
        animatesRows = animated; defer { animatesRows = true }
        update(tabs: tabs, selected: selected, theme: theme, splits: splits)
        layoutSubtreeIfNeeded()
    }
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
        address.frame = NSRect(x: TabAppearance.inset, y: 50, width: w-2*TabAppearance.inset, height: 36)
        searchIcon.frame = NSRect(x: 12, y: 10, width: 14, height: 16)
        let textX: CGFloat = searchIcon.isHidden ? 13 : 34
        addressText.frame = NSRect(x: textX, y: 10, width: max(0, address.bounds.width-textX-13), height: 18)
        copyButton.frame = NSRect(x: address.frame.maxX-59, y: 56, width: 27, height: 24)
        settingsButton.frame = NSRect(x: address.frame.maxX-31, y: 56, width: 27, height: 24)
        layoutExtensionButtons()
        updateAddressTextBoundary(animated: false)
        let start: CGFloat = 98
        newTab.frame = NSRect(x: TabAppearance.inset, y: start, width: w-2*TabAppearance.inset, height: TabAppearance.height)
        let scrollY = newTab.frame.maxY+TabAppearance.spacing
        scroll.frame = NSRect(x: 0, y: scrollY, width: w, height: max(0, bounds.height-scrollY-44))
        var y: CGFloat = 0; targetFrames = [:]
        for (index, row) in displayedRows.enumerated() {
            let h: CGFloat = (row as? SplitTabRow)?.rowHeight ?? (row as? TabRow)?.rowHeight ?? TabAppearance.height
            let target = NSRect(x: TabAppearance.inset, y: y, width: w-2*TabAppearance.inset, height: h)
            targetFrames[orderedIDs[index]] = target
            if drag?.view !== row && returningDrag?.view !== row {
                TabListMotion.move(row, to: target, animated: animatesRows && row.frame.width > 0)
            }
            y += h+TabAppearance.spacing
        }
        rowsHost.frame = NSRect(x: 0, y: 0, width: w, height: max(y+8, scroll.bounds.height))
        archiveButton.frame = NSRect(x: w-37, y: bounds.height-39, width: 28, height: 28)
        cleanUpButton.frame = NSRect(x: 10, y: bounds.height-39, width: 28, height: 28)
        positionSelectedTabShadow()
    }
    @objc func positionSelectedTabShadow() {
        guard let id = selectedTabID, let row: NSView = splitRows.values.first(where: { $0.group.contains(id) }) ?? rows[id] else { selectedTabShadow.isHidden = true; return }
        guard row.superview === rowsHost else { selectedTabShadow.isHidden = true; return }
        let rect = row.convert(row.bounds, to: self)
        // Avoid painting a full card behind a row clipped by vertical scrolling.
        selectedTabShadow.isHidden = !scroll.frame.contains(rect)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        selectedTabShadow.frame = rect
        CATransaction.commit()
        if shadowRowID != canonicalID(for: row) {
            shadowRowID = canonicalID(for: row)
        }
        if let source = row.layer, let movement = source.animation(forKey: TabListMotion.movementKey) as? CABasicAnimation,
           let from = movement.fromValue as? NSValue, let destination = selectedTabShadow.layer {
            let copy = movement.copy() as! CABasicAnimation
            let offset = NSPoint(x: from.pointValue.x-source.position.x, y: from.pointValue.y-source.position.y)
            copy.fromValue = NSPoint(x: destination.position.x+offset.x, y: destination.position.y+offset.y)
            copy.toValue = destination.position
            // Unset, it starts with the row's, when the frame reaches the screen.
            if movement.beginTime != 0 { copy.beginTime = destination.convertTime(source.convertTime(movement.beginTime, to: nil), from: nil) }
            destination.add(copy, forKey: TabListMotion.movementKey)
        } else { selectedTabShadow.layer?.removeAnimation(forKey: TabListMotion.movementKey) }
        // Let the rounded layer outline supply the shadow shape as well.
        selectedTabShadow.layer?.shadowPath = nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
        if let window, !isHidden { setSidebarHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))) }
    }
    override func mouseEntered(with event: NSEvent) { setSidebarHovered(true) }
    override func mouseExited(with event: NSEvent) { setSidebarHovered(false) }
    override func viewDidHide() { super.viewDidHide(); setSidebarHovered(false, animated: false) }
}
