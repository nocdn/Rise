import AppKit
import RiseCore

@MainActor extension BrowserController {
    var activeSplitGroup: SplitTabGroup? {
        selectedID.flatMap { id in splitGroups.first { $0.contains(id) } }
    }
    var splitTab: BrowserTab? {
        guard let group = activeSplitGroup else { return nil }
        let other = selectedID == group.leftID ? group.rightID : group.leftID
        return tabs.first { $0.id == other }
    }
    var visibleTabIDs: [UUID] {
        if let group = activeSplitGroup { return [group.leftID, group.rightID] }
        return selectedID.map { [$0] } ?? []
    }
    func attachVisiblePages() {
        let visible = Set(visibleTabIDs)
        pictureInPicture.reconcile(visibleIDs: visible)
        for tab in tabs {
            if pictureInPicture.owns(tab) { continue }
            if !visible.contains(tab.id) { tab.webView.removeFromSuperview(); continue }
            if tab.needsBlockingReload, tab.webView.url != nil { tab.needsBlockingReload = false; tab.webView.reloadFromOrigin() }
            if tab.webView.url == nil, !tab.hasAttemptedNavigation, !tab.webView.isLoading, let url = tab.requestedURL { tab.load(url) }
            if tab.webView.superview !== pageClip { pageClip.addSubview(tab.webView, positioned: .below, relativeTo: developerBar) }
        }
    }
    @objc func toggleSplit() {
        if let selectedID, activeSplitGroup != nil { separateSplit(containing: selectedID); return }
        guard let current = selectedTab else { return }
        if let other = tabs.first(where: { $0.id != current.id }) { showSplit(other) }
        else if let url = current.url {
            let other = configure(BrowserTab()); tabs.insert(other, at: 0); other.load(url); showSplit(other)
        }
    }
    func showSplit(_ tab: BrowserTab) {
        guard let current = selectedID, tab.id != current, tabs.contains(where: { $0.id == tab.id }) else { return }
        splitGroups.removeAll { $0.contains(current) || $0.contains(tab.id) }
        splitGroups.append(SplitTabGroup(leftID: current, rightID: tab.id))
        select(current)
    }
    func separateSplit(containing id: UUID) {
        splitGroups.removeAll { $0.contains(id) }
        attachVisiblePages(); update()
    }
    func focusSplitPage(at event: NSEvent) {
        guard activeSplitGroup != nil, peekTab == nil, palette.isHidden, !isSwitchingTabs else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        guard let hit = root.hitTest(point) else { return }
        for tab in tabs where visibleTabIDs.contains(tab.id) && tab.id != selectedID {
            if hit === tab.webView || hit.isDescendant(of: tab.webView) { select(tab.id); return }
        }
    }
}
