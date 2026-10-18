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
        tabs = ids.compactMap { existing[$0] }
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: splitGroups, animated: animated)
        scheduleSave()
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
    func unpinTab(_ id: UUID, at index: Int = 0, animated: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == id }), tab.pinned else { update(); return }
        tab.pinned = false
        var order = sidebar.orderedIDs.filter { $0 != id }
        order.insert(id, at: min(index, order.count))
        reorderTabs(order, animated: animated)
        update()
    }
    /// From a menu: the tab travels to the tiles, or back to the top of the list.
    func togglePin(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let wasPinned = tab.pinned, start = sidebar.pinFlightStart(for: id)
        if wasPinned { unpinTab(id, animated: true) } else { pinTab(id) }
        if tab.pinned != wasPinned, let start { sidebar.flyPinChange(id, from: start) }
    }
    func reorderPinnedTabs(_ order: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let pinned = order.compactMap { byID[$0] }.filter(\.pinned)
        let next = pinned + tabs.filter { !pinned.contains($0) }
        guard next.map(\.id) != tabs.map(\.id) else { return }
        tabs = next
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: splitGroups)
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
        undoManager.registerUndo(withTarget: self) { browser in
            MainActor.assumeIsolated {
                let current = browser.tabs.map(\.id)
                browser.reorderTabs(order.filter { id in browser.tabs.contains { $0.id == id } }, animated: false)
                browser.registerTabOrderUndo(current, name: name)
            }
        }
        undoManager.setActionName(name)
    }
    /// A tab's site for clean up: its host without `www.`. Pages without one stay where they are.
    static func cleanUpKey(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
