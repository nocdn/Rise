import AppKit
import RiseCore

/// Keeps the actual page, rather than its address, so a tab switch preserves forms, scroll,
/// navigation history and a load still in progress. The surrounding card is rebuilt on return.
struct SuspendedPeek {
    let tab: BrowserTab
    let sourceID: UUID?
    let opensNewTab: Bool
    let origin: PeekOrigin?
}

@MainActor extension BrowserController {
    var peekOwnerID: UUID? { peekTab == nil ? nil : peekSourceTabID ?? selectedID }
    var allPeekTabs: [BrowserTab] { suspendedPeeks.values.map(\.tab).filter { $0 !== peekTab } + [peekTab].compactMap { $0 } }

    func peek(for id: UUID) -> BrowserTab? {
        peekOwnerID == id ? peekTab : suspendedPeeks[id]?.tab
    }

    func suspendPeek() {
        guard let tab = peekTab else { return }
        guard let owner = peekOwnerID, tabs.contains(where: { $0.id == owner }) else { closePeek(); return }
        suspendedPeeks[owner] = SuspendedPeek(tab: tab, sourceID: peekSourceTabID, opensNewTab: peekOpensNewTab, origin: peekOrigin)
        suspendFindBar(for: tab)
        // Closing the presentation mustn't stop the page's current load.
        peekTab = nil
        closePeek()
        tab.page.view.removeFromSuperview()
        setCovered(true, tab)
        tab.page.setMediaSuspended(true)
    }

    func restoreSuspendedPeek() {
        guard peekTab == nil,
              let owner = visibleTabIDs.first(where: { suspendedPeeks[$0] != nil }),
              let saved = suspendedPeeks[owner] else { return }
        let source = saved.sourceID.flatMap { id in tabs.first { $0.id == id } }
        showPeek(url: saved.tab.url ?? URL(string: "about:blank")!, from: source?.page.view,
                 opensNewTab: saved.opensNewTab, existing: saved.tab, animated: false)
        suspendedPeeks.removeValue(forKey: owner)
        peekOrigin = saved.origin
        saved.tab.page.setMediaSuspended(false)
        if saved.tab.needsBlockingReload { saved.tab.needsBlockingReload = false; saved.tab.page.reloadIgnoringCache() }
        // A Peek kept from last time loads its page, with its history, once it shows.
        let tab = saved.tab
        if tab.page.url == nil, !tab.hasAttemptedNavigation, !tab.page.isLoading, let url = tab.requestedURL { tab.load(url) }
    }

    /// Every tab's Peek, the one open and those waiting behind their tabs, for the session.
    var savedPeeks: [SavedPeek] {
        var peeks = suspendedPeeks.map { owner, peek in
            SavedPeek(ownerID: owner, tab: peek.tab.saved, sourceID: peek.sourceID, opensNewTab: peek.opensNewTab)
        }
        if let peekTab, let owner = peekOwnerID, tabs.contains(where: { $0.id == owner }) {
            peeks.removeAll { $0.ownerID == owner }
            peeks.append(SavedPeek(ownerID: owner, tab: peekTab.saved, sourceID: peekSourceTabID, opensNewTab: peekOpensNewTab))
        }
        return peeks.sorted { a, b in
            (tabs.firstIndex { $0.id == a.ownerID } ?? 0) < (tabs.firstIndex { $0.id == b.ownerID } ?? 0)
        }
    }

    /// Puts the session's Peeks back behind their tabs, unloaded; selecting a tab shows its own,
    /// as after switching away from it, and loads it then.
    func restorePeeks(_ peeks: [SavedPeek]) {
        for peek in SavedPeek.valid(peeks, tabIDs: tabs.map(\.id)) {
            let tab = configure(BrowserTab(saved: peek.tab))
            suspendedPeeks[peek.ownerID] = SuspendedPeek(tab: tab, sourceID: peek.sourceID, opensNewTab: peek.opensNewTab, origin: nil)
        }
    }

    /// Closing an owner tab also releases its Peek, including one currently out of sight.
    func discardPeek(for owner: UUID) {
        if peekOwnerID == owner { closePeek() }
        guard let saved = suspendedPeeks.removeValue(forKey: owner) else { return }
        permissionCoordinator.cancel(for: saved.tab.page.view)
        findBars.removeValue(forKey: saved.tab.id)?.discard()
        saved.tab.cancelLoad(); saved.tab.page.view.removeFromSuperview()
        tabMedia.remove(saved.tab.id)
    }

    /// A page can close itself while its owner is in the background.
    func closePage(_ view: NSView?) {
        guard let view else { return }
        if let tab = tabs.first(where: { $0.page.view === view }) { closeTab(tab.id) }
        else if peekTab?.page.view === view { closePeek(animated: true) }
        else if let owner = suspendedPeeks.first(where: { $0.value.tab.page.view === view })?.key {
            discardPeek(for: owner); update()
        }
    }
}
