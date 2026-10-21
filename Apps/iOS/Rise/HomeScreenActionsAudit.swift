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
        func history() -> HistoryPanel? {
            browser.isPanelOpen && browser.bottomBar.panel == .history ? browser.bottomBar.history : nil
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
        try check("history-uses-the-toolbar-instead-of-a-modal", browser.presentedViewController == nil && browser.bottomBar.shown === list)
        try capture("history", browser.view)
        (list.list.cellForItem(at: IndexPath(item: 1, section: 0)) as! HistoryCell).row.sendActions(for: .primaryActionTriggered)
        try await wait("history selection") { browser.tabs.count == 2 }
        try check("history-selection-opens-the-full-address", browser.tabs[browser.tabIndex].sessionTab.url == first)
        browser.webView.stopLoading()
        browser.openPanel()
        try await settle()
        browser.quickActions.open(.newPrivateTab)
        try await wait("private new-page panel") { browser.isPanelOpen && browser.bottomBar.panel == .search && browser.bottomBar.search.isPrivateBrowsing }
        try check("already-open-search-becomes-purple-without-a-sweep", browser.bottomBar.backgroundColor == PrivatePanelAppearance.background && browser.bottomBar.privateSweepY == nil)
        try check("shortcut-does-not-trigger-the-toggle-bounce", browser.bottomBar.layer.animation(forKey: "private-rubber-band") == nil)
        try await settle()
        try check("private-shortcut-uses-the-existing-panel", browser.presentedViewController == nil && browser.bottomBar.shown === browser.bottomBar.search)
        try check("private-shortcut-starts-an-empty-search", browser.bottomBar.search.field.text?.isEmpty == true)
        try check("private-shortcut-shows-the-purple-appearance", browser.bottomBar.isPrivateBrowsing && browser.bottomBar.overrideUserInterfaceStyle == .dark)
        try capture("private-search", browser.view)
        let window = delegate.window!, before = window.subviews.count
        browser.quickActions.setActive(false, in: window)
        try check("private-panel-is-covered-in-app-switcher-snapshot", window.subviews.count == before+1)
        browser.quickActions.setActive(true, in: window)
        try check("private-snapshot-cover-clears-on-return", window.subviews.count == before)
        browser.closePanel()
        try await settle()
        try check("cancelling-private-search-keeps-the-regular-page", !browser.isPrivateBrowsing && !browser.bottomBar.isPrivateBrowsing && browser.tabs[browser.tabIndex].sessionTab.url == first)
        browser.showTabSwitcher()
        try await settle()
        browser.openPanel(.menu)
        try await settle()
        browser.bottomBar.tabMenu.historyButton.sendActions(for: .primaryActionTriggered)
        try await wait("history from tab deck") { history() != nil }
        try check("existing-history-button-opens-the-same-list", browser.isPanelOpen && browser.isTabSwitcherOpen && browser.bottomBar.shown === browser.bottomBar.history)
        browser.quickActions.open(.downloads)
        try await wait("downloads from presented history") { browser.presentedViewController == nil && browser.isPanelOpen && browser.bottomBar.panel == .downloads }
        try await settle()
        try check("warm-downloads-opens-after-dismissing-history", browser.quickActions.pending == nil)
        handled = true
        delegate.windowScene(scene, performActionFor: UIApplicationShortcutItem(type: "unknown", localizedTitle: "Unknown")) { handled = $0 }
        try check("scene-rejects-unrecognized-shortcuts", !handled)
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
