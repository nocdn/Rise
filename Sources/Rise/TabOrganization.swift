import AppKit

@MainActor extension BrowserController {
    func reorderTabs(_ rowOrder: [UUID]) {
        var ids: [UUID] = []
        for id in rowOrder {
            let pair = splitGroups.first { $0.contains(id) }
            for member in pair.map({ [$0.leftID, $0.rightID] }) ?? [id] where !ids.contains(member) { ids.append(member) }
        }
        ids += tabs.map(\.id).filter { !ids.contains($0) }
        guard ids != tabs.map(\.id) else { return }
        let existing = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id,$0) })
        tabs = ids.compactMap { existing[$0] }
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: splitGroups)
        scheduleSave()
    }
    func renameTab(_ id: UUID, title: String) { tabs.first { $0.id == id }?.rename(title) }
}
