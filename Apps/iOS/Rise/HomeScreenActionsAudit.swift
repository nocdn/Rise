#if DEBUG
import UIKit
import WebKit

/// Exercises the production shortcut router, with no real visits, sync or phone interaction.
@MainActor enum HomeScreenActionsAudit {
    static let argument = "-RiseHomeScreenActionsAudit"
    struct Failure: Error { let name: String }
    static func makeBrowser() -> BrowserViewController {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseQuickActions-\(UUID())")
        let browser = BrowserViewController(startURL: nil, opensSearchOnFirstAppearance: true,
            sessionStore: MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("Session.json")))
        // Exactly the cold-launch ordering: route before the root view appears.
        browser.quickActions.open(.downloads)
        return browser
    }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("HomeScreenActionsAudit")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    static func exercise(_ browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func wait(_ name: String, _ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<350 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(name: "Timed out: "+name)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(650)) }
        func history() -> BrowsingHistoryController? {
            (browser.presentedViewController as? UINavigationController)?.topViewController as? BrowsingHistoryController
        }
        func capture(_ name: String, _ view: UIView) throws {
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let items = Bundle.main.object(forInfoDictionaryKey: "UIApplicationShortcutItems") as? [[String: String]] ?? []
        try check("three-home-screen-items", items.count == 3)
        try check("exact-requested-titles", items.compactMap { $0["UIApplicationShortcutItemTitle"] } == ["Downloads", "History", "New Private Tab"])
        try check("every-item-has-a-valid-system-icon", items.allSatisfy { UIImage(systemName: $0["UIApplicationShortcutItemIconSymbolName"] ?? "") != nil })
        try check("every-item-routes-to-a-known-action", items.allSatisfy { HomeScreenAction(rawValue: $0["UIApplicationShortcutItemType"] ?? "") != nil })
        try check("unknown-shortcut-is-rejected", HomeScreenAction(shortcut: UIApplicationShortcutItem(type: "unknown", localizedTitle: "Unknown")) == nil)
        try await wait("cold downloads") { browser.isPanelOpen && browser.bottomBar.panel == .downloads }
        try await settle()
        try check("cold-downloads-bypasses-launch-search", !browser.bottomBar.search.field.isFirstResponder && browser.quickActions.pending == nil)
        try capture("downloads", browser.view)
        let first = URL(string: "https://history-one.invalid/path?q=full")!
        let second = URL(string: "https://history-two.invalid/")!
        browser.addressSuggestions.history.record(first, title: "Older article", at: Date(timeIntervalSinceNow: -600))
        browser.addressSuggestions.history.record(second, title: "Recent article")
        let scene = browser.view.window!.windowScene!
        let delegate = scene.delegate as! SceneDelegate
        var handled = false
        delegate.windowScene(scene, performActionFor: UIApplicationShortcutItem(type: HomeScreenAction.history.rawValue, localizedTitle: "History")) { handled = $0 }
        try check("warm-scene-callback-handles-history", handled)
        try await wait("history from downloads") { history() != nil }
        try await settle()
        let list = history()!
        try check("history-is-newest-first", list.entries.map(\.url) == [second.absoluteString, first.absoluteString])
        list.reload(query: "OLDER")
        try check("history-filters-title-case-insensitively", list.entries.map(\.url) == [first.absoluteString])
        list.reload(query: "history-two")
        try check("history-filters-addresses", list.entries.map(\.url) == [second.absoluteString])
        list.reload(query: "no matches")
        try check("history-shows-an-empty-search-state", list.entries.isEmpty && list.tableView.backgroundView is UILabel)
        list.reload(query: "")
        try capture("history", list.navigationController!.view)
        list.tableView(list.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        try await wait("history selection") { browser.tabs.count == 2 }
        try check("history-selection-opens-the-full-address", browser.tabs[browser.tabIndex].sessionTab.url == first)
        browser.webView.stopLoading()
        browser.openPanel()
        try await settle()
        browser.quickActions.open(.newPrivateTab)
        try await wait("new private tab") { browser.quickActions.privateSession?.presentingViewController != nil }
        try await settle()
        let session = browser.quickActions.privateSession!, privateBrowser = session.browser
        try check("private-shortcut-starts-an-empty-search", privateBrowser.isPanelOpen && privateBrowser.bottomBar.search.field.text?.isEmpty == true)
        try check("private-mode-is-clearly-labelled", privateBrowser.title == "Private Browsing" && privateBrowser.navigationItem.rightBarButtonItem?.accessibilityLabel == "Close private tabs")
        try check("private-webkit-store-is-not-persistent", !privateBrowser.websiteDataStore.isPersistent && !privateBrowser.webView.configuration.websiteDataStore.isPersistent)
        try check("private-tabs-have-no-sync-or-disk-previews", privateBrowser.tabSync == nil && privateBrowser.tabPreviews == nil)
        try check("private-search-does-not-record-or-send-typing", !privateBrowser.addressSuggestions.recordsBrowsing && !privateBrowser.bottomBar.search.allowsRemoteSuggestions)
        try capture("private", session.view)
        let cookieName = "rise_private_audit_"+UUID().uuidString.replacingOccurrences(of: "-", with: "")
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: "private-audit.invalid", .path: "/", .name: cookieName, .value: value, .secure: "TRUE"])!
        }
        await browser.websiteDataStore.httpCookieStore.setCookie(cookie("regular"))
        try check("private-cookies-start-separate-from-regular", !(await privateBrowser.websiteDataStore.httpCookieStore.allCookies()).contains { $0.name == cookieName })
        await privateBrowser.websiteDataStore.httpCookieStore.setCookie(cookie("private"))
        try check("private-cookie-does-not-change-regular-cookie", (await browser.websiteDataStore.httpCookieStore.allCookies()).first { $0.name == cookieName }?.value == "regular")
        privateBrowser.closePanel()
        try await settle()
        let privateURL = URL(string: "https://private-audit.invalid/")!
        privateBrowser.webView.loadHTMLString("<title>Private audit</title><body>Private page</body>", baseURL: privateURL)
        try await wait("private html") { privateBrowser.webView.title == "Private audit" && !privateBrowser.webView.isLoading }
        privateBrowser.addressSuggestions.committed(privateBrowser.webView)
        privateBrowser.addressSuggestions.changed(privateBrowser.webView)
        privateBrowser.saveSession(flush: true)
        try check("private-navigation-does-not-enter-history", privateBrowser.addressSuggestions.history.entries.isEmpty)
        try check("private-navigation-does-not-learn-site-searches", privateBrowser.addressSuggestions.learner.searches.searches.isEmpty)
        try check("private-navigation-does-not-create-suggestion-files", !FileManager.default.fileExists(atPath: privateBrowser.addressSuggestions.history.storageURL.deletingLastPathComponent().path))
        try check("private-favicons-bypass-the-shared-fetch-cache", await BrowserTab.favicon(for: privateBrowser.webView) == nil)
        privateBrowser.adBlocker.setEnabled(false, for: privateURL)
        privateBrowser.adBlocker.cookieBanners.setEnabled(false, for: privateURL)
        try check("private-protection-settings-work-in-memory", !privateBrowser.adBlocker.isEnabled(for: privateURL) && !privateBrowser.adBlocker.cookieBanners.isEnabled(for: privateURL))
        try check("private-protection-settings-do-not-change-regular", browser.adBlocker.isEnabled(for: privateURL) && browser.adBlocker.cookieBanners.isEnabled(for: privateURL))
        let count = browser.tabs.count
        browser.quickActions.open(.newPrivateTab)
        try await wait("second private tab") { privateBrowser.tabs.count == 2 && privateBrowser.isPanelOpen }
        try await settle()
        try check("repeated-shortcut-adds-a-new-private-tab", browser.quickActions.privateSession === session && privateBrowser.tabs.count == 2 && privateBrowser.webView.url == nil)
        let privateCookies = await privateBrowser.websiteDataStore.httpCookieStore.allCookies()
        try check("private-tabs-share-only-their-ephemeral-store", privateBrowser.tabs.allSatisfy { $0.webView.configuration.websiteDataStore === privateBrowser.websiteDataStore }
            && privateCookies.first { $0.name == cookieName }?.value == "private")
        privateBrowser.closePanel()
        try await settle()
        privateBrowser.showPeek(privateURL)
        try await wait("private peek") { privateBrowser.presentedViewController is PeekViewController }
        let peek = privateBrowser.presentedViewController as! PeekViewController
        try check("private-peek-keeps-the-same-isolated-store", peek.browser.isPrivateBrowsing && peek.browser.websiteDataStore === privateBrowser.websiteDataStore && !peek.browser.addressSuggestions.recordsBrowsing)
        privateBrowser.dismiss(animated: false)
        try await settle()
        privateBrowser.openPanel(.menu); privateBrowser.openSiteSettings(); privateBrowser.openAppSettings()
        try await settle()
        try check("private-settings-cannot-enable-tab-sync", !privateBrowser.bottomBar.appSettings.syncRow.toggle.isOn && !privateBrowser.bottomBar.appSettings.syncRow.toggle.isEnabled)
        let window = delegate.window!
        let before = window.subviews.count
        browser.quickActions.setActive(false, in: window)
        try check("private-view-is-covered-in-app-switcher-snapshot", window.subviews.count == before+1 && window.subviews.last?.backgroundColor == .black)
        browser.quickActions.setActive(true, in: window)
        try check("private-snapshot-cover-clears-on-return", window.subviews.count == before)
        session.onClose?()
        try await wait("close private") { browser.quickActions.privateSession == nil && browser.presentedViewController == nil }
        try check("closing-private-keeps-regular-tabs-unchanged", browser.tabs.count == count && browser.tabs[browser.tabIndex].sessionTab.url == first)
        browser.quickActions.open(.newPrivateTab)
        try await wait("fresh private session") { browser.quickActions.privateSession?.presentingViewController != nil }
        try await settle()
        let fresh = browser.quickActions.privateSession!
        let freshCookies = await fresh.browser.websiteDataStore.httpCookieStore.allCookies()
        try check("closing-private-starts-a-fresh-cookie-session", fresh !== session && !freshCookies.contains { $0.name == cookieName })
        try check("closing-private-resets-in-memory-site-preferences", fresh.browser.adBlocker.isEnabled(for: privateURL) && fresh.browser.adBlocker.cookieBanners.isEnabled(for: privateURL))
        fresh.onClose?()
        try await wait("return to regular") { browser.presentedViewController == nil && browser.quickActions.privateSession == nil }
        browser.showTabSwitcher()
        try await settle()
        browser.openPanel(.menu)
        try await settle()
        browser.bottomBar.tabMenu.historyButton.sendActions(for: .primaryActionTriggered)
        try await wait("history from tab deck") { history() != nil }
        try check("existing-history-button-opens-the-same-list", !browser.isPanelOpen && browser.isTabSwitcherOpen)
        browser.quickActions.open(.downloads)
        try await wait("downloads from presented history") { browser.presentedViewController == nil && browser.isPanelOpen && browser.bottomBar.panel == .downloads }
        try await settle()
        try check("warm-downloads-opens-after-dismissing-history", browser.quickActions.pending == nil)
        handled = true
        delegate.windowScene(scene, performActionFor: UIApplicationShortcutItem(type: "unknown", localizedTitle: "Unknown")) { handled = $0 }
        try check("scene-rejects-unrecognized-shortcuts", !handled)
        await browser.websiteDataStore.httpCookieStore.deleteCookie(cookie("regular"))
        // Even accidental persistence arguments cannot make private tabs durable.
        let guardFolder = folder.appendingPathComponent("private-guard")
        let guarded = BrowserViewController(startURL: nil,
            sessionStore: MobileBrowserSessionStore(fileURL: guardFolder.appendingPathComponent("session.json")),
            previewCacheURL: guardFolder.appendingPathComponent("previews"), suggestionsDirectory: guardFolder,
            isPrivateBrowsing: true, websiteDataStore: .default())
        guarded.saveSession(flush: true)
        try check("private-mode-rejects-a-persistent-webkit-store", !guarded.websiteDataStore.isPersistent)
        try check("private-mode-ignores-disk-restoration-and-cache-paths", !FileManager.default.fileExists(atPath: guardFolder.path) && guarded.tabPreviews == nil)
    }
}
#endif
