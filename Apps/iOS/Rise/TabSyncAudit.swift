#if DEBUG
import UIKit
import WebKit

/// Isolated native adapter checks: no account, shared session, or user's CloudKit records.
@MainActor enum TabSyncAudit {
    static let argument = "-RiseTabSyncAudit"
    struct Failure: Error { let name: String }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("TabSyncAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: host.view.window!, folder: folder)
                try "Passed\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static func exercise(in window: UIWindow, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !value { throw Failure(name: name) }
        }
        let suite = "RiseTabSyncAudit-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let first = MobileBrowserSession.Tab(url: nil, title: "Background"), active = MobileBrowserSession.Tab(url: nil, title: "Active")
        store.save(.init(tabs: [first, active], selectedTabID: active.id)); store.flush()
        func makeSync() -> SharedTabsSync {
            SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        }
        let sync = makeSync()
        sync.setEnabled(true)
        func makeBrowser(_ sync: SharedTabsSync) -> BrowserViewController {
            let browser = BrowserViewController(sessionStore: store, tabSync: sync, websiteDataStore: .nonPersistent())
            window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
            return browser
        }
        let browser = makeBrowser(sync), page = browser.tabs[browser.tabIndex], webView = browser.webView
        webView.loadHTMLString("<title>Page being read</title><body>Keep this page<script>window.syncMarker = 42</script></body>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading || webView.title != "Page being read", Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try check("real-webkit-page-is-loaded", webView.title == "Page being read")
        // The tab being read closes on the other device: it closes here, for the front of the list.
        let front = SharedBrowserTab(id: UUID(), url: nil, title: "Front"), back = SharedBrowserTab(id: UUID(), url: nil, title: "Back")
        sync.capture([front, back]); sync.onTabsChange?([front, back])
        try check("remote-close-of-the-active-tab-closes-it-here", browser.tabs.map(\.id) == [front.id, back.id] && sync.isClosed(active.id))
        try check("remote-close-goes-to-the-first-tab", browser.tabIndex == 0 && browser.tabs[browser.tabIndex].id == front.id && browser.tabs[0] !== page)
        try check("remote-close-replaces-the-page-shown", browser.webView !== webView && webView.superview == nil && browser.webView.superview != nil)
        browser.saveSession(flush: true)
        try check("session-drops-the-closed-tab", store.load()?.tabs.map(\.id) == [front.id, back.id] && store.load()?.selectedTabID == front.id)
        // A background closure and an insert leave the tab being read alone, wherever it moves to.
        let shown = browser.webView, inserted = SharedBrowserTab(id: UUID(), url: nil, title: "Inserted")
        sync.capture([inserted, front]); sync.onTabsChange?([inserted, front])
        try check("background-removal-and-insertion-still-apply", browser.tabs.map(\.id) == [inserted.id, front.id] && sync.isClosed(back.id))
        try check("background-changes-keep-the-tab-being-read", browser.tabs[browser.tabIndex].id == front.id && browser.webView === shown)
        for _ in 0..<3 { sync.capture([]); sync.onTabsChange?([]) }
        try check("remote-close-all-leaves-a-blank-page", browser.tabs.count == 1 && browser.tabs[0].isSyncPlaceholder && browser.tabIndex == 0)
        try check("repeated-sync-never-reshares-closed-tabs", sync.tabs.isEmpty && sync.isClosed(front.id))
        browser.saveSession(flush: true)
        let restoredSync = makeSync(), restored = makeBrowser(restoredSync)
        try check("relaunch-keeps-the-remote-tombstones", restoredSync.tabs.isEmpty && restoredSync.isClosed(active.id) && !restored.tabs.contains { $0.id == active.id })
        restored.saveSession(flush: true)
    }
}
#endif
