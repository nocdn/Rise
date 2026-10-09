import AppKit
import WebKit

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
    /// Whether `tab` can go that way, through its page's history or its held pages.
    func canGo(_ direction: HistoryDirection, in tab: BrowserTab) -> Bool {
        direction == .back ? tab.webView.canGoBack || !tab.backPages.isEmpty
                           : tab.webView.canGoForward || !tab.forwardPages.isEmpty
    }
    /// Steps to the held page that way, once the page's own history has run out.
    @discardableResult func goThroughHeldPages(_ direction: HistoryDirection, in tab: BrowserTab) -> Bool {
        guard let held = direction == .back ? tab.backPages.popLast() : tab.forwardPages.popLast() else { return false }
        trade(tab, with: held)
        hold(held)
        if direction == .back { tab.forwardPages.append(held) } else { tab.backPages.append(held) }
        settle(tab)
        return true
    }
    /// The page the swipe or the arrows act on, going `direction`: its own history first, then held pages.
    func navigate(_ page: WKWebView, _ direction: HistoryDirection) {
        let own = direction == .back ? page.canGoBack : page.canGoForward
        if own { if direction == .back { page.goBack() } else { page.goForward() }; return }
        if let tab = tabs.first(where: { $0.webView === page }) { goThroughHeldPages(direction, in: tab) }
    }
    func canNavigate(_ page: WKWebView, _ direction: HistoryDirection) -> Bool {
        if let tab = tabs.first(where: { $0.webView === page }) { return canGo(direction, in: tab) }
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
        historySwipe.cancel(for: holder.webView); pageCloth.cancel(for: holder.webView)
        permissionCoordinator.cancel(for: holder.webView)
        holder.webView.removeFromSuperview(); holder.webView.setAllMediaPlaybackSuspended(true)
    }
    private func release(_ holder: BrowserTab) {
        holder.cancelLoad(); holder.webView.removeFromSuperview()
    }
    /// Puts the tab's new page on screen where its old one was.
    func settle(_ tab: BrowserTab, recordsVisit: Bool = true) {
        tab.webView.setAllMediaPlaybackSuspended(false)
        attachVisiblePages(); updatePeekCovers(); layoutChrome()
        findBars[tab.id]?.pageChanged()
        if recordsVisit, let url = tab.url, url.absoluteString != "about:blank" {
            browsingHistory.record(url, title: tab.webView.title ?? tab.title)
            discoverPageFavicon(tab.webView)
        }
        if tab.id == selectedID { window?.makeFirstResponder(tab.webView) }
        update()
    }
}
