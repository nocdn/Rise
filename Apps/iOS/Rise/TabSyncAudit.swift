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
        let added = SharedBrowserTab(id: UUID(), url: nil, title: "Remote insert")
        sync.capture([added]); sync.onTabsChange?([added])
        try check("background-removal-and-insertion-still-apply", browser.tabs.map(\.id) == [added.id, active.id])
        try check("remote-close-keeps-the-same-active-tab-and-webview", browser.tabs[browser.tabIndex] === page && browser.webView === webView)
        let marker = try await webView.evaluateJavaScript("window.syncMarker") as? Int
        try check("remote-close-does-not-reload-the-active-page", marker == 42)
        for _ in 0..<3 { sync.capture([]); sync.onTabsChange?([]) }
        try check("remote-close-all-leaves-only-the-active-page", browser.tabs.map(\.id) == [active.id])
        try check("repeated-sync-never-reshare-the-retained-tab", sync.tabs.isEmpty && sync.isClosed(active.id))
        browser.saveSession(flush: true)
        try check("session-persists-the-retained-page-and-selection", store.load()?.tabs.map(\.id) == [active.id] && store.load()?.selectedTabID == active.id)
        let restoredSync = makeSync(), restored = makeBrowser(restoredSync)
        try check("relaunch-keeps-the-active-page", restored.tabs.map(\.id) == [active.id] && restored.tabs[restored.tabIndex].id == active.id)
        try check("relaunch-keeps-the-remote-tombstone", restoredSync.tabs.isEmpty && restoredSync.isClosed(active.id))
        let next = SharedBrowserTab(id: UUID(), url: nil, title: "Another new tab")
        restoredSync.capture([next]); restoredSync.onTabsChange?([next])
        let index = restored.tabs.firstIndex { $0.id == next.id }!
        restored.showTabSwitcher()
        try await Task.sleep(for: .milliseconds(400))
        restored.selectTab(index)
        try await Task.sleep(for: .milliseconds(450))
        restoredSync.onTabsChange?([next])
        try check("a-previously-active-closed-page-can-be-removed-in-background", restored.tabs.map(\.id) == [next.id])
        restored.saveSession(flush: true)
    }
}
#endif
