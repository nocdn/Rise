import AppKit

@MainActor extension BrowserController {
    func reorderTabs(_ rowOrder: [UUID], animated: Bool = true) {
        var ids: [UUID] = []
        for id in rowOrder {
            let pair = splitGroups.first { $0.contains(id) }
            for member in pair.map({ [$0.leftID, $0.rightID] }) ?? [id] where !ids.contains(member) { ids.append(member) }
        }
        ids += tabs.map(\.id).filter { !ids.contains($0) }
        // Pinned tabs stay first, as Chrome extensions count them.
        let pinned = Set(tabs.filter(\.pinned).map(\.id))
        ids = ids.filter { pinned.contains($0) } + ids.filter { !pinned.contains($0) }
        guard ids != tabs.map(\.id) else { return }
        let existing = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id,$0) })
        tabOrderUndoPending = false
        tabs = ids.compactMap { existing[$0] }
        sidebar.update(tabs: sidebarTabs, selected: sidebarSelectedTab, theme: theme, splits: sidebarSplitGroups, animated: animated)
        scheduleSave()
    }
    /// One ID per sidebar row, including rows hidden by search, or per pinned tile.
    private var currentTabMoveRows: [UUID] {
        guard let tab = selectedTab else { return [] }
        var rows: [UUID] = []
        for other in tabs where other.pinned == tab.pinned {
            let id = splitGroups.first { $0.contains(other.id) }?.leftID ?? other.id
            if !rows.contains(id) { rows.append(id) }
        }
        return rows
    }
    private var currentTabRowID: UUID? { activeSplitGroup?.leftID ?? selectedID }
    var canMoveCurrentTabToTop: Bool { canMoveCurrentTab(by: -1) }
    func canMoveCurrentTab(by direction: Int) -> Bool {
        guard let id = currentTabRowID, let index = currentTabMoveRows.firstIndex(of: id) else { return false }
        return currentTabMoveRows.indices.contains(index+direction)
    }
    @objc func moveCurrentTabUp() { moveCurrentTab(by: -1) }
    @objc func moveCurrentTabDown() { moveCurrentTab(by: 1) }
    func moveCurrentTab(by direction: Int, coalescing: Bool = false) {
        var rows = currentTabMoveRows
        guard let id = currentTabRowID, let selectedID, let index = rows.firstIndex(of: id),
              rows.indices.contains(index+direction) else { return }
        let before = tabs.map(\.id)
        let continuing = coalescing && tabMoveSequence?.tabID == selectedID && tabMoveSequence?.order == before
        rows.swapAt(index, index+direction)
        reorderTabs(rows)
        revealCurrentTabRow()
        if !continuing { registerTabOrderUndo(before, name: "Move Tab") }
        tabOrderUndoPending = true
        tabMoveSequence = coalescing ? (selectedID, tabs.map(\.id)) : nil
    }
    /// Moves the current row (both halves of a split) first, keeping pinned tiles separate.
    @objc func moveCurrentTabToTop() {
        guard canMoveCurrentTabToTop, let id = selectedTab?.id else { return }
        tabMoveSequence = nil
        let before = tabs.map(\.id)
        reorderTabs([id] + before.filter { $0 != id })
        revealCurrentTabRow()
        registerTabOrderUndo(before, name: "Move Tab to Top")
    }
    private func revealCurrentTabRow() {
        if let id = currentTabRowID, let row = sidebar.displayedRow(for: id) { row.scrollToVisible(row.bounds) }
    }
    /// Take these before Chromium or a text field consumes the arrow or undo keys.
    func handleTabMoveEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(KeyboardShortcut.modifierMask)
        if event.type == .keyDown, keyboardShortcuts.matches("moveCurrentTabUp", event) || keyboardShortcuts.matches("moveCurrentTabDown", event) {
            tabMoveHeldModifiers = modifiers
            moveCurrentTab(by: keyboardShortcuts.matches("moveCurrentTabUp", event) ? -1 : 1, coalescing: true); return true
        }
        if event.type == .keyDown, keyboardShortcuts.matches("moveCurrentTabToTop", event) {
            moveCurrentTabToTop(); return true
        }
        // A ⌘Z on its way to the page goes there first, and can still undo the move after.
        if let pending = pendingPageKey, pending.timestamp == event.timestamp, ["undo:", "redo:"].contains(pending.commandID) { return false }
        if handleTabOrderUndoKey(event) { return true }
        if event.type == .keyDown {
            tabMoveSequence = nil
            tabOrderUndoPending = false
        } else if event.type == .flagsChanged, !modifiers.isSuperset(of: tabMoveHeldModifiers) {
            tabMoveSequence = nil
        } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            tabMoveSequence = nil
        }
        return false
    }
    /// The tab changes ⌘Z and ⇧⌘Z take back and redo before a page or a text field can.
    static let tabUndoNames = ["Move Tab", "Move Tab to Top", "Sort Tabs by Domain", "Unpin Tab"]
    /// What ⌘Z or ⇧⌘Z would do to the tabs' order, in words after "to".
    func tabOrderUndoAction(redo: Bool) -> String? {
        guard tabOrderUndoPending, let undo = window?.undoManager else { return nil }
        let names = Self.tabUndoNames
        if redo { return undo.canRedo && names.contains(undo.redoActionName) ? "redo \(undo.redoActionName)" : nil }
        return undo.canUndo && names.contains(undo.undoActionName) ? "undo \(undo.undoActionName)" : nil
    }
    func handleTabOrderUndoKey(_ event: NSEvent) -> Bool {
        guard tabOrderUndoPending, event.type == .keyDown,
              let undo = window?.undoManager else { return false }
        let names = Self.tabUndoNames
        if keyboardShortcuts.matches("undo:", event), undo.canUndo, names.contains(undo.undoActionName) { tabMoveSequence = nil; undo.undo(); return true }
        if keyboardShortcuts.matches("redo:", event), undo.canRedo, names.contains(undo.redoActionName) { tabMoveSequence = nil; undo.redo(); return true }
        return false
    }
    /// The sidebar's tiles hold this many; Pin Tab is off once they're full.
    var canPinTab: Bool { tabs.filter { $0.pinned && !isSplit($0.id) }.count < PinnedLayout.maximum }
    private func isSplit(_ id: UUID) -> Bool { splitGroups.contains { $0.contains(id) } }
    /// Pins a tab into the tiles at `slot`, or last.
    func pinTab(_ id: UUID, at slot: Int? = nil) {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.pinned, !isSplit(id), canPinTab else { update(); return }
        tab.pinned = true
        var pinned = tabs.filter { $0.pinned && $0 !== tab }
        pinned.insert(tab, at: min(slot ?? pinned.count, pinned.count))
        tabs = pinned + tabs.filter { !$0.pinned }
        update()
    }
    /// Unpins a tab into the list at `index` among its rows, or at its top.
    /// Dropped into the list, the rows have already made room; from a menu, they make it now.
    /// ⌘Z pins it back where its tile was.
    func unpinTab(_ id: UUID, at index: Int = 0, animated: Bool = false, flies: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.pinned else { update(); return }
        let slot = tabs.filter(\.pinned).firstIndex { $0.id == id } ?? 0
        let start = flies ? sidebar.pinFlightStart(for: id) : nil
        tab.pinned = false
        var order = sidebar.orderedIDs.filter { $0 != id }
        order.insert(id, at: min(index, order.count))
        reorderTabs(order, animated: animated)
        update()
        if let start { sidebar.flyPinChange(id, from: start) }
        registerUnpinUndo(id, slot: slot, row: sidebar.orderedIDs.firstIndex(of: id) ?? index)
    }
    /// From a menu: the tab travels to the tiles, or back to the top of the list.
    func togglePin(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.pinned { unpinTab(id, animated: true, flies: true); return }
        let start = sidebar.pinFlightStart(for: id)
        pinTab(id)
        if tab.pinned, let start { sidebar.flyPinChange(id, from: start) }
    }
    /// ⌘Z travels an unpinned tab back to its tile at `slot`, and ⇧⌘Z back to its row at `row`.
    private func registerUnpinUndo(_ id: UUID, slot: Int, row: Int) {
        guard let undoManager = window?.undoManager else { return }
        let ownGroup = undoManager.groupingLevel == 0
        if ownGroup { undoManager.beginUndoGrouping() }
        defer { if ownGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { browser in
            MainActor.assumeIsolated {
                guard let tab = browser.tabs.first(where: { $0.id == id }), !tab.pinned else { return }
                let start = browser.sidebar.pinFlightStart(for: id)
                browser.pinTab(id, at: slot)
                guard tab.pinned else { return }
                if let start { browser.sidebar.flyPinChange(id, from: start) }
                undoManager.registerUndo(withTarget: browser) { browser in
                    MainActor.assumeIsolated { browser.unpinTab(id, at: row, animated: true, flies: true) }
                }
                undoManager.setActionName("Unpin Tab")
                browser.tabOrderUndoPending = true
            }
        }
        undoManager.setActionName("Unpin Tab")
        tabOrderUndoPending = true
    }
    func reorderPinnedTabs(_ order: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let pinned = order.compactMap { byID[$0] }.filter(\.pinned)
        let next = pinned + tabs.filter { !pinned.contains($0) }
        guard next.map(\.id) != tabs.map(\.id) else { return }
        tabs = next
        sidebar.update(tabs: sidebarTabs, selected: sidebarSelectedTab, theme: theme, splits: sidebarSplitGroups)
        scheduleSave()
    }
    func renameTab(_ id: UUID, title: String) { tabs.first { $0.id == id }?.rename(title) }
    /// Brings tabs from the same site together, where that site's first tab is. Everything
    /// else keeps its order, and split tabs move as a pair with the left tab's site.
    @objc func cleanUpTabs() {
        var groups: [[UUID]] = [], groupIndex: [String: Int] = [:]
        for tab in tabs {
            let pair = splitGroups.first { $0.contains(tab.id) }
            guard pair == nil || pair?.leftID == tab.id else { continue }
            let key = Self.cleanUpKey(tab.url)
            if let key, let index = groupIndex[key] { groups[index].append(tab.id) }
            else {
                if let key { groupIndex[key] = groups.count }
                groups.append([tab.id])
            }
        }
        let before = tabs.map(\.id)
        reorderTabs(groups.flatMap { $0 }, animated: false)
        registerTabOrderUndo(before, name: "Sort Tabs by Domain")
    }
    /// ⌘Z puts the tabs back in `order`, and ⇧⌘Z redoes the change. Tabs opened since go last;
    /// closed ones are skipped.
    private func registerTabOrderUndo(_ order: [UUID], name: String) {
        guard order != tabs.map(\.id), let undoManager = window?.undoManager else { return }
        let ownGroup = undoManager.groupingLevel == 0
        if ownGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { browser in
            MainActor.assumeIsolated {
                let current = browser.tabs.map(\.id)
                browser.reorderTabs(order.filter { id in browser.tabs.contains { $0.id == id } }, animated: false)
                browser.revealCurrentTabRow()
                browser.registerTabOrderUndo(current, name: name)
            }
        }
        undoManager.setActionName(name)
        if ownGroup { undoManager.endUndoGrouping() }
        tabOrderUndoPending = true
    }
    /// A tab's site for clean up: its host without `www.`. Pages without one stay where they are.
    static func cleanUpKey(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
