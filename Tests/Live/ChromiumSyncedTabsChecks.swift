// Dormant tabs imported from iPhone, in a real Chromium-backed Rise window.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumSyncedTabsChecks.swift
import AppKit
import RiseCore
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumSyncedTabsMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL metadata check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder+"/chromium", keychain: false) else { print("FAIL Chromium did not start"); exit(1) }
        let run = SyncedTabsRun(folder: URL(fileURLWithPath: folder))
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class SyncedTabsRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    var peak = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ name: String) { print(condition ? "PASS" : "FAIL", name); if !condition { failures += 1 } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            browser.syncedTabMetadata?.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let selected = browser.addTab(url: URL(string: "about:blank")!)
        let urls = ["https://news.ycombinator.com/", "https://github.com/", "https://developer.mozilla.org/en-US/docs/Web/HTML"]
        let imports = urls.map { SharedBrowserTab(id: UUID(), url: $0, title: URL(string: $0)!.host) }
        browser.applySharedTabs(imports + [.init(id: selected.id, url: nil, title: selected.title)])
        let imported = browser.tabs.filter { imports.map(\.id).contains($0.id) }
        check(imported.count == 3 && browser.selectedID == selected.id, "Remote insert preserves the selected tab")
        check(imported.allSatisfy { $0.page is ChromiumPage && !$0.hasAttemptedNavigation && $0.page.url == nil }, "Imported Chromium pages remain unloaded")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            peak = max(peak, browser.syncedTabMetadata?.activeCount ?? 0)
            if imported.allSatisfy({ $0.favicon != nil && !SyncedTabMetadata.needsTitle($0.title, url: $0.url!) }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        for tab in imported {
            check(!SyncedTabMetadata.needsTitle(tab.title, url: tab.url!), "Background title for \(tab.url!.host!): \(tab.title)")
            check(tab.favicon != nil && tab.saved.faviconData != nil, "Background favicon persists for \(tab.url!.host!)")
            check(tab.page.url == nil && !tab.hasAttemptedNavigation, "Metadata never navigates \(tab.url!.host!)")
            check(browser.sidebar.rows[tab.id]?.icon.image === tab.favicon, "Sidebar receives the fetched icon for \(tab.url!.host!)")
        }
        check(peak <= SyncedTabMetadata.concurrency, "Metadata concurrency is bounded")
        check(browser.selectedID == selected.id, "Fetches never steal selection")
        check(browser.browsingHistory.entries.isEmpty, "Prefetch does not create browsing-history visits")
        browser.saveNow()
        let state = SessionStorage.read(from: browser.sessionURL)
        check(imported.allSatisfy { tab in state?.tabs.first { $0.id == tab.id }?.faviconData != nil }, "Session saves background icons")
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.syncedTabMetadata?.cancel(); restored.saveWork?.cancel(); restored.window?.orderOut(nil) }
        check(imported.allSatisfy { original in
            restored.tabs.contains { $0.id == original.id && $0.title == original.title && $0.favicon != nil && !$0.hasAttemptedNavigation }
        }, "Cached titles and icons are present immediately after restoring")
    }
}
