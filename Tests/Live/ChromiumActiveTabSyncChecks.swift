// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumActiveTabSyncChecks.swift
import AppKit
import RiseCore
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumActiveTabSyncMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+45) { print("FAIL active-tab sync check timed out"); exit(1) }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let app = RCApplication.shared, run = ActiveTabSyncRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ActiveTabSyncRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ name: String) {
        print(condition ? "PASS" : "FAIL", name)
        if !condition { failures += 1 }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await exercise() } catch { print("FAIL", error); failures += 1 }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func exercise() async throws {
        let suite = "RiseActiveTabSync-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        browser.tabSync = sync
        sync.onTabsChange = { [weak browser] in browser?.applySharedTabs($0) }
        defer { browser.syncedTabMetadata?.cancel(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil); sync.flush() }
        browser.showWindow(nil)
        let background = browser.addTab()
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        try "<title>Active reading page</title><body style='height:5000px'>Preserve me<script>window.syncMarker = 42</script>".write(to: folder.appendingPathComponent("reading.html"), atomically: true, encoding: .utf8)
        let url = URL(string: "http://127.0.0.1:\(port)/reading.html")!
        let active = browser.addTab(url: url), page = active.page
        let deadline = Date().addingTimeInterval(12)
        while page.url != url || page.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        check(page.url == url && !page.isLoading, "Real Chromium page loaded")
        _ = try await page.evaluate("window.scrollTo(0, 400)", arguments: [:], in: nil, world: .page)
        sync.start(tabs: browser.sharedTabsSnapshot)
        let remote = SharedBrowserTab(id: UUID(), url: nil, title: "From phone")
        sync.capture([remote]); sync.onTabsChange?([remote])
        check(Set(browser.tabs.map(\.id)) == [active.id, remote.id], "Background close and insert apply")
        check(!browser.tabs.contains { $0 === background }, "Remote background close removes its page")
        check(browser.selectedID == active.id && browser.selectedTab === active && browser.selectedTab?.page === page, "Active tab and live Chromium page stay in place")
        let marker = try await page.evaluate("return window.syncMarker", arguments: [:], in: nil, world: .page) as? Int
        let scroll = try await page.evaluate("return window.scrollY", arguments: [:], in: nil, world: .page) as? Int
        check(marker == 42 && scroll == 400, "Active document and scroll position survive remote closure")
        for _ in 0..<3 { sync.capture([]); sync.onTabsChange?([]) }
        check(browser.tabs.map(\.id) == [active.id] && browser.selectedID == active.id, "Repeated remote close-all retains only the active page")
        check(sync.tabs.isEmpty && sync.isClosed(active.id), "Preservation never reopens the tab on the phone")
        browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL, preferences: preferences)
        defer { restored.syncedTabMetadata?.cancel(); restored.saveWork?.cancel(); restored.tabs.forEach { $0.cancelLoad() }; restored.window?.orderOut(nil) }
        restored.applySharedTabs([])
        check(restored.tabs.map(\.id) == [active.id] && restored.selectedID == active.id, "Session restoration preserves the same tab identity")
        let next = SharedBrowserTab(id: UUID(), url: nil, title: "New tab")
        sync.capture([next]); sync.onTabsChange?([next])
        browser.select(next.id)
        sync.onTabsChange?([next])
        check(browser.tabs.map(\.id) == [next.id], "A later sync closes the retained tab once it is in the background")
        browser.closeTab(next.id)
        check(!browser.tabs.contains { $0.id == next.id }, "Explicit local close remains available")
    }
}
