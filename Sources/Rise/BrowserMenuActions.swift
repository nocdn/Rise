import AppKit
import RiseCore

@MainActor extension BrowserController {
    @objc func openFile() {
        showPageOpenPanel(multiple: true, directories: false) { [weak self] urls in
            for url in urls ?? [] { self?.addTab(url: url) }
        }
    }
    @objc func duplicateCurrentTab() {
        guard let tab = selectedTab, let url = tab.url else { return }
        addTab(url: url, opener: tab.id)
    }
    @objc func pinCurrentTab() { if let id = selectedTab?.id { togglePin(id) } }
    /// Pinned tabs and the other half of a split stay open during bulk closes.
    var otherClosableTabs: [BrowserTab] {
        let visible = Set(visibleTabIDs)
        return tabs.filter { !visible.contains($0.id) && !$0.pinned }
    }
    var closableTabsBelow: [BrowserTab] {
        guard let lastVisible = tabs.lastIndex(where: { visibleTabIDs.contains($0.id) }) else { return [] }
        return tabs.dropFirst(lastVisible+1).filter { !$0.pinned }
    }
    @objc func closeOtherTabs() { for tab in otherClosableTabs.reversed() { closeTab(tab.id) } }
    @objc func closeTabsBelow() { for tab in closableTabsBelow.reversed() { closeTab(tab.id) } }
    @objc func stopLoadingPage() { commandTab?.cancelLoad(); update() }
    @objc func savePageScreenshot() { capturePage() }
    @objc func capturePageImage() { captureWholePage(.jpeg) }
    @objc func capturePagePDF() { captureWholePage(.pdf) }
    /// Chrome's print preview over the page commands act on, as Chrome's File > Print shows it.
    @objc func printPage() { (commandTab?.page as? ChromiumPage)?.browserView.printPage() }
    @objc func printPageUsingSystemDialog() { (commandTab?.page as? ChromiumPage)?.browserView.printPageUsingSystemDialog() }
    @objc func showPageSource() { viewSource() }
    @objc func showSiteInformation() { siteInformation() }
    /// The page's site is asked again for its camera, microphone, location and notifications, at
    /// once, as if it had never asked; the page bar says so.
    @objc func resetSitePermissions() {
        guard let url = commandTab?.url, let origin = SitePermissions.origin(url) else { return }
        sitePermissions.reset(origin: origin)
        selectedBar.showNotice("Reset Permissions for \(url.host ?? origin)", image: BarNotice.resetImage)
    }
    @objc func manageExtensions() { showExtensions() }
    @objc func showProject() { addTab(url: URL(string: "https://github.com/nocdn/Rise")!) }
    @objc func reportIssue() { addTab(url: URL(string: "https://github.com/nocdn/Rise/issues")!) }
}

/// AppKit asks as a menu opens and before invoking its shortcuts. Titles, checkmarks and
/// availability follow the current tab instead of the state when the menu bar was made.
extension BrowserController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // The selected tab for what's done to tabs; the page commands act on, an open Peek's
        // included, for what's done to pages.
        let tab = selectedTab, page = commandTab
        let tabHasPage = tab?.url != nil, hasPage = page?.url != nil
        switch item.action {
        case #selector(annotateSelection): return PageAnnotationStore.key(for: page?.url) != nil
        case #selector(removePageAnnotations):
            return PageAnnotationStore.key(for: page?.url).map { !annotations.store.document(for: $0).annotations.isEmpty } ?? false
        case #selector(selectNumberedTab(_:)):
            guard tabs.indices.contains(item.tag) else {
                item.title = "Tab \(item.tag+1)"; item.toolTip = nil; item.state = .off; return false
            }
            let target = tabs[item.tag]
            item.title = "\(item.tag+1). \(target.title)"; item.toolTip = target.url?.absoluteString
            item.state = selectedID == target.id ? .on : .off
            return true
        case #selector(goBack): return historyPage.map { canNavigate($0, .back) } ?? false
        case #selector(goForward): return historyPage.map { canNavigate($0, .forward) } ?? false
        case #selector(reopenTab): return !closedTabs.isEmpty
        case #selector(closeCurrentTab): return tab != nil || peekTab != nil
        case #selector(stashPeekInNewTab): return peekTab != nil && !isPromotingPeek
        case #selector(nextTab), #selector(previousTab), #selector(cleanUpTabs): return tabs.count > 1
        case #selector(moveCurrentTabToTop): return canMoveCurrentTabToTop
        case #selector(moveCurrentTabUp): return canMoveCurrentTab(by: -1)
        case #selector(moveCurrentTabDown): return canMoveCurrentTab(by: 1)
        case #selector(duplicateCurrentTab), #selector(duplicateIntoSplit): return tabHasPage
        case #selector(pinCurrentTab):
            item.title = tab?.pinned == true ? "Unpin Tab" : "Pin Tab"
            return tab.map { tab in tab.pinned || canPinTab && !splitGroups.contains { $0.contains(tab.id) } } ?? false
        case #selector(closeOtherTabs): return tab != nil && !otherClosableTabs.isEmpty
        case #selector(closeTabsBelow): return !closableTabsBelow.isEmpty
        case #selector(toggleSidebar):
            item.title = sidebarVisible ? "Hide Sidebar" : "Show Sidebar"; return true
        case #selector(toggleDownloads):
            item.title = downloadsPopover.isShown ? "Hide Downloads" : "Show Downloads"; return true
        case #selector(toggleSplit):
            item.title = activeSplitGroup == nil ? "Split View" : "Separate Split Tabs"
            return tab != nil && (tabs.count > 1 || tabHasPage)
        case #selector(toggleDeveloper): item.state = tab?.developer == true ? .on : .off; return tab != nil
        case #selector(toggleCookieConsent):
            item.state = cookieConsent.isEnabled(for: page?.url) ? .on : .off
            return CookieConsentPolicy.site(page?.url) != nil
        case #selector(toggleAutomaticPictureInPicture):
            let origin = SitePermissions.origin(page?.url)
            item.state = sitePermissions.automaticPictureInPicture(origin: origin) ? .on : .off
            return origin != nil
        case #selector(toggleLinkPreloading): item.state = linkPreloader.enabled ? .on : .off; return true
        case #selector(toggleYouTubeAutoplay): item.state = youTubeAutoplay.isEnabled ? .on : .off; return true
        case #selector(toggleAIChat): item.title = aiChat.isOpen ? "Hide Chat" : "Show Chat"; return true
        case #selector(toggleDevTools):
            item.title = devTools.shows(.elements, in: tab?.id) ? "Hide Developer Tools" : "Inspect Elements"
            return tab?.page is ChromiumPage
        case #selector(toggleDevToolsConsole):
            item.title = devTools.shows(.console, in: tab?.id) ? "Hide Developer Tools" : "Show Console"
            return tab?.page is ChromiumPage
        case #selector(toggleSimulatedFullscreen): item.state = pageFullscreen.isSimulated ? .on : .off; return true
        case #selector(stopLoadingPage): return page?.isLoading == true
        case #selector(printPage): return (page?.page as? ChromiumPage)?.browserView.canPrint == true
        // From the print preview too, which hands its job to the system's dialog.
        case #selector(printPageUsingSystemDialog): return hasPage && page?.page is ChromiumPage
        case #selector(zoomIn): return hasPage && (page?.page.zoom ?? 1) < 3
        case #selector(zoomOut): return hasPage && (page?.page.zoom ?? 1) > 0.3
        case #selector(actualSize): return hasPage
        case #selector(toggleLocalTimes):
            item.state = (findTab?.page as? ChromiumPage).map { timeReplacement.isActive(in: $0) } == true ? .on : .off
            return findTab?.page is ChromiumPage && palette.isHidden
        case #selector(copyURL), #selector(shareCurrentPage): return hasPage && page?.url?.absoluteString != "about:blank"
        case #selector(showPageSource): return ["http", "https", "file"].contains(page?.url?.scheme ?? "")
        case #selector(javascriptConsole): return page?.page is ChromiumPage
        case #selector(showSettings), #selector(manageExtensions): return ChromiumEngine.isRunning
        case #selector(showFind), #selector(findNext), #selector(findPrevious), #selector(skipToNextMatch), #selector(skipToPreviousMatch): return findTab?.url != nil
        case #selector(peekCurrentPage): return tabHasPage
        case #selector(reload), #selector(hardReload), #selector(savePageScreenshot), #selector(capturePageImage), #selector(capturePagePDF),
             #selector(showSiteInformation): return hasPage
        case #selector(resetSitePermissions): return SitePermissions.origin(page?.url) != nil
        case #selector(toggleCardMotionTester):
            item.state = CardMotionTester.shared.isOn ? .on : .off; return true
        case #selector(toggleLinkPulseTester):
            item.state = LinkPulseTester.shared.isOn ? .on : .off; return true
        default: return true
        }
    }
}
