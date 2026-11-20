import AppKit
import RiseCore

/// Bookmarks in the sidebar, in the tabs' place: the tabs roll out to the left and the bookmarks
/// roll in from the right, as the page bar's address and its notices exchange places, and the
/// sidebar widens a little, halfway to its Control-Command width. "Bookmarks" heads them by the
/// traffic lights, and Sort turns into Return to tabs, which rolls everything back.
@MainActor final class SidebarBookmarksState {
    fileprivate(set) var isShown = false
    /// While the hold shortcut is down: the modifiers held, and the key, until they're let go.
    fileprivate var hold: (modifiers: NSEvent.ModifierFlags, keyCode: UInt16)?
    var isHeld: Bool { hold != nil }
    /// The bookmarks opened a collapsed sidebar, which tucks away again when they go.
    fileprivate var revealedSidebar = false
    /// 0 at the sidebar's own width, 1 at the width bookmarks show at.
    fileprivate var spring = MotionSpring(0)
    fileprivate var link: CADisplayLink?
    fileprivate var lastTick: CFTimeInterval?
    var progress: CGFloat { CGFloat(spring.value) }
    init() { spring.configure(response: SidebarRollMotion.widthResponse, bounce: 0) }
}

/// The roll: what leaves goes sideways and fades quickly, and what comes follows a moment later from
/// the other side, slowing into place, on the page bar's notice timing (`PlainNavBar.Notice`).
enum SidebarRollMotion {
    static let exit: CGFloat = 34, entry: CGFloat = 30
    static let exitDuration = PlainNavBar.Notice.exitDuration, entryDelay = PlainNavBar.Notice.entryDelay
    static let entryDuration = PlainNavBar.Notice.entryDuration+0.04
    static let exitTiming = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.6)
    static let entryTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
    static let key = "Rise.SidebarRoll"
    /// How far toward its Control-Command width the sidebar widens for bookmarks.
    static let widening: CGFloat = 0.5
    static let widthResponse = 0.22
    /// The title rolls a shorter way, as words in the page bar do.
    static let titleExit: CGFloat = 14, titleEntry: CGFloat = 12
}

@MainActor extension SidebarView {
    /// The tabs' side of the sidebar: everything between the titlebar and the bottom buttons.
    var tabContentViews: [NSView] {
        [pinnedView, newTab, searchRow, scroll, chosenPill, nowPlaying].filter { $0.superview === self }
    }
    /// Shows the bookmarks in the tabs' place, or the tabs again, rolling sideways.
    func setShowsBookmarks(_ shows: Bool, animated: Bool) {
        guard shows != showsBookmarks else { return }
        showsBookmarks = shows
        cleanUpButton.setShowsReturn(shows, animated: animated && window?.isVisible == true)
        if shows {
            tabContentViews.compactMap(\.layer).forEach { $0.removeAnimation(forKey: TabListMotion.movementKey) }
            cancelTabInteractions()
        }
        needsLayout = true; layoutSubtreeIfNeeded()
        let tabs = tabContentViews, bookmarks: [NSView] = [bookmarksPane]
        let moving = animated && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Showing bookmarks, things move left; going back, right.
        let way: CGFloat = shows ? -1 : 1
        let now = CACurrentMediaTime()
        let leaving = shows ? tabs : bookmarks, coming = shows ? bookmarks : tabs
        bookmarksPane.isHidden = false; bookmarksTitle.isHidden = false
        for view in leaving { roll(view, out: way, distance: SidebarRollMotion.exit, at: now, moving: moving) }
        for view in coming { roll(view, inFrom: -way, distance: SidebarRollMotion.entry, at: now, moving: moving) }
        if shows { roll(bookmarksTitle, inFrom: -way, distance: SidebarRollMotion.titleEntry, at: now, moving: moving) }
        else { roll(bookmarksTitle, out: way, distance: SidebarRollMotion.titleExit, at: now, moving: moving) }
        // The tabs stay faded out under the bookmarks, which are clear over the sidebar's material,
        // and the bookmarks, gone, are hidden.
        let settled = SidebarRollMotion.entryDelay+SidebarRollMotion.entryDuration
        let finish = { [weak self] in
            guard let self, self.showsBookmarks == shows, !shows else { return }
            self.bookmarksPane.isHidden = true; self.bookmarksTitle.isHidden = true
        }
        if moving { DispatchQueue.main.asyncAfter(deadline: .now()+settled+0.02, execute: finish) } else { finish() }
        bookmarksPane.isActive = shows
    }
    /// Goes `way` (left, -1, or right) as it fades, staying gone until something brings it back.
    private func roll(_ view: NSView, out way: CGFloat, distance: CGFloat, at now: CFTimeInterval, moving: Bool) {
        guard let layer = view.layer else { return }
        let opacity = layer.presentation()?.opacity ?? 1
        let x = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        layer.removeAnimation(forKey: SidebarRollMotion.key)
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = moving ? opacity : 0; fade.toValue = 0
        let slide = CABasicAnimation(keyPath: "transform.translation.x"); slide.fromValue = moving ? x : way*distance; slide.toValue = way*distance
        let group = CAAnimationGroup(); group.animations = [fade, slide]
        group.beginTime = now; group.duration = moving ? SidebarRollMotion.exitDuration : 0.001
        group.timingFunction = SidebarRollMotion.exitTiming
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        layer.add(group, forKey: SidebarRollMotion.key)
    }
    /// Comes from the `way` side, after the leaving have mostly gone, slowing into its place.
    private func roll(_ view: NSView, inFrom way: CGFloat, distance: CGFloat, at now: CFTimeInterval, moving: Bool) {
        guard let layer = view.layer else { return }
        let opacity = layer.presentation()?.opacity ?? 0
        let x = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? way*distance
        // Still on its way out, it turns back from where it is rather than jumping off to the side.
        let interrupted = layer.animation(forKey: SidebarRollMotion.key) != nil && opacity > 0.02
        layer.removeAnimation(forKey: SidebarRollMotion.key)
        guard moving else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = interrupted ? opacity : 0; fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.x"); slide.fromValue = interrupted ? x : way*distance; slide.toValue = 0
        let group = CAAnimationGroup(); group.animations = [fade, slide]
        group.beginTime = interrupted ? now : now+SidebarRollMotion.entryDelay
        group.duration = SidebarRollMotion.entryDuration
        group.timingFunction = SidebarRollMotion.entryTiming; group.fillMode = .backwards
        layer.add(group, forKey: SidebarRollMotion.key)
    }
    /// Lays out the bookmarks over the tabs' place, and their title between the traffic lights and New Tab's plus.
    func layoutBookmarks() {
        let w = bounds.width
        bookmarksPane.frame = NSRect(x: 0, y: SidebarBookmarksPane.top, width: w, height: max(0, bounds.height-44-SidebarBookmarksPane.top))
        let line = ceil(bookmarksTitle.intrinsicContentSize.height)
        let end = minimalNewTab ? downloadsCentreX-14-6 : w-12
        let start = bookmarksTitleLeading
        bookmarksTitle.frame = NSRect(x: start, y: round(bookmarksTitleMidY-line/2), width: max(0, end-start), height: line)
    }
}

/// The bookmarks as the sidebar lists them: each row as a tab's, in the tabs' place, over them.
@MainActor final class SidebarBookmarksPane: FlippedView {
    /// Where it starts in the sidebar, just under the titlebar; its first row is where the first tab's is.
    static let top: CGFloat = 44
    static let firstRow = SidebarView.addresslessTop-top
    let scroll = SidebarScrollView()
    let rowsHost = FlippedView()
    private(set) var rows: [SidebarBookmarkRow] = []
    private let emptyTitle = NSTextField(labelWithString: "No bookmarks yet")
    private let emptyHint = NSTextField(wrappingLabelWithString: "")
    private var theme = RiseTheme.neutral
    var emptyText = "" { didSet { emptyHint.stringValue = emptyText; needsLayout = true } }
    var onOpen: ((UUID, Bool) -> Void)?
    var onMenu: ((UUID, NSEvent, NSView) -> Void)?
    var onReorder: ((UUID, Int) -> Void)?
    var onEditEnd: ((UUID, String?) -> Void)?
    /// While the hold shortcut, with Control in it, is down, a Control-click opens rather than
    /// showing the menu.
    var controlClickOpens = false
    /// Whether it's the sidebar's side that shows: rows take the pointer only then.
    var isActive = false { didSet { if isActive != oldValue { rows.forEach { $0.refreshHover() } } } }
    private var dragged: (row: SidebarBookmarkRow, grab: CGFloat, y: CGFloat)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true; isHidden = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.verticalScroller = ThinScroller(); scroll.verticalScroller?.controlSize = .small; scroll.scrollerStyle = .overlay
        scroll.documentView = rowsHost
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium); emptyTitle.alignment = .center
        emptyHint.font = .systemFont(ofSize: 12); emptyHint.alignment = .center
        [scroll, emptyTitle, emptyHint].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.list); setAccessibilityLabel("Bookmarks")
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Clear over the sidebar's own material and tint, as the tabs' list is.
    func apply(_ theme: RiseTheme) {
        self.theme = theme
        scroll.verticalScroller?.appearance = theme.appearance
        emptyTitle.textColor = TabAppearance.text(theme, selected: false); emptyHint.textColor = theme.muted
        rows.forEach { $0.apply(theme) }
    }
    func update(_ bookmarks: [Bookmark], theme: RiseTheme, icon: (Bookmark) -> NSImage?) {
        if theme != self.theme || rows.isEmpty { apply(theme) }
        var byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.bookmarkID, $0) })
        var next: [SidebarBookmarkRow] = []
        for bookmark in bookmarks {
            let row = byID.removeValue(forKey: bookmark.id) ?? makeRow(bookmark.id)
            row.show(bookmark, icon: icon(bookmark), theme: theme)
            next.append(row)
        }
        byID.values.forEach { $0.removeFromSuperview() }
        rows = next
        emptyTitle.isHidden = !rows.isEmpty; emptyHint.isHidden = !rows.isEmpty
        needsLayout = true
    }
    private func makeRow(_ id: UUID) -> SidebarBookmarkRow {
        let row = SidebarBookmarkRow(id: id)
        row.onOpen = { [weak self] atTop in self?.onOpen?(id, atTop) }
        row.onMenu = { [weak self, weak row] event in
            guard let self, let row else { return }
            if event.type == .leftMouseDown, self.controlClickOpens { self.onOpen?(id, event.modifierFlags.contains(.command)); return }
            self.onMenu?(id, event, row)
        }
        row.isActive = { [weak self] in self?.isActive == true }
        row.onDragStart = { [weak self, weak row] event in if let row { self?.beginDrag(row, event) } }
        row.onDragMove = { [weak self] event in self?.moveDrag(event) }
        row.onDragEnd = { [weak self] in self?.endDrag() }
        row.onEditEnd = { [weak self] title in self?.onEditEnd?(id, title) }
        rowsHost.addSubview(row)
        return row
    }
    /// Starts naming a bookmark in its row, scrolled to, as a tab's double-click does.
    func beginEditing(_ id: UUID) {
        guard let row = rows.first(where: { $0.bookmarkID == id }) else { return }
        layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -8))
        row.beginEditing()
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        placeRows(animated: false)
        let width = bounds.width-40
        let hint = emptyHint.sizeThatFits(NSSize(width: width, height: 200))
        let title = ceil(emptyTitle.intrinsicContentSize.height)
        let y = Self.firstRow+18
        emptyTitle.frame = NSRect(x: 20, y: y, width: width, height: title)
        emptyHint.frame = NSRect(x: 20, y: y+title+4, width: width, height: ceil(hint.height))
    }
    private func placeRows(animated: Bool) {
        let w = bounds.width, step = TabAppearance.height+TabAppearance.spacing
        var order = rows
        if let dragged, let from = order.firstIndex(where: { $0 === dragged.row }) {
            order.remove(at: from); order.insert(dragged.row, at: dropIndex(for: dragged.y))
        }
        for (index, row) in order.enumerated() {
            let frame = NSRect(x: TabAppearance.inset, y: Self.firstRow+CGFloat(index)*step, width: w-2*TabAppearance.inset, height: TabAppearance.height)
            if row === dragged?.row {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                row.frame = NSRect(x: frame.minX, y: dragged!.y, width: frame.width, height: frame.height)
                CATransaction.commit()
            } else { TabListMotion.move(row, to: frame, animated: animated && row.frame.width > 0) }
        }
        rowsHost.frame = NSRect(x: 0, y: 0, width: w, height: max(bounds.height, Self.firstRow+CGFloat(rows.count)*step+8))
    }
    private func dropIndex(for y: CGFloat) -> Int {
        let step = TabAppearance.height+TabAppearance.spacing
        return min(max(0, Int(((y-Self.firstRow)/step).rounded())), max(0, rows.count-1))
    }

    // MARK: Dragging a bookmark up and down the list

    private func beginDrag(_ row: SidebarBookmarkRow, _ event: NSEvent) {
        let y = rowsHost.convert(event.locationInWindow, from: nil).y
        dragged = (row, y-row.frame.minY, row.frame.minY)
        row.layer?.zPosition = 1; row.isLifted = true
    }
    private func moveDrag(_ event: NSEvent) {
        guard let current = dragged else { return }
        let y = rowsHost.convert(event.locationInWindow, from: nil).y-current.grab
        let last = Self.firstRow+CGFloat(max(0, rows.count-1))*(TabAppearance.height+TabAppearance.spacing)
        dragged?.y = min(max(Self.firstRow-6, y), last+6)
        placeRows(animated: true)
    }
    private func endDrag() {
        guard let current = dragged else { return }
        let index = dropIndex(for: current.y)
        dragged = nil
        current.row.layer?.zPosition = 0; current.row.isLifted = false
        if let from = rows.firstIndex(where: { $0 === current.row }), from != index {
            rows.remove(at: from); rows.insert(current.row, at: index)
            onReorder?(current.row.bookmarkID, index)
        }
        placeRows(animated: true)
    }
}

/// A bookmark in the sidebar, drawn as a tab is: its icon, its title in the tabs' font and ink, and
/// the tabs' hover.
@MainActor final class SidebarBookmarkRow: NSView, NSTextFieldDelegate {
    let bookmarkID: UUID
    let icon = FaviconView(frame: .zero)
    let titleField = TabTitleField(frame: .zero)
    let background = PlainTabBackground()
    private var theme = RiseTheme.neutral
    private var hovered = false
    private var pressEvent: NSEvent?, dragging = false
    var isLifted = false { didSet { style() } }
    var isActive: () -> Bool = { true }
    var onOpen: ((Bool) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var isEditing = false
    private var originalTitle = ""
    var onEditEnd: ((String?) -> Void)?
    override var isFlipped: Bool { true }
    init(id: UUID) {
        bookmarkID = id
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = TabAppearance.radius; layer?.cornerCurve = .continuous
        titleField.delegate = self; titleField.focusRingType = .none
        icon.wantsLayer = true
        titleField.cell?.usesSingleLineMode = true
        [background, icon, titleField].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ bookmark: Bookmark, icon image: NSImage?, theme: RiseTheme) {
        if !isEditing { titleField.stringValue = bookmark.shownTitle }
        if let image { icon.image = image } else { icon.showEmptyPlaceholder(theme: theme) }
        toolTip = AddressDisplay.text(bookmark.url.absoluteString)
        setAccessibilityLabel(bookmark.shownTitle)
        apply(theme)
    }
    func apply(_ theme: RiseTheme) {
        self.theme = theme
        titleField.textColor = TabAppearance.text(theme, selected: false)
        icon.contentTintColor = theme.sidebarIcon
        background.dark = theme == .dark
        style()
    }
    override func layout() {
        super.layout()
        background.frame = bounds
        icon.frame = NSRect(x: 8, y: (bounds.height-16)/2, width: 16, height: 16)
        let line = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: 30, y: (bounds.height-line)/2, width: max(0, bounds.width-30-8), height: line)
    }
    private func style() {
        background.radius = TabAppearance.radius
        let lit = (hovered || pressEvent != nil) && isActive()
        layer?.backgroundColor = (isLifted ? TabAppearance.dragFill(theme, sidebarFraction: 1) : .clear).cgColor
        background.show(chosen: false, hovered: lit && !isLifted, animated: window != nil)
    }
    func refreshHover() {
        guard let window, !isHiddenOrHasHiddenAncestor else { hovered = false; style(); return }
        let point = window.mouseLocationOutsideOfEventStream
        hovered = visibleRect.contains(convert(point, from: nil)) && isFrontmost(at: point); style()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if isEditing, titleField.frame.contains(local) { return titleField.hitTest(local) ?? titleField }
        return self
    }

    // MARK: Naming it, as a tab is renamed

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true; originalTitle = titleField.stringValue
        titleField.isEditable = true; titleField.isSelectable = true
        titleField.selectText(nil)
    }
    /// Enter keeps what's typed, or the title it had if nothing is; Escape cancels.
    func finishEditing(save: Bool) {
        guard isEditing else { return }
        let value = (titleField.currentEditor()?.string ?? titleField.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ended by a click elsewhere, focus is already on its way there; only Enter and Escape let go of it here.
        let ownsFocus = titleField.currentEditor() != nil && window?.firstResponder === titleField.currentEditor()
        isEditing = false
        if ownsFocus { window?.makeFirstResponder(nil) }
        titleField.isEditable = false; titleField.isSelectable = false
        let title = save && !value.isEmpty ? value : originalTitle
        titleField.stringValue = title
        onEditEnd?(save ? title : nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishEditing(save: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(save: false); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishEditing(save: true) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseMoved(with event: NSEvent) { if !hovered { refreshHover() } }
    override func mouseExited(with event: NSEvent) { hovered = false; style() }
    override func mouseDown(with event: NSEvent) {
        if isEditing { return }
        if event.modifierFlags.contains(.control) { onMenu?(event); return }
        pressEvent = event; dragging = false; style()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressEvent else { return }
        if !dragging && abs(event.locationInWindow.y-pressEvent.locationInWindow.y) >= 3 { dragging = true; onDragStart?(pressEvent) }
        if dragging { onDragMove?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        let wasDragging = dragging
        pressEvent = nil; dragging = false
        if wasDragging { onDragEnd?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(event.modifierFlags.contains(.command)) }
        refreshHover()
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func accessibilityPerformPress() -> Bool { onOpen?(false); return true }
}

/// Sort tabs by domain, which turns into Return to tabs while bookmarks show, its glyph swapping as
/// a tab's play and pause do.
@MainActor final class SidebarSortButton: ChromeButton {
    private let sortGlyph = GlyphView(), returnGlyph = GlyphView()
    private(set) var showsReturn = false
    private var sortShortcut = "⇧⌘K", returnShortcut = ""
    static let sortText = "Sort tabs by domain", returnText = "Return to tabs"
    init(action: @escaping () -> Void) {
        super.init(symbol: "questionmark", title: Self.sortText, action: action)
        image = nil
        sortGlyph.image = TablerIcon.image(TablerIcon.tabCleanup, size: 20, description: Self.sortText)
        returnGlyph.image = TablerIcon.image(TablerIcon.arrowBackUp, size: 20, description: Self.returnText)
        for glyph in [sortGlyph, returnGlyph] { glyph.imageScaling = .scaleNone; glyph.wantsLayer = true; addSubview(glyph) }
        returnGlyph.layer?.opacity = 0
        setHoverHint(Self.sortText, shortcut: sortShortcut)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var contentTintColor: NSColor? {
        didSet { sortGlyph.contentTintColor = contentTintColor; returnGlyph.contentTintColor = contentTintColor }
    }
    override func layout() {
        super.layout()
        // Anchored at their middles, so the swap's scale stays centred.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for glyph in [sortGlyph, returnGlyph] {
            glyph.frame = bounds
            glyph.layer?.anchorPoint = NSPoint(x: 0.5, y: 0.5)
            glyph.layer?.bounds = bounds
            glyph.layer?.position = NSPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
    }
    func setShortcuts(sort: String, back: String) {
        sortShortcut = sort; returnShortcut = back
        setHoverHint(showsReturn ? Self.returnText : Self.sortText, shortcut: showsReturn ? back : sort)
    }
    func setShowsReturn(_ shows: Bool, animated: Bool) {
        guard shows != showsReturn else { return }
        showsReturn = shows
        layoutSubtreeIfNeeded()
        if let incoming = (shows ? returnGlyph : sortGlyph).layer, let outgoing = (shows ? sortGlyph : returnGlyph).layer {
            SymbolSwapMotion.show(incoming, replacing: outgoing, animated: animated)
        }
        setHoverHint(shows ? Self.returnText : Self.sortText, shortcut: shows ? returnShortcut : sortShortcut)
        if hover { hoverHint?.setHovered(true) }
    }
    /// The glyphs are only drawn: the button takes the clicks.
    final class GlyphView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor extension BrowserController {
    var showsSidebarBookmarks: Bool { sidebarBookmarks.isShown }

    /// The sidebar's toggle (⌥⌘B by default): bookmarks in the tabs' place, or the tabs again.
    @objc func toggleSidebarBookmarks() {
        guard bookmarkPlacement == .sidebar else { return }
        if sidebarBookmarks.isShown { returnToTabs(animated: true) } else { showSidebarBookmarks() }
    }
    func showSidebarBookmarks() {
        guard bookmarkPlacement == .sidebar, !sidebarBookmarks.isShown else { return }
        let state = sidebarBookmarks
        state.isShown = true
        if sidebar.isSearchingTabs { sidebar.endTabSearch() }
        hidePalette(); cancelTabSwitch()
        hideTabHoverCard()
        // A collapsed sidebar comes out for them, and goes again with them.
        state.revealedSidebar = false
        if !sidebarVisible && !sidebarFloat.isOut { revealFloatingSidebar(); state.revealedSidebar = true }
        bookmarksChanged()
        sidebar.setShowsBookmarks(true, animated: true)
        animateBookmarksWidth(to: 1)
    }
    /// Rolls the tabs back, as the return button and letting go of the hold shortcut do.
    func returnToTabs(animated: Bool) {
        let state = sidebarBookmarks
        state.hold = nil; sidebar.bookmarksPane.controlClickOpens = false
        // A title being typed is kept as it is.
        sidebar.bookmarksPane.rows.first { $0.isEditing }?.finishEditing(save: true)
        guard state.isShown else { return }
        state.isShown = false
        sidebar.setShowsBookmarks(false, animated: animated)
        animateBookmarksWidth(to: 0, animated: animated)
        if state.revealedSidebar {
            state.revealedSidebar = false
            if !sidebarVisible, !isPointerOverSidebar { tuckFloatingSidebar() }
        }
    }
    private var isPointerOverSidebar: Bool {
        guard let window else { return false }
        return sidebar.bounds.contains(sidebar.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    /// The sidebar's Sort button: while bookmarks show, it's Return to tabs.
    func sidebarSortPressed() {
        if sidebarBookmarks.isShown { returnToTabs(animated: true) } else { cleanUpTabs() }
    }
    /// A bookmark chosen in the sidebar opens beside the tab you're on, or at the top with ⌘.
    func openSidebarBookmark(_ id: UUID, atTop: Bool) {
        openBookmark(id, atTop: atTop)
    }

    /// The hold shortcut (⌃⌥B by default) shows the bookmarks while it's held, and the tabs again
    /// once it's let go: its modifiers, or its key when it has none but a function key's.
    func handleBookmarksHoldEvent(_ event: NSEvent) -> Bool {
        let state = sidebarBookmarks
        if event.type == .keyDown, keyboardShortcuts.matches("holdSidebarBookmarks", event) {
            guard bookmarkPlacement == .sidebar else { return false }
            if state.hold == nil, !event.isARepeat {
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                state.hold = (modifiers, event.keyCode)
                sidebar.bookmarksPane.controlClickOpens = modifiers.contains(.control)
                if state.isShown { state.revealedSidebar = false } else { showSidebarBookmarks() }
            }
            return true
        }
        guard let hold = state.hold else { return false }
        if event.type == .flagsChanged, !hold.modifiers.isEmpty, !event.modifierFlags.isSuperset(of: hold.modifiers) {
            returnToTabs(animated: true); return false
        }
        if event.type == .keyUp, event.keyCode == hold.keyCode {
            if hold.modifiers.isEmpty { returnToTabs(animated: true) }
            return true
        }
        return false
    }
    /// Letting go elsewhere, as when the window stops being key, ends a hold.
    func endBookmarksHold() {
        if sidebarBookmarks.isHeld { returnToTabs(animated: true) }
    }

    func animateBookmarksWidth(to target: Double, animated: Bool = true) {
        let state = sidebarBookmarks
        state.spring.target = target
        guard animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            state.link?.invalidate(); state.link = nil; state.spring.settle(); layoutBookmarksWidth(); return
        }
        guard state.link == nil else { return }
        state.lastTick = CACurrentMediaTime()
        let link = root.displayLink(target: self, selector: #selector(tickBookmarksWidth(_:)))
        link.add(to: .main, forMode: .common); state.link = link
    }
    @objc private func tickBookmarksWidth(_ link: CADisplayLink) {
        let state = sidebarBookmarks
        let now = CACurrentMediaTime(), dt = min(0.05, now-(state.lastTick ?? now)); state.lastTick = now
        state.spring.step(dt)
        if state.spring.isResting(within: 0.001) { state.spring.settle(); link.invalidate(); state.link = nil }
        layoutBookmarksWidth()
    }
    private func layoutBookmarksWidth() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sidebar.followsWidth = true
        layoutChrome(); root.layoutSubtreeIfNeeded()
        sidebar.followsWidth = false
        CATransaction.commit()
    }
    /// The title's place: after the traffic lights, level with them.
    func placeBookmarksTitle() {
        guard let zoom = window?.standardWindowButton(.zoomButton), zoom.superview != nil else { return }
        let frame = zoom.convert(zoom.bounds, to: sidebar)
        sidebar.bookmarksTitleLeading = (frame.maxX+12).rounded()
        sidebar.bookmarksTitleMidY = frame.midY
    }
}
