import AppKit

/// A Peek growing into its tab hands its live page over instead of loading it again. The
/// tab's page from before is held, live and paused, so Back returns to it without reloading
/// once the new page's own history runs out, and Forward goes back again.
@MainActor extension BrowserController {
    /// How many earlier pages a tab keeps live for Back; older ones are let go.
    static let heldPageLimit = 3

    /// Shows `page`'s live page in `tab`, holding the tab's page from before for Back.
    func handOff(_ page: BrowserTab, into tab: BrowserTab) {
        trade(tab, with: page)
        hold(page)
        tab.backPages.append(page)
        while tab.backPages.count > Self.heldPageLimit { release(tab.backPages.removeFirst()) }
        dropForwardPages(of: tab)
        settle(tab)
    }
    /// Swaps the pages; what the tab knew about its old page's video and media goes with it.
    func trade(_ tab: BrowserTab, with holder: BrowserTab) {
        pictureInPicture.remove(tab); tabMedia.remove(tab.id)
        tab.exchangePages(with: holder)
    }
    /// Whether `tab` can go that way, through its page's history or its held pages, and for
    /// Back, finally to the tab that opened it.
    func canGo(_ direction: HistoryDirection, in tab: BrowserTab) -> Bool {
        direction == .back ? tab.page.canGoBack || !tab.backPages.isEmpty || opener(returningFrom: tab) != nil
                           : tab.page.canGoForward || !tab.forwardPages.isEmpty
    }
    /// The tab Back returns to from `tab`, a page a site opened in a new tab, while it's still open.
    func opener(returningFrom tab: BrowserTab) -> BrowserTab? {
        guard let id = tab.returnsTo, id != tab.id else { return nil }
        return tabs.first { $0.id == id }
    }
    /// Steps to the held page that way, once the page's own history has run out; past those,
    /// Back closes a page a site opened in a new tab and returns to the tab that opened it.
    @discardableResult func goThroughHeldPages(_ direction: HistoryDirection, in tab: BrowserTab) -> Bool {
        guard let held = direction == .back ? tab.backPages.popLast() : tab.forwardPages.popLast() else {
            guard direction == .back, let opener = opener(returningFrom: tab) else { return false }
            // The opener shows first, so closing doesn't pass through a neighbouring tab.
            select(opener.id); closeTab(tab.id)
            return true
        }
        trade(tab, with: held)
        hold(held)
        if direction == .back { tab.forwardPages.append(held) } else { tab.backPages.append(held) }
        settle(tab)
        return true
    }
    /// The page showing in `view`: a tab's, the Peek's, or the one waiting on a Shift-hover.
    func page(showing view: NSView?) -> WebPage? {
        guard let view else { return nil }
        return (tabs + allPeekTabs + [peekStandby?.tab].compactMap { $0 }).first { $0.page.view === view }?.page
    }
    /// The page the swipe or the arrows act on, going `direction`: its own history first, then held pages.
    func navigate(_ page: WebPage, _ direction: HistoryDirection) {
        let own = direction == .back ? page.canGoBack : page.canGoForward
        if own { if direction == .back { page.goBack() } else { page.goForward() }; return }
        if let tab = tabs.first(where: { $0.page === page }) { goThroughHeldPages(direction, in: tab) }
    }
    func canNavigate(_ page: WebPage, _ direction: HistoryDirection) -> Bool {
        if let tab = tabs.first(where: { $0.page === page }) { return canGo(direction, in: tab) }
        return direction == .back ? page.canGoBack : page.canGoForward
    }
    /// Going somewhere new leaves the later pages behind, as a browser's forward history does.
    func dropForwardPages(of tab: BrowserTab) {
        tab.forwardPages.forEach(release); tab.forwardPages = []
    }
    /// Lets go of every page a closing tab was holding.
    func releaseHeldPages(of tab: BrowserTab) {
        (tab.backPages+tab.forwardPages).forEach(release); tab.backPages = []; tab.forwardPages = []
    }
    /// Keeps a page off screen, paused, until Back or Forward needs it.
    func hold(_ holder: BrowserTab) {
        historySwipe.cancel(for: holder.page)
        permissionCoordinator.cancel(for: holder.page.view)
        holder.page.view.removeFromSuperview(); holder.page.setMediaSuspended(true)
    }
    private func release(_ holder: BrowserTab) {
        holder.cancelLoad(); holder.page.view.removeFromSuperview()
    }
    /// Puts the tab's new page on screen where its old one was.
    func settle(_ tab: BrowserTab, recordsVisit: Bool = true) {
        tab.page.setMediaSuspended(false)
        attachVisiblePages(); updatePeekCovers(); layoutChrome()
        findBars[tab.id]?.pageChanged()
        if recordsVisit, let url = tab.url, url.absoluteString != "about:blank" {
            browsingHistory.record(url, title: historyTitle(tab.page.title ?? tab.title, url: url))
            discoverPageFavicon(tab.page)
        }
        if tab.id == selectedID { window?.makeFirstResponder(tab.page.view) }
        update()
    }
}
