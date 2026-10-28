import AppKit
import RiseCore

@MainActor final class SidebarView: Surface {
    /// New Tab's top: as far under the traffic lights as Kero's first row is under its own
    /// (view.go), 46 pt centre to centre, its 28 pt header 2 pt under a 60 pt title bar centred on
    /// them. Rise's are centred 26 pt down, and New Tab is 34 pt tall.
    static let addresslessTop: CGFloat = 55
    /// How far the pinned tiles sit above `PinnedLayout`'s places, which left room for an address.
    static let pinnedLift: CGFloat = 98-addresslessTop
    /// Where the address palette opens beside the page, at the sidebar's top.
    var paletteAnchor: NSRect { NSRect(x: TabAppearance.inset, y: 50, width: bounds.width-2*TabAppearance.inset, height: 36) }
    let newTab = NewTabButton()
    let scroll = NSScrollView()
    let rowsHost = FlippedView()
    /// Holds closed tabs' rows while they fade, below the others.
    private let leavingRows = LeavingRowsView()
    private(set) var appliedTheme: RiseTheme?
    /// Searching tabs (`TabSearch.swift`): what's typed, or nil when not searching; the row lit
    /// with the arrow keys; and the list before it was filtered.
    let searchRow = TabSearchRow()
    var tabSearch: String?
    var searchFocusID: UUID?
    /// Whether the pointer, rather than the arrow keys, last moved the search's focus.
    var searchFocusByPointer = false
    var unfilteredRows: [NSView] = []
    var unfilteredIDs: [UUID] = []
    var onTabSearchEnded: (() -> Void)?
    var selectedTabID: UUID?
    let archiveButton: DownloadsButton
    let cleanUpButton: HoverHintButton
    /// The minimal New Tab: a plus in the titlebar, level with the traffic lights and over the
    /// downloads button, in place of the New Tab row. The titlebar holds it, as it takes clicks
    /// there (`BrowserController.placeTitlebarNewTab`).
    let titlebarNewTab: HoverHintButton
    /// The middle of the downloads button, which the titlebar's plus is centred over.
    var downloadsCentreX: CGFloat { bounds.width-23 }
    var minimalNewTab = true {
        didSet {
            guard minimalNewTab != oldValue else { return }
            newTab.isHidden = minimalNewTab; titlebarNewTab.isHidden = !minimalNewTab
            needsLayout = true
        }
    }
    var rows: [UUID: TabRow] = [:]
    /// Pinned tabs, as tiles between the address and New Tab (`PinnedTabs.swift`).
    let pinnedView = PinnedTabsView()
    var pinnedDrag: PinnedDrag?
    /// Holds a pinned tab's place in the list while one is dragged down to it.
    let listPlaceholder = FlippedView()
    var tabsByID: [UUID: BrowserTab] = [:]
    var onPin: ((UUID, Int) -> Void)?
    var onUnpin: ((UUID, Int) -> Void)?
    var onReorderPinned: (([UUID]) -> Void)?
    var splitRows: [UUID: SplitTabRow] = [:]
    var displayedRows: [NSView] = []
    var targetFrames: [UUID: NSRect] = [:]
    var drag: SidebarDrag?
    var returningDrag: SidebarDrag?
    var dragScrollTimer: Timer?
    var crossingClick: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    var detachmentClick: () -> Void = { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
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
    /// What its tabs in developer mode show, as chosen in rise://settings.
    var developerTabLook = DeveloperTabLook()
    var onTogglePlayback: ((UUID) -> Void)?
    var onToggleMute: ((UUID) -> Void)?
    var onTabPress: (() -> Void)?
    init(archive: @escaping () -> Void, cleanUp: @escaping () -> Void) {
        archiveButton = DownloadsButton(title: "Downloads", action: archive)
        cleanUpButton = HoverHintButton(image: TablerIcon.image(TablerIcon.tabCleanup, size: 20, description: "Sort tabs by domain"),
                                        text: "Sort tabs by domain", shortcut: "⇧⌘K", action: cleanUp)
        titlebarNewTab = HoverHintButton(image: TablerIcon.image(TablerIcon.plus, size: 20, strokeWidth: ReloadMorph.lineWidth, description: "New Tab"),
                                         text: "New Tab", shortcut: "⌘T", action: {})
        super.init()
        newTab.target = self; newTab.action = #selector(createTab); newTab.isHidden = minimalNewTab
        titlebarNewTab.actionBlock = { [weak self] in self?.createTab() }
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.verticalScroller = ThinScroller(); scroll.scrollerStyle = .overlay
        scroll.documentView = rowsHost
        [pinnedView, newTab, scroll, archiveButton, cleanUpButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func createTab() { onNewTab?() }
    func update(tabs: [BrowserTab], selected: BrowserTab?, theme: RiseTheme, splits: [SplitTabGroup] = []) {
        // This runs on every change to any tab; only what changed is set, as each set is redrawn.
        if appliedTheme != theme {
            appliedTheme = theme
            fill = theme.background
            newTab.theme = theme; searchRow.apply(theme)
            (scroll.verticalScroller as? ThinScroller)?.dark = theme == .dark
            for button in [archiveButton, cleanUpButton, titlebarNewTab] as [ChromeButton] {
                button.hoverHint?.appearance = theme.appearance
            }
            [archiveButton, cleanUpButton].forEach { $0.contentTintColor = theme.sidebarIcon }
            // New Tab's plus keeps its own ink over the sidebar, whatever colour the page bar takes.
            titlebarNewTab.contentTintColor = theme.newTabPlus
            for button in [archiveButton, cleanUpButton, titlebarNewTab] as [ChromeButton] {
                button.hoverColor = theme.text.withAlphaComponent(0.07)
            }
        }
        selectedTabID = selected?.id
        for id in Array(rows.keys) where !tabs.contains(where: { $0.id == id }) { if let row = rows.removeValue(forKey: id) { fadeOut(row) } }
        tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let splitIDs = Set(splits.flatMap { [$0.leftID, $0.rightID] })
        let pinned = Array(tabs.filter { $0.pinned && !splitIDs.contains($0.id) }.prefix(PinnedLayout.maximum).map(\.id))
        updatePinned(pinned, selected: selected, theme: theme)
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
                row.onHover = { [weak self] hovering in
                    self?.onTabHover?(id, hovering)
                    if !hovering { self?.pointerLeftSearchedTab(id) }
                }
                row.onPointerMove = { [weak self] in self?.pointerMovedOverSearchedTab(id) }
                row.onPress = { [weak self] in self?.onTabPress?() }
                row.onTogglePlayback = { [weak self] in self?.onTogglePlayback?(id) }
                row.onToggleMute = { [weak self] in self?.onToggleMute?(id) }
                rows[id] = row
            }
            let group = splits.first { $0.contains(tab.id) }
            row.isSplitMember = group != nil
            row.hoverFocuses = isSearchingTabs
            let isSelected = group.map { group in selected.map { group.contains($0.id) } ?? false } ?? (tab.id == selected?.id)
            row.update(tab: tab, selected: isSelected, theme: theme,
                       configuration: .forTab(tab, theme: theme, peek: peekState?(tab.id), developerLook: developerTabLook))
            row.setPlayback(paused: playbackState?(tab.id))
            if pinned.contains(tab.id) { if row.superview === rowsHost { row.removeFromSuperview() } }
            else if group == nil && row.superview !== rowsHost && drag?.view !== row && returningDrag?.view !== row { rowsHost.addSubview(row) }
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
        for tab in tabs where !seen.contains(tab.id) && !pinned.contains(tab.id) {
            if let group = splits.first(where: { $0.contains(tab.id) }), let row = splitRows[group.id] {
                displayedRows.append(row); orderedIDs.append(group.leftID); seen.formUnion([group.leftID, group.rightID])
            } else if let row = rows[tab.id] {
                displayedRows.append(row); orderedIDs.append(tab.id); seen.insert(tab.id)
            }
        }
        unfilteredRows = displayedRows; unfilteredIDs = orderedIDs
        filterForSearch()
        if let drag, drag.pinSlot == nil, !displayedRows.contains(where: { $0 === drag.view }) { endTabDrag() }
        applyDragToList()
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
    /// Lays the list out again, its rows gliding to their places or landing there at once.
    func relayout(animated: Bool) {
        animatesRows = animated; defer { animatesRows = true }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func tabID(at point: NSPoint) -> UUID? {
        if let tile = pinnedView.tiles.values.first(where: { $0.superview === pinnedView && $0.convert($0.bounds, to: self).contains(point) }) {
            return tile.tabID
        }
        guard scroll.frame.contains(point) else { return nil }
        for row in displayedRows where row.convert(row.bounds, to: self).contains(point) {
            if let tab = row as? TabRow { return tab.tabID }
            if let pair = row as? SplitTabRow {
                return pair.convert(point, from: self).x < pair.bounds.midX ? pair.left.tabID : pair.right.tabID
            }
        }
        return nil
    }
    /// While the sidebar widens or narrows for Control-Command, its tiles follow its width each
    /// frame, as its rows do, rather than springing after it.
    var followsWidth = false
    override func layout() {
        super.layout(); let w = bounds.width
        let pinnedHeight = PinnedLayout.height(count: pinnedView.count)
        let lift = Self.pinnedLift
        // The grid's room fits tiles at their tallest; shorter, they sit at its bottom.
        let shown = PinnedLayout.height(count: pinnedView.count, tileHeight: pinnedView.tileHeight)
        pinnedView.frame = NSRect(x: 0, y: PinnedLayout.top-lift+pinnedHeight-shown, width: w, height: max(0, shown-PinnedLayout.bottom))
        pinnedView.layoutTiles(animated: animatesRows && window != nil && !followsWidth)
        let start: CGFloat = (pinnedHeight > 0 ? PinnedLayout.top+pinnedHeight : 98)-lift
        let shift = start-newTab.frame.minY
        // Without its row, New Tab is a line where the list starts, which pinning measures from.
        newTab.frame = NSRect(x: TabAppearance.inset, y: start, width: w-2*TabAppearance.inset, height: minimalNewTab ? 0 : TabAppearance.height)
        var scrollY = minimalNewTab ? start : newTab.frame.maxY+TabAppearance.spacing
        // Searching tabs, the search row heads the list, a little apart from the first tab.
        if isSearchingTabs {
            searchRow.frame = NSRect(x: TabAppearance.inset, y: scrollY, width: w-2*TabAppearance.inset, height: TabAppearance.height)
            scrollY = searchRow.frame.maxY+TabSearchRow.gap
        }
        scroll.frame = NSRect(x: 0, y: scrollY, width: w, height: max(0, bounds.height-scrollY-44))
        // The grid grows and shrinks as tabs are pinned; what's below it slides to make room.
        if shift != 0, animatesRows, window != nil, newTab.frame.width > 0 {
            [newTab, searchRow, scroll].forEach { PinnedLayout.slideVertically($0, from: -shift) }
        }
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
        leavingRows.frame = rowsHost.bounds
        archiveButton.frame = NSRect(x: downloadsCentreX-14, y: bounds.height-39, width: 28, height: 28)
        cleanUpButton.frame = NSRect(x: 10, y: bounds.height-39, width: 28, height: 28)
    }
    /// A closed tab's row fades out quickly where it was, under the rows sliding into its place,
    /// and takes no clicks or hover meanwhile.
    private func fadeOut(_ row: TabRow) {
        guard row.superview === rowsHost, animatesRows, window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            row.removeFromSuperview(); return
        }
        if leavingRows.superview !== rowsHost { rowsHost.addSubview(leavingRows, positioned: .below, relativeTo: nil) }
        leavingRows.frame = rowsHost.bounds
        row.onHover = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        leavingRows.addSubview(row)
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TabListMotion.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            row.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { row.removeFromSuperview() }
        }
    }
}

/// Rows fading out after their tabs closed: shown, but not there to click.
final class LeavingRowsView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
