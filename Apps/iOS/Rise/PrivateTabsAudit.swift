#if DEBUG
import UIKit
import WebKit

/// Exercise the actual panel, mixed deck, WebKit stores and durable adapters in an isolated session.
@MainActor enum PrivateTabsAudit {
    static let argument = "-RisePrivateTabsAudit"
    struct Failure: Error { let name: String }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PrivateTabsAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: host.view.window!, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    static func exercise(in window: UIWindow, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
            if !value { throw Failure(name: name) }
        }
        func wait(_ name: String, _ ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try check(name, ready())
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(650)) }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let suite = "RisePrivateTabs-\(UUID())", regularStore = WKWebsiteDataStore.nonPersistent()
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let normalURL = fixture.url.appendingPathComponent("preview/blue-0")
        let privateURL = fixture.url.appendingPathComponent("preview/blue-1")
        let normal = MobileBrowserSession.Tab(url: normalURL, title: "Regular page")
        store.save(.init(tabs: [normal], selectedTabID: normal.id)); store.flush()
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        let browser = BrowserViewController(sessionStore: store, tabSync: sync, previewCacheURL: folder.appendingPathComponent("previews"),
                                            websiteDataStore: regularStore)
        browser.overrideUserInterfaceStyle = .light
        window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
        try await wait("regular-page-loads") { browser.webView.url == normalURL && !browser.webView.isLoading }
        let normalPage = browser.webView
        _ = try await normalPage.evaluateJavaScript("localStorage.setItem('rise-private-audit', 'regular')")
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "rise_mode", .value: "regular"])!
        await regularStore.httpCookieStore.setCookie(cookie)
        let amazon = URL(string: "https://www.amazon.co.uk/")!
        browser.addressSuggestions.history.record(amazon, title: "Amazon")
        browser.openPanel()
        try await settle()
        let panel = browser.bottomBar.search, bar = browser.bottomBar
        panel.field.text = "amazo"; panel.field.sendActions(for: .editingChanged)
        try check("normal-learned-suggestion-is-visible", panel.candidates.contains { $0.url?.host == amazon.host })
        let text = panel.field.text, completion = panel.field.inlineCompletion
        let frame = bar.frame
        try capture("regular-light")
        panel.privateButton.sendActions(for: .primaryActionTriggered)
        try check("eye-swap-starts-above-the-sweep-immediately", panel.privateButton.symbolName == "private-eye" && panel.privateButton.superview === bar)
        try await Task.sleep(for: .milliseconds(55))
        let first = bar.privateSweepY
        try capture("purple-rising-early")
        try await Task.sleep(for: .milliseconds(70))
        let second = bar.privateSweepY
        try capture("purple-rising-late")
        try check("purple-sweep-rises-from-the-bottom", first != nil && second != nil && second! < first!)
        try await Task.sleep(for: .milliseconds(185))
        try check("sweep-finishes-without-a-panel-bounce", bar.layer.animation(forKey: "private-rubber-band") == nil)
        if let shown = bar.layer.presentation() {
            let transform = shown.transform
            try check("sweep-keeps-the-panel-still", abs(transform.m22-1) < 0.001 && abs(transform.m42) < 0.1)
        }
        try await settle()
        try check("private-panel-has-the-requested-purple", bar.isPrivateBrowsing && bar.backgroundColor == PrivatePanelAppearance.background)
        try check("private-mode-keeps-the-draft-and-completion", panel.field.text == text && panel.field.inlineCompletion == completion)
        try check("private-mode-still-reads-learned-suggestions", panel.candidates.contains { $0.url?.host == amazon.host })
        try check("toggle-shows-the-normal-eye", panel.privateButton.symbolName == "private-eye")
        try check("toggle-is-left-of-x-with-a-separate-hit-target", panel.privateButton.frame.maxX <= panel.clearButton.frame.minX+1)
        try check("colour-transition-does-not-change-panel-geometry", bar.frame == frame)
        try capture("private-light")
        panel.privateButton.sendActions(for: .primaryActionTriggered)
        try check("eye-off-swap-also-starts-immediately", panel.privateButton.symbolName == "private-eye-off" && panel.privateButton.superview === bar)
        try await Task.sleep(for: .milliseconds(55))
        try capture("regular-returning-arc")
        try await settle()
        try check("eye-returns-to-the-search-panel-after-the-sweep", panel.privateButton.superview === panel)
        try check("toggle-restores-regular-light-appearance", !bar.isPrivateBrowsing && bar.overrideUserInterfaceStyle == .unspecified)
        browser.overrideUserInterfaceStyle = .dark
        browser.view.layoutIfNeeded()
        try capture("regular-dark")
        panel.setPrivateBrowsing(true); try await settle()
        try check("private-purple-is-identical-in-dark-mode", bar.backgroundColor == PrivatePanelAppearance.background && bar.overrideUserInterfaceStyle == .dark)
        try capture("private-dark")
        for enabled in [false, true, false, true] { panel.setPrivateBrowsing(enabled); try await Task.sleep(for: .milliseconds(35)) }
        try await settle()
        try check("rapid-toggle-reversal-settles-on-the-latest-mode", panel.isPrivateBrowsing && bar.isPrivateBrowsing && bar.privateSweepY == nil)
        browser.openFromPanel(privateURL)
        try await wait("private-page-loads-in-the-main-tab-list") { browser.tabs.count == 2 && browser.isPrivateBrowsing && browser.webView.url == privateURL && !browser.webView.isLoading }
        let privateTab = browser.tabs[browser.tabIndex], privatePage = browser.webView, privateStore = browser.websiteDataStore
        try check("private-tabs-use-a-separate-nonpersistent-webkit-store", privateStore !== regularStore && !privateStore.isPersistent)
        let privateCookies = await privateStore.httpCookieStore.allCookies()
        try check("regular-cookies-are-not-visible-in-private-tabs", !privateCookies.contains { $0.name == "rise_mode" })
        let privateStorage = try await privatePage.evaluateJavaScript("localStorage.getItem('rise-private-audit')")
        try check("regular-local-storage-is-not-visible-in-private-tabs", privateStorage is NSNull)
        await privateStore.httpCookieStore.setCookie(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "rise_mode", .value: "private"])!)
        _ = try await privatePage.evaluateJavaScript("localStorage.setItem('rise-private-audit', 'private')")
        let regularCookies = await regularStore.httpCookieStore.allCookies()
        try check("private-cookies-cannot-change-regular-cookies", regularCookies.first { $0.name == "rise_mode" }?.value == "regular")
        let regularStorage = try await normalPage.evaluateJavaScript("localStorage.getItem('rise-private-audit')") as? String
        try check("private-storage-cannot-change-regular-storage", regularStorage == "regular")
        browser.addressSuggestions.committed(privatePage); browser.addressSuggestions.changed(privatePage)
        browser.saveSession(flush: true)
        try check("private-visits-never-enter-normal-history", !browser.addressSuggestions.history.entries.contains { $0.url == privateURL.absoluteString })
        try check("private-tabs-never-enter-the-shared-list", !sync.tabs.contains { $0.id == privateTab.id })
        let saved = try String(contentsOf: store.fileURL)
        try check("private-tabs-never-enter-the-durable-session", !saved.contains(privateTab.id.uuidString) && !saved.contains(privateURL.absoluteString))
        privateTab.snapshot = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40)).image { c in UIColor.purple.setFill(); c.fill(CGRect(x: 0, y: 0, width: 30, height: 40)) }
        browser.tabPreviews?.save(privateTab); browser.tabPreviews?.cache.flush()
        let cached = await browser.tabPreviews?.cache.load(id: privateTab.id, url: privateURL)
        try check("private-previews-are-never-saved-to-disk", cached == nil)
        let remote = SharedBrowserTab(id: UUID(), url: nil, title: "From desktop")
        let incoming = sync.tabs+[remote]
        sync.capture(incoming); sync.onTabsChange?(incoming)
        try check("sync-retains-private-tabs-locally", browser.tabs.contains { $0 === privateTab } && browser.isPrivateBrowsing)
        try check("remote-tabs-never-inherit-private-storage", browser.tabs.first { $0.id == remote.id }?.webView.configuration.websiteDataStore === regularStore)
        browser.showTabSwitcher(); try await settle()
        try check("private-card-is-in-the-normal-tab-deck", browser.tabSwitcher.cells.count == browser.tabs.count)
        try capture("mixed-tab-deck")
        browser.selectTab(browser.tabs.firstIndex { $0.id == normal.id }!); try await settle()
        let lateURL = fixture.url.appendingPathComponent("preview/blue-2")
        privatePage.load(URLRequest(url: lateURL))
        try await wait("background-private-page-finishes") { privatePage.url == lateURL && !privatePage.isLoading }
        try check("background-private-callbacks-cannot-write-regular-history", !browser.addressSuggestions.history.entries.contains { $0.url == lateURL.absoluteString })
        browser.showTabSwitcher(); try await settle()
        let index = browser.tabs.firstIndex { $0.id == privateTab.id }!, cell = browser.tabSwitcher.cells[index]
        cell.beginCloseDrag(); cell.updateCloseDrag(-cell.bounds.height*0.3)
        cell.endCloseDrag(-cell.bounds.height*0.3, velocity: -1000, cancelled: false)
        try await wait("swiping-private-card-really-closes-it") { !browser.tabs.contains { $0.id == privateTab.id } }
        try await settle()
        try check("shake-cannot-restore-a-closed-private-tab", !browser.reopenClosedTab())
        browser.selectTab(browser.tabIndex); try await settle()
        browser.openPrivateSearch(); try await settle()
        browser.openFromPanel(privateURL)
        try await wait("a-later-private-session-opens") { browser.isPrivateBrowsing && !browser.webView.isLoading }
        let fresh = browser.websiteDataStore
        let freshCookies = await fresh.httpCookieStore.allCookies()
        try check("last-private-close-discards-its-cookie-session", fresh !== privateStore && !freshCookies.contains { $0.name == "rise_mode" })
        let freshPrivateID = browser.tabs[browser.tabIndex].id
        browser.showTabSwitcher(); try await settle()
        while let index = browser.tabs.firstIndex(where: { !$0.isPrivateBrowsing }) {
            browser.tabSwitcher.cells[index].onClose()
            try await Task.sleep(for: .milliseconds(320))
        }
        try check("the-last-private-tab-can-still-be-swiped-away", browser.tabs.count == 1 && browser.tabSwitcher.cells[0].canClose)
        let last = browser.tabSwitcher.cells[0]
        last.beginCloseDrag(); last.updateCloseDrag(-last.bounds.height*0.3)
        last.endCloseDrag(-last.bounds.height*0.3, velocity: -1000, cancelled: false)
        try await wait("closing-the-final-private-tab-returns-to-normal-new-page") { browser.tabs.count == 1 && !browser.isPrivateBrowsing && browser.isPanelOpen }
        try check("the-final-private-tab-is-not-resurrected", !browser.tabs.contains { $0.id == freshPrivateID })
        browser.closePanel(); try await settle()
        browser.quickActions.open(.newPrivateTab)
        try await wait("home-screen-shortcut-opens-the-same-private-panel") { browser.isPanelOpen && panel.isPrivateBrowsing && browser.presentedViewController == nil }
        try check("warm-shortcut-opens-already-purple-without-a-sweep", bar.backgroundColor == PrivatePanelAppearance.background && bar.privateSweepY == nil)
        try capture("shortcut-private-panel")
        panel.setPrivateBrowsing(false); try await settle()
        panel.setPrivateBrowsing(true)
        try await Task.sleep(for: .milliseconds(55))
        browser.quickActions.open(.newPrivateTab)
        try check("shortcut-finishes-an-in-flight-purple-transition", bar.backgroundColor == PrivatePanelAppearance.background && bar.privateSweepY == nil && bar.layer.animation(forKey: "private-rubber-band") == nil)
        browser.saveSession(flush: true)
        let cold = BrowserViewController(startURL: nil, opensSearchOnFirstAppearance: true)
        cold.quickActions.open(.newPrivateTab)
        window.rootViewController = cold; window.makeKeyAndVisible(); cold.view.layoutIfNeeded()
        try await wait("cold-private-shortcut-opens-the-new-page-panel") { cold.isPanelOpen && cold.bottomBar.search.isPrivateBrowsing }
        try check("cold-shortcut-opens-already-purple-without-a-sweep", cold.bottomBar.backgroundColor == PrivatePanelAppearance.background && cold.bottomBar.privateSweepY == nil && cold.presentedViewController == nil)
        try capture("shortcut-private-cold")
    }
}
#endif
