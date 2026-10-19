import AppKit

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
    @objc func stopLoadingPage() { selectedTab?.cancelLoad(); update() }
    @objc func savePageScreenshot() { capturePage() }
    @objc func capturePageImage() { captureWholePage(.jpeg) }
    @objc func capturePagePDF() { captureWholePage(.pdf) }
    @objc func showPageSource() { viewSource() }
    @objc func showSiteInformation() { siteInformation() }
    @objc func manageExtensions() { showExtensions() }
    @objc func showProject() { addTab(url: URL(string: "https://github.com/nocdn/Rise")!) }
    @objc func reportIssue() { addTab(url: URL(string: "https://github.com/nocdn/Rise/issues")!) }
}

/// AppKit asks as a menu opens and before invoking its shortcuts. Titles, checkmarks and
/// availability follow the current tab instead of the state when the menu bar was made.
extension BrowserController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = selectedTab
        let hasPage = tab?.url != nil
        switch item.action {
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
        case #selector(nextTab), #selector(previousTab), #selector(cleanUpTabs): return tabs.count > 1
        case #selector(duplicateCurrentTab): return hasPage
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
            return tab != nil && (tabs.count > 1 || hasPage)
        case #selector(toggleDeveloper): item.state = tab?.developer == true ? .on : .off; return tab != nil
        case #selector(toggleDevTools):
            item.title = devTools.isOpen && devTools.tabID == tab?.id ? "Hide Developer Tools" : "Show Developer Tools"
            return tab?.page is ChromiumPage
        case #selector(toggleSimulatedFullscreen): item.state = pageFullscreen.isSimulated ? .on : .off; return true
        case #selector(stopLoadingPage): return tab?.isLoading == true
        case #selector(zoomIn): return hasPage && (tab?.page.zoom ?? 1) < 3
        case #selector(zoomOut): return hasPage && (tab?.page.zoom ?? 1) > 0.3
        case #selector(actualSize): return hasPage
        case #selector(copyURL), #selector(shareCurrentPage): return hasPage && tab?.url?.absoluteString != "about:blank"
        case #selector(showPageSource): return ["http", "https", "file"].contains(tab?.url?.scheme ?? "")
        case #selector(javascriptConsole): return tab?.page is ChromiumPage
        case #selector(showSettings), #selector(manageExtensions): return ChromiumEngine.isRunning
        case #selector(showFind), #selector(findNext), #selector(findPrevious), #selector(skipToNextMatch), #selector(skipToPreviousMatch): return findTab?.url != nil
        case #selector(reload), #selector(hardReload),
             #selector(peekCurrentPage), #selector(savePageScreenshot), #selector(capturePageImage), #selector(capturePagePDF),
             #selector(showSiteInformation): return hasPage
        case #selector(toggleCardMotionTester):
            item.state = CardMotionTester.shared.isOn ? .on : .off; return true
        default: return true
        }
    }
}
