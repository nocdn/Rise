import AppKit

/// A split's pages each have their own page bar: the window's (`navBar`), with the sidebar button,
/// over the left page, and `splitBar`, with its own back, forward and reload, over the right. Each
/// shows its own page; a click on either first makes its page the selected one, so what the bar's
/// buttons do, which acts on the selected page, acts on its own.
@MainActor extension BrowserController {
    func installSplitBar() {
        let room = PlainNavBar.Metrics.navigationCentres[1]-PlainNavBar.Metrics.navigationCentres[0]
        splitBarButtons = [
            HistoryArrowButton(direction: .back, title: "Back (⌘[)", action: { [weak self] in self?.goBack() }),
            HistoryArrowButton(direction: .forward, title: "Forward (⌘])", action: { [weak self] in self?.goForward() }),
            ReloadButton(title: "Reload (⌘R)", action: { [weak self] in self?.reload() }),
        ]
        splitBar.navigation = splitBarButtons
        splitBar.navigationCentres = PlainNavBar.Metrics.navigationCentres.dropFirst().map { $0-room }
        splitBar.leadingRoom = room
        splitBar.onOpenAddress = { [weak self] in self?.focusAddress() }
        splitBar.addressMenu = { [weak self] bar in self?.addressMenu(for: bar) }
        splitBar.isHidden = true
        pageClip.addSubview(splitBar, positioned: .above, relativeTo: navBar)
    }

    /// Each bar and the page it shows: a split's two, or the selected page's alone.
    var pageBarTabs: [(bar: PlainNavBar, tab: BrowserTab)] {
        if let group = activeSplitGroup, let left = tabs.first(where: { $0.id == group.leftID }),
           let right = tabs.first(where: { $0.id == group.rightID }) {
            return [(navBar, left), (splitBar, right)]
        }
        return selectedTab.map { [(navBar, $0)] } ?? []
    }
    /// The bar over the selected page, where its popovers open from.
    var selectedBar: PlainNavBar {
        activeSplitGroup?.rightID == selectedID && !splitBar.isHidden && splitBar.superview === pageClip ? splitBar : navBar
    }
    var selectedReloadButton: ReloadButton? {
        (selectedBar === splitBar ? splitBarButtons.last : toolbarButtons[3]) as? ReloadButton
    }
    func selectedHistoryArrow(_ direction: HistoryDirection) -> HistoryArrowButton? {
        let arrows = selectedBar === splitBar ? Array(splitBarButtons.prefix(2)) : Array(toolbarButtons[1...2])
        return arrows[direction == .back ? 0 : 1] as? HistoryArrowButton
    }

    /// The bars across the page's top: one over each of a split's pages, or one across it all.
    /// An animation placing the pages places the bars too.
    func layoutPageBars(width: CGFloat) {
        guard !pageLayoutHeld || navBar.frame.width == 0 else { return }
        // A Peek's split cut short leaves its bar in the card it was coming in on.
        if splitBar.superview !== pageClip { pageClip.addSubview(splitBar, positioned: .above, relativeTo: navBar) }
        let height = PlainNavBar.Metrics.height
        if let group = activeSplitGroup, splitBar.superview === pageClip {
            let frames = splitFrames(in: NSRect(x: 0, y: 0, width: width, height: height), fraction: group.fraction)
            navBar.frame = NSRect(x: 0, y: 0, width: frames.left.width, height: height)
            splitBar.frame = NSRect(x: frames.right.minX, y: 0, width: frames.right.width, height: height)
            splitBar.isHidden = false
        } else {
            navBar.frame = NSRect(x: 0, y: 0, width: width, height: height)
            if splitBar.superview === pageClip { splitBar.isHidden = true }
        }
    }

    /// Back, forward and reload for each bar's page; with a Peek open, the window's act on the Peek.
    func updateNavigationButtons() {
        func apply(_ buttons: ArraySlice<ChromeButton>, page: WebPage?, loading: Bool) {
            let buttons = Array(buttons)
            buttons[0].isEnabled = page.map { canNavigate($0, .back) } ?? false
            buttons[1].isEnabled = page.map { canNavigate($0, .forward) } ?? false
            (buttons[2] as? ReloadButton)?.setMode(loading ? .stop : .reload)
        }
        let bars = pageBarTabs
        let left = bars.first?.tab
        apply(toolbarButtons[1...3], page: peekTab?.page ?? (bars.count == 2 ? left?.page : historyPage),
              loading: (bars.count == 2 ? left : selectedTab)?.isLoading == true)
        if bars.count == 2 { apply(splitBarButtons[0...2], page: bars[1].tab.page, loading: bars[1].tab.isLoading) }
    }

    /// A bar shows its page's address, title, zoom and load; another page's colour comes at once,
    /// as last seen, then as it is now.
    func showPageBar(_ bar: PlainNavBar, tab: BrowserTab?, shown: inout UUID?) {
        let sameTab = shown == tab?.id
        bar.show(url: tab?.url, title: tab?.title ?? "")
        bar.setReplacedCurrency(currencyReplacement.shownCode(for: tab), animated: sameTab)
        bar.pageZoom = tab?.page.zoom ?? 1
        if shown != tab?.id {
            shown = tab?.id
            bar.resetLoading(tab?.isLoading == true, progress: tab?.page.estimatedProgress ?? 0, hard: tab?.isHardReloading == true)
            bar.setColor(tab.flatMap { plainBarColors[$0.id] } ?? theme.page, animated: false)
        } else {
            bar.setLoading(tab?.isLoading == true, progress: tab?.page.estimatedProgress ?? 0, hard: tab?.isHardReloading == true)
        }
    }
}
