import AppKit
import RiseCore

@MainActor extension BrowserController {
    var sharedTabsSnapshot: [SharedBrowserTab] {
        tabs.compactMap { tab in
            let saved = tab.saved
            let address = saved.url
            let value = SharedBrowserTab(id: tab.id, url: address == "about:blank" ? nil : address, title: tab.title,
                                         navigationHistory: saved.navigationHistory)
            return value.isShareable ? value : nil
        }
    }

    func startTabSync() {
        let sync = SharedTabsSync(cacheURL: sessionURL.deletingLastPathComponent().appendingPathComponent("SharedTabs.json"), preferences: preferences)
        tabSync = sync
        sync.onTabsChange = { [weak self] in self?.applySharedTabs($0) }
        sync.onSearchesChange = { [weak self] in
            guard let self, self.palette.isPresented else { return }
            self.palette.refresh()
        }
        sync.onHistoryChange = { [weak self] in
            guard let self, self.palette.isPresented else { return }
            self.palette.refresh()
        }
        sync.onArchiveChange = { [weak self] in self?.reconcileArchivedTabs() }
        sync.start(tabs: sharedTabsSnapshot, learnedSearches: siteSearchLearner.searches, browsingHistory: browsingHistory)
        reconcileArchivedTabs()
    }

    var canApplySharedTabs: Bool {
        !isApplyingSharedTabs && !isSelectingTab && !palette.isPresented && peekTab == nil && !isSwitchingTabs && !isScrollingTabs
            && sidebar.drag == nil && !historySwipe.isActive && window?.attachedSheet == nil
    }

    func applyPendingSharedTabs() {
        guard hasPendingSharedTabs, let tabSync, tabSync.isEnabled else { return }
        applySharedTabs(tabSync.tabs)
    }

    func applySharedTabs(_ incoming: [SharedBrowserTab]) {
        guard canApplySharedTabs else { hasPendingSharedTabs = true; return }
        isApplyingSharedTabs = true; hasPendingSharedTabs = false
        let selected = selectedID, index = tabs.firstIndex { $0.id == selected } ?? 0
        let existing = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let snapshot = sharedTabsSnapshot
        let incoming = SharedTabsReconciliation.preservingActiveTab(in: incoming, displayed: snapshot, activeID: selected)
        let displayed = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        let sharedIDs = Set(displayed.keys)
        let localTabs = tabs.filter { !sharedIDs.contains($0.id) }
        let next = incoming.map { value -> BrowserTab in
            if let tab = existing[value.id], displayed[value.id]?.url == value.url,
               value.navigationHistory.map({ tab.navigationHistory?.hasSameRoute(as: $0) == true }) ?? true {
                if tab.customTitle == nil { tab.title = value.title ?? "New Tab" }
                return tab
            }
            var saved = existing[value.id]?.saved ?? SavedTab(id: value.id, url: "about:blank", title: "New Tab")
            saved.url = value.url ?? "about:blank"; saved.title = value.title ?? "New Tab"
            saved.navigationHistory = value.navigationHistory
            saved.sessionState = nil; saved.faviconData = nil; saved.darkFaviconData = nil; saved.faviconOrigin = nil
            return configure(BrowserTab(saved: saved))
        } + localTabs
        for old in tabs where !next.contains(where: { $0 === old }) {
            // Archived on another device: kept with what only this Mac has, such as its session.
            if tabSync?.isArchived(old.id) == true { archivedTabs.add([old.saved]) }
            discardPeek(for: old.id)
            old.onChange = nil; old.onThumbnailChange = nil; old.onFullscreenChange = nil
            pictureInPicture.remove(old); tabMedia.remove(old.id)
            pageFullscreen.setActive(false, in: old.page.view)
            releaseHeldPages(of: old); permissionCoordinator.cancel(for: old.page.view)
            old.cancelLoad(); old.page.view.removeFromSuperview()
            findBars.removeValue(forKey: old.id)?.discard()
        }
        tabs = next
        let ids = Set(tabs.map(\.id))
        splitGroups.removeAll { !ids.contains($0.leftID) || !ids.contains($0.rightID) }
        recentTabIDs.removeAll { !ids.contains($0) }
        selectedID = selected.flatMap { ids.contains($0) ? $0 : nil } ?? (tabs.isEmpty ? nil : tabs[min(index, tabs.count-1)].id)
        tabSync?.acknowledge(sharedTabsSnapshot)
        attachVisiblePages(); update()
        isApplyingSharedTabs = false
        saveNow()
    }
}
