#if DEBUG
import UIKit

/// Exercises the real toolbar and a full local history without changing the user's records.
@MainActor enum HistoryPanelAudit {
    static let argument = "-RiseHistoryPanelAudit"
    struct Failure: Error { let name: String }
    static func makeBrowser() -> BrowserViewController {
        BrowserViewController(startURL: nil, suggestionsDirectory: URL.temporaryDirectory
            .appendingPathComponent("RiseHistoryAudit-\(UUID())"))
    }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("HistoryPanelAudit")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    private static func exercise(_ browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(550)) }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let bar = browser.bottomBar, history = bar.history, source = browser.addressSuggestions
        browser.overrideUserInterfaceStyle = .light
        browser.openHistory()
        try await settle()
        try check("empty-history-still-opens-in-the-toolbar", browser.isPanelOpen && bar.shown === history
                  && history.entries.isEmpty && history.list.backgroundView is UILabel && browser.presentedViewController == nil)
        history.closeButton.sendActions(for: .primaryActionTriggered)
        try await settle()
        try check("history-opened-from-home-closes-to-home", !browser.isPanelOpen && bar.shown === bar.home)
        browser.openHistory()
        try await settle()
        let backdropPoint = CGPoint(x: browser.view.bounds.midX, y: bar.frame.minY/2)
        let backdrop = browser.view.hitTest(backdropPoint, with: nil)
        try check("history-backdrop-is-tappable", backdrop?.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } == true)
        browser.perform(NSSelectorFromString("closePanelOnTap"))
        try await settle()
        try check("tapping-outside-history-restores-the-small-bar", !browser.isPanelOpen && bar.shown === bar.home)
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 16, height: 16)).fill()
        }
        let first = URL(string: "https://history.invalid/articles/0?source=full")!
        source.icons.remember(icon, for: first)
        let titles = ["Designing a browser for everyday use", "A closer look at the new iPhone", "The quiet craft of making software",
                      "Notes from a weekend in London", "A guide to better typography", "Building interfaces that feel natural"]
        for index in 0..<BrowsingHistory.maximumEntries {
            source.history.record(URL(string: "https://history.invalid/articles/\(index)?source=full")!,
                title: index < titles.count ? titles[index] : "Saved article \(index)",
                at: Date(timeIntervalSince1970: 2_000_000_000-Double(index)))
        }
        browser.showTabSwitcher()
        try await settle()
        browser.openPanel(.menu)
        try await settle()
        let began = CACurrentMediaTime()
        bar.tabMenu.historyButton.sendActions(for: .primaryActionTriggered)
        let actionMS = (CACurrentMediaTime()-began)*1000
        CATransaction.flush()
        let commitMS = (CACurrentMediaTime()-began)*1000
        try JSONSerialization.data(withJSONObject: ["actionMS": actionMS, "commitMS": commitMS, "entries": history.entries.count],
            options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("opening.json"))
        try check("history-opens-on-the-original-button-action", browser.isPanelOpen && bar.panel == .history
                  && bar.shown === history && browser.quickActions.pending == nil && browser.presentedViewController == nil)
        try check("history-has-no-one-second-presentation-delay", commitMS < 200)
        try await settle()
        try check("history-fills-eighty-percent-of-the-screen", abs(bar.bounds.height-browser.view.bounds.height*0.8) < 1)
        try check("all-history-is-available-newest-first", history.entries.count == 2000 && history.entries.first?.url == first.absoluteString
                  && history.entries.last?.title == "Saved article 1999")
        try check("long-histories-create-only-visible-rows", history.list.visibleCells.count > 5 && history.list.visibleCells.count < 32)
        let cell = history.list.cellForItem(at: IndexPath(item: 0, section: 0)) as! HistoryCell
        cell.row.layoutIfNeeded()
        let reference = AddressSuggestionRow(frame: cell.row.bounds)
        reference.show(AddressCandidate(title: titles[0], url: first), image: icon)
        reference.layoutIfNeeded()
        try check("history-matches-suggestion-type-and-row-spacing", history.list.rowHeight == SearchPanel.rowHeight
                  && cell.row.titleLabelView.font == reference.titleLabelView.font && cell.row.bounds.height == SearchPanel.rowHeight)
        try check("history-keeps-extra-padding-and-suggestion-favicon-composition", history.list.frame.minX == HistoryPanel.extraHorizontalInset
                  && history.header.frame.minX == HistoryPanel.extraHorizontalInset && cell.row.frame.minX == SearchPanel.inset
                  && cell.row.icon.frame == reference.icon.frame && cell.row.icon.layer.cornerRadius == reference.icon.layer.cornerRadius
                  && cell.row.titleLabelView.frame.minX == reference.titleLabelView.frame.minX)
        try check("history-hides-url-subtitles-and-unusable-fill-controls", history.list.visibleCells.allSatisfy {
            guard let row = ($0 as? HistoryCell)?.row else { return false }
            return row.addressLabel.isHidden && row.addressLabel.text == nil && row.fillButton.isHidden
                && row.accessibilityCustomActions?.map(\.name) == ["Delete from history"]
        })
        try check("history-has-no-search-field", !history.subviews.contains { $0 is UITextField || $0 is UISearchBar }
                  && !bar.search.field.isFirstResponder)
        cell.row.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(120))
        try check("history-retains-suggestion-press-feedback", abs(cell.row.transform.a-SearchPanel.pressedScale) < 0.001
                  && cell.row.pressBackground.backgroundColor == SearchPanel.pressedFill)
        cell.row.sendActions(for: .touchCancel)
        try await Task.sleep(for: .milliseconds(220))
        try capture("history-light")
        let height = bar.bounds.height
        history.list.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        history.list.layoutIfNeeded()
        try check("history-scrolls-without-resizing-the-panel", history.list.indexPathsForVisibleItems.map(\.item).min()! > 10 && bar.bounds.height == height)
        try check("scrolling-within-history-does-not-move-the-panel", !history.list.canRubberBandPanel(velocity: CGPoint(x: 0, y: 300)))
        history.list.setContentOffset(.zero, animated: false)
        try check("a-downward-pull-at-the-top-rubber-bands-the-panel", history.list.canRubberBandPanel(velocity: CGPoint(x: 0, y: 300))
                  && !history.list.canRubberBandPanel(velocity: CGPoint(x: 0, y: -300))
                  && !history.list.canRubberBandPanel(velocity: CGPoint(x: 400, y: 100)))
        browser.dragPanel(to: 60)
        try check("history-resists-a-downward-drag", bar.bounds.height < height && bar.bounds.height > height-20 && browser.panelMotion.isHoldingRate)
        browser.finishPanelDrag(at: 60, velocity: 0)
        try await settle()
        try check("short-history-pulls-return-to-full-height", bar.panel == .history && abs(bar.bounds.height-height) < 1)
        browser.dragPanel(to: 1200)
        try check("even-a-long-history-pull-stays-bounded", bar.bounds.height > height-40)
        browser.finishPanelDrag(at: 1200, velocity: 3000)
        try await settle()
        try check("a-strong-downward-flick-keeps-history-open", browser.isPanelOpen && bar.panel == .history && abs(bar.bounds.height-height) < 1)
        browser.dragPanel(to: -1200)
        try check("history-also-resists-upward-drags", bar.bounds.height > height && bar.bounds.height < height+40)
        browser.finishPanelDrag(at: -1200, velocity: -3000)
        try await settle()
        try check("upward-flicks-return-to-the-same-history-height", bar.panel == .history && abs(bar.bounds.height-height) < 1)
        browser.handlePanelEdgeSwipe(.possible)
        browser.handlePanelEdgeSwipe(.cancelled)
        try check("an-edge-touch-must-be-recognized-as-a-swipe", bar.panel == .history)
        browser.handlePanelEdgeSwipe(.began)
        try check("the-edge-swipe-closes-on-began-without-waiting-for-release", bar.panel == .tabMenu && bar.shown === bar.tabMenu)
        try await settle()
        try check("a-left-edge-swipe-restores-the-previous-menu", browser.isPanelOpen && bar.panel == .tabMenu && bar.shown === bar.tabMenu)
        for _ in 0..<6 { browser.openHistory(); history.closeButton.sendActions(for: .primaryActionTriggered) }
        try await settle()
        try check("rapid-history-swaps-leave-no-old-surfaces", bar.shown === bar.tabMenu && history.alpha == 0 && bar.home.alpha == 0
                  && !history.isUserInteractionEnabled && bar.tabMenu.isUserInteractionEnabled)
        browser.overrideUserInterfaceStyle = .dark
        browser.openHistory()
        try await settle()
        try capture("history-dark")
        try check("history-also-works-in-dark-mode", bar.panel == .history && bar.backgroundColor?.resolvedColor(with: bar.traitCollection)
                  == BottomBar.background.resolvedColor(with: bar.traitCollection))
        _ = browser.accessibilityPerformEscape()
        try await settle()
        try check("accessibility-escape-restores-the-previous-menu", browser.isPanelOpen && bar.panel == .tabMenu)
        browser.openHistory()
        try await settle()
        browser.perform(NSSelectorFromString("closePanelOnTap"))
        try check("tapping-outside-history-uses-the-same-return-route-as-x", browser.isPanelOpen && bar.panel == .tabMenu && bar.shown === bar.tabMenu)
        try await settle()
        browser.openHistory()
        try await settle()
        let tabs = browser.tabs.count
        (history.list.cellForItem(at: IndexPath(item: 0, section: 0)) as! HistoryCell).row.sendActions(for: .primaryActionTriggered)
        try await settle()
        try check("choosing-a-visit-opens-its-full-url-in-a-new-tab", browser.tabs.count == tabs+1 && browser.tabs[browser.tabIndex].sessionTab.url == first)
        try check("choosing-a-visit-closes-history-and-the-deck", !browser.isPanelOpen && !browser.isTabSwitcherOpen && bar.shown === bar.home)
        browser.webView.stopLoading()
        browser.quickActions.open(.history)
        try await settle()
        try check("home-screen-history-uses-the-same-panel", bar.panel == .history && browser.presentedViewController == nil && browser.quickActions.pending == nil)
        history.closeButton.sendActions(for: .primaryActionTriggered)
        try await settle()
        try check("home-screen-history-x-restores-the-small-bar", !browser.isPanelOpen && bar.shown === bar.home)
        browser.openPanel(.menu)
        try await settle()
        browser.handlePanelEdgeSwipe(.began)
        try check("edge-back-does-not-dismiss-the-root-menu", !browser.canReturnFromPanel && bar.panel == .menu)
        browser.openSiteSettings()
        try await settle()
        browser.handlePanelEdgeSwipe(.changed)
        browser.handlePanelEdgeSwipe(.ended)
        try check("settings-edge-back-waits-for-recognition-not-release", bar.panel == .siteSettings)
        browser.handlePanelEdgeSwipe(.began)
        try check("site-settings-edge-back-returns-immediately-to-more", bar.panel == .menu && bar.shown === bar.menu && browser.isPanelOpen)
        try await settle()
        browser.openSiteSettings()
        try await settle()
        browser.openAppSettings()
        try await settle()
        browser.handlePanelEdgeSwipe(.began)
        try check("app-settings-edge-back-returns-one-level", bar.panel == .siteSettings && bar.shown === bar.siteSettings && browser.isPanelOpen)
        try await settle()
        bar.siteSettings.closeButton.sendActions(for: .primaryActionTriggered)
        try await settle()
        try check("settings-x-uses-the-same-return-route", bar.panel == .menu)
        browser.openDownloads()
        try await settle()
        browser.handlePanelEdgeSwipe(.began)
        try check("downloads-edge-back-returns-immediately-to-more", bar.panel == .menu && bar.shown === bar.menu && browser.isPanelOpen)
        try await settle()
        browser.openDownloads()
        try await settle()
        browser.dragPanel(to: -450)
        browser.finishPanelDrag(at: -450, velocity: -1400)
        try await settle()
        browser.handlePanelEdgeSwipe(.began)
        try check("edge-back-also-returns-from-expanded-downloads", bar.panel == .menu && bar.shown === bar.menu && browser.isPanelOpen)
        try await settle()
        browser.openDownloads()
        try await settle()
        bar.downloads.closeButton.sendActions(for: .primaryActionTriggered)
        try await settle()
        try check("downloads-x-uses-the-same-return-route", bar.panel == .menu)
        browser.closePanel()
        try await settle()
        browser.overrideUserInterfaceStyle = .light
        browser.openHistory()
        try await settle()
    }
}
#endif
