import AppKit
import RiseCore

/// Tabs that go unused move to Archived Tabs, from where they can be reopened as they were. Other
/// devices can do the same; all share what's been used and what's archived. See docs/TabArchive.md.
@MainActor extension BrowserController {
    static let tabArchiveHoursKey = "Rise.TabArchiveHours"
    static let tabUseClockKey = "Rise.TabUseClock"
    static let tabArchiveChoices = [("0", "Never"), ("24", "After 1 day"), ("48", "After 2 days"), ("72", "After 3 days"), ("168", "After 1 week")]
    /// How long a tab may go unused, in hours: 48 unless set (0: never).
    var tabArchiveHours: Int {
        preferences.object(forKey: Self.tabArchiveHoursKey) == nil ? TabArchiveRules.defaultHours : preferences.integer(forKey: Self.tabArchiveHoursKey)
    }
    func setTabArchiveHours(_ hours: Int) { preferences.set(hours, forKey: Self.tabArchiveHoursKey) }
    /// How long it takes for a tab to count as used once it's shown, so that passing through doesn't.
    static let tabUseDelay: TimeInterval = 5
    /// How often it looks for tabs to archive, and how soon after a use it notes another for a tab.
    static let tabArchiveInterval: TimeInterval = 15*60, tabUseInterval: TimeInterval = 5*60

    /// Rise is in front, and someone's at the Mac.
    var isUsingRise: Bool {
        guard NSApp.isActive, window?.isMiniaturized != true, let anyInput = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < 5*60
    }

    /// Each minute: with Rise in use, the tabs showing count as used, and any that have gone unused
    /// long enough are archived.
    func tabUseTick(using: Bool? = nil, now: Date = Date()) {
        shareKeptTabs()
        guard using ?? isUsingRise else { return }
        tabUseClock.noteActive(at: now)
        if let data = try? JSONEncoder().encode(tabUseClock) { preferences.set(data, forKey: Self.tabUseClockKey) }
        let visible = Set(visibleTabIDs)
        for tab in tabs where visible.contains(tab.id) { recordUse(of: tab, at: now) }
        if lastTabArchiveCheck.map({ now.timeIntervalSince($0) >= Self.tabArchiveInterval }) ?? true {
            lastTabArchiveCheck = now
            Task { await archiveUnusedTabs(now: now) }
        }
    }
    /// Other devices can't see why a tab should stay, as being pinned stays on this Mac, so they're told.
    func shareKeptTabs() {
        guard let tabSync else { return }
        for tab in tabs {
            let kept = tab.pinned || tab.customTitle != nil || tab.developer || tab.leftWithEdits || tab.isPlayingAudio
                || playbackPaused(tab.id) == false || splitGroups.contains { $0.contains(tab.id) }
            tabSync.setKept(tab.id, kept)
        }
    }
    func recordUse(of tab: BrowserTab, at date: Date = Date()) {
        if tab.use.record(at: date, every: Self.tabUseInterval) { scheduleSave() }
        tabSync?.recordUse(of: tab.id, at: date)
    }
    func scheduleTabUse(_ id: UUID) {
        tabUseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.selectedID == id, self.isUsingRise, let tab = self.selectedTab else { return }
            self.recordUse(of: tab)
        }
        tabUseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.tabUseDelay, execute: work)
    }

    /// The tabs in use in some way that isn't a matter of time.
    private func isProtectedFromArchiving(_ tab: BrowserTab, visible: Set<UUID>) -> Bool {
        tab.pinned || tab.customTitle != nil || tab.id == selectedID || visible.contains(tab.id) || tabSync?.isKept(tab.id) == true
            || splitGroups.contains { $0.contains(tab.id) } || tab.isLoading || tab.isPlayingAudio || playbackPaused(tab.id) == false
            || tab.page.view.superview != nil || pictureInPicture.owns(tab) || tab.isInNativeFullscreen
            || peek(for: tab.id) != nil || tabSwitchOrder.contains(tab.id) || assistantSubmissions[tab.id] != nil
    }
    /// The tabs due to be archived now, going by their use on every device.
    func tabsDueForArchiving(now: Date = Date()) -> [BrowserTab] {
        guard tabArchiveHours > 0 else { return [] }
        let visible = Set(visibleTabIDs)
        let candidates = tabs.map { tab -> TabArchiveRules.Tab in
            tab.use = tab.use.merging(tabSync?.use(of: tab.id))
            return TabArchiveRules.Tab(id: tab.id, use: tab.use, url: tab.url ?? tab.requestedURL, visits: browsingHistory.visits(to: tab.url ?? tab.requestedURL),
                                       isDeveloper: tab.developer, isProtected: isProtectedFromArchiving(tab, visible: visible))
        }
        let due = TabArchiveRules(limit: Double(tabArchiveHours)*3600).due(candidates, clock: tabUseClock, at: now)
        return due.compactMap { id in tabs.first { $0.id == id } }
    }
    /// Whether anything on the page has been typed into and not sent. A page in the background may
    /// have been frozen, which won't answer until it's shown, so it goes by how it was left.
    private func hasUnsentEdits(_ tab: BrowserTab) async -> Bool {
        let page = tab.page
        guard page.url != nil else { return false }
        return await withCheckedContinuation { continuation in
            var answered = false
            func answer(_ edits: Bool) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: edits)
            }
            Task { answer((await page.evaluate(Self.editingScript, arguments: [:], world: "Rise.TabSleep") as? Bool) ?? tab.leftWithEdits) }
            DispatchQueue.main.asyncAfter(deadline: .now()+2) { answer(tab.leftWithEdits) }
        }
    }
    func noteEditsOnLeaving(_ tab: BrowserTab) {
        let page = tab.page
        guard page.url != nil else { return }
        Task { [weak tab] in
            let edits = await page.evaluate(Self.editingScript, arguments: [:], world: "Rise.TabSleep") as? Bool
            guard let tab, tab.page === page, let edits else { return }
            tab.leftWithEdits = edits
        }
    }

    /// Archives what's due. Uses on the phone that haven't arrived yet would otherwise look like no
    /// use at all, so with iCloud sync on and out of reach, it waits for another time.
    func archiveUnusedTabs(now: Date = Date()) async {
        guard !isArchivingTabs else { return }
        isArchivingTabs = true
        defer { isArchivingTabs = false }
        guard !tabsDueForArchiving(now: now).isEmpty else { return }
        let started = Date()
        if let tabSync, await !tabSync.refreshBeforeArchiving() { return }
        var ready: [BrowserTab] = []
        for tab in tabsDueForArchiving(now: now) where await !hasUnsentEdits(tab) { ready.append(tab) }
        // Time has passed since it asked, in which a tab may have been shown or closed.
        let later = now.addingTimeInterval(Date().timeIntervalSince(started))
        let due = Set(tabsDueForArchiving(now: later).map(\.id))
        guard canApplySharedTabs else { lastTabArchiveCheck = nil; return }
        archive(ready.filter { due.contains($0.id) }, at: later)
    }

    /// Moves tabs to the archive, offering to put them back where they were. A blank tab holds
    /// nothing to come back to, so it simply closes.
    func archive(_ chosen: [BrowserTab], at now: Date = Date()) {
        guard !chosen.isEmpty else { return }
        let listed = chosen.filter { $0.saved.url != "about:blank" }
        let places = listed.compactMap { tab in tabs.firstIndex { $0 === tab }.map { (id: tab.id, index: $0) } }.sorted { $0.index < $1.index }
        archivedTabs.add(listed.map(\.saved), at: now)
        tabSync?.archive(listed.map(\.id), at: now)
        for tab in chosen { closeTab(tab.id, remembering: false) }
        saveNow()
        guard !listed.isEmpty else { return }
        let words = listed.count == 1 ? "Archived 1 Unused Tab" : "Archived \(listed.count) Unused Tabs"
        selectedBar.showNotice(words, image: BarNotice.archiveImage, action: BarNotice.Link(text: "Undo") { [weak self] in
            self?.selectedBar.hideNotice()
            self?.restoreArchived(places)
        }, hold: 10)
    }
    /// Puts just-archived tabs back in their places, leaving the current tab as it is.
    private func restoreArchived(_ places: [(id: UUID, index: Int)]) {
        for place in places {
            guard let saved = takeArchived(place.id) else { continue }
            tabs.insert(reopened(saved), at: min(place.index, tabs.count))
        }
        update()
    }

    /// A tab from the archive, shown at the top of the list.
    func reopenArchivedTab(_ id: UUID) {
        guard let saved = takeArchived(id) else { return }
        let tab = reopened(saved)
        tabs.insert(tab, at: tabs.firstIndex { !$0.pinned } ?? tabs.count)
        select(tab.id)
    }
    /// Takes a tab out of the list, here and on every device.
    @discardableResult func takeArchived(_ id: UUID) -> SavedTab? {
        tabSync?.removeFromArchive(id)
        return archivedTabs.remove(id)
    }
    /// Follows what other devices have archived, reopened or deleted.
    func reconcileArchivedTabs() {
        guard let tabSync else { return }
        archivedTabs.reconcile(with: tabSync.archivedTabs().map(ArchivedTab.init), removed: tabSync.isRemovedFromArchive, open: Set(tabs.map(\.id)))
        (archivedTabsPopover.contentViewController as? ArchivedTabsController)?.reload()
    }
    @objc func showArchivedTabs() {
        if archivedTabsPopover.isShown { archivedTabsPopover.performClose(nil); return }
        let controller = ArchivedTabsController(archive: archivedTabs)
        controller.popover = archivedTabsPopover
        controller.remove = { [weak self] id in self?.takeArchived(id) }
        controller.reopen = { [weak self] id in
            self?.archivedTabsPopover.performClose(nil)
            self?.reopenArchivedTab(id)
        }
        archivedTabsPopover.contentViewController = controller
        showFromSidebarCorner(archivedTabsPopover)
    }
    var archivedTabsSummary: String {
        let count = archivedTabs.entries.count
        return count == 0 ? "Tabs archived for going unused are kept here for 90 days" : count == 1 ? "1 tab you can reopen" : "\(count) tabs you can reopen"
    }
}

extension BarNotice {
    static let archiveImage = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)) ?? linkImage
}

/// The list of archived tabs: a search field above them, the newest first. Clicking one or pressing
/// Return reopens it; its X lets it go for good.
@MainActor final class ArchivedTabsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let width: CGFloat = 340, rowHeight: CGFloat = 42, visibleRows = 8, header: CGFloat = 44
    private let archive: ArchivedTabs
    private let field = NSSearchField(), table = NSTableView(), scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private(set) var shown: [ArchivedTab] = []
    var reopen: ((UUID) -> Void)?
    var remove: ((UUID) -> Void)?
    weak var popover: NSPopover?

    init(archive: ArchivedTabs) { self.archive = archive; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.header+Self.rowHeight))
        field.placeholderString = "Search archived tabs"; field.delegate = self; field.setAccessibilityLabel("Search archived tabs")
        let column = NSTableColumn(identifier: .init("tab")); column.width = Self.width
        table.addTableColumn(column); table.headerView = nil; table.style = .plain
        table.rowHeight = Self.rowHeight; table.intercellSpacing = .zero; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(rowClicked); table.setAccessibilityLabel("Archived tabs")
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        [field, scroll, empty].forEach(view.addSubview)
        reload()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKey(); view.window?.makeFirstResponder(field)
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        field.frame = NSRect(x: 10, y: view.bounds.height-Self.header+10, width: view.bounds.width-20, height: 24)
        let list = NSRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height-Self.header)
        scroll.frame = list
        empty.frame = list.insetBy(dx: 12, dy: (list.height-18)/2)
    }
    func reload() {
        shown = archive.matching(field.stringValue)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        empty.stringValue = archive.entries.isEmpty ? "No archived tabs" : "No matches"
        empty.isHidden = !shown.isEmpty
        let height = Self.header+Self.rowHeight*CGFloat(max(1, min(shown.count, Self.visibleRows)))
        preferredContentSize = NSSize(width: Self.width, height: height)
        popover?.contentSize = preferredContentSize
    }
    func controlTextDidChange(_ notification: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): if shown.indices.contains(table.selectedRow) { reopen?(shown[table.selectedRow].id) }
        case #selector(NSResponder.cancelOperation(_:)): popover?.performClose(nil)
        default: return false
        }
        return true
    }
    private func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(0, table.selectedRow+delta), shown.count-1)
        table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc private func rowClicked() {
        guard shown.indices.contains(table.clickedRow) else { return }
        reopen?(shown[table.clickedRow].id)
    }
    private func removeRow(_ id: UUID) {
        remove?(id)
        reload()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = shown[row]
        return ArchivedTabRow(entry) { [weak self] in self?.removeRow(entry.id) }
    }
}

/// An archived tab's icon, title, site and when it was archived, with an X while the pointer's over it.
@MainActor private final class ArchivedTabRow: NSView {
    private static let ages: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .full; return formatter
    }()
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    private let close: NSButton
    private let remove: () -> Void
    init(_ entry: ArchivedTab, remove: @escaping () -> Void) {
        self.remove = remove
        close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from Archived Tabs") ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        icon.image = entry.tab.faviconData.flatMap(FaviconSnapshot.decode) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.setAccessibilityElement(false)
        title.stringValue = entry.tab.title; title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail
        let host = AddressResolver.displayHost(URL(string: entry.tab.url))
        let age = Date().timeIntervalSince(entry.archivedAt) < 60 ? "just now" : Self.ages.localizedString(for: entry.archivedAt, relativeTo: Date())
        detail.stringValue = "\(host) · \(age)"
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        close.isBordered = false; close.imageScaling = .scaleProportionallyDown; close.contentTintColor = .secondaryLabelColor
        close.target = self; close.action = #selector(removeClicked); close.isHidden = true; close.toolTip = "Remove from Archived Tabs"
        [icon, title, detail, close].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func removeClicked() { remove() }
    override func layout() {
        super.layout()
        let width = bounds.width, middle = bounds.height/2
        icon.frame = NSRect(x: 14, y: middle-8, width: 16, height: 16)
        close.frame = NSRect(x: width-32, y: middle-9, width: 18, height: 18)
        let textWidth = max(0, width-40-38)
        title.frame = NSRect(x: 40, y: middle, width: textWidth, height: 17)
        detail.frame = NSRect(x: 40, y: middle-16, width: textWidth, height: 15)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { close.isHidden = false }
    override func mouseExited(with event: NSEvent) { close.isHidden = true }
}
