#if DEBUG
import UIKit
import WebKit

/// Archiving unused tabs in an isolated browser with real WebKit pages: no account, shared session
/// or the user's CloudKit records. Run with `-RiseTabArchiveAudit`; results and pictures of the panels
/// are left in Caches/TabArchiveAudit.
@MainActor enum TabArchiveAudit {
    static let argument = "-RiseTabArchiveAudit"
    struct Failure: Error { let name: String }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("TabArchiveAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: host.view.window!, folder: folder)
                try "Passed\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
            UserDefaults.standard.removeObject(forKey: BrowserViewController.tabArchiveHoursKey)
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
        func shot(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try? image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        func settle(_ milliseconds: Int = 600) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        let old = Date().addingTimeInterval(-72*3600)
        /// A browser as a relaunch leaves it, the first of so many tabs selected, with no iCloud.
        func makeBrowser(tabs count: Int, name: String) -> (BrowserViewController, SharedTabsSync) {
            let place = folder.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let preferences = UserDefaults(suiteName: "RiseTabArchiveAudit-\(name)-\(UUID())")!
            let sync = SharedTabsSync(cacheURL: place.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
            let store = MobileBrowserSessionStore(fileURL: place.appendingPathComponent("session.json"))
            let tabs = (0..<count).map { MobileBrowserSession.Tab(url: URL(string: "https://example.com/\($0)"), title: "Page \($0)") }
            store.save(.init(tabs: tabs, selectedTabID: tabs[0].id)); store.flush()
            let browser = BrowserViewController(sessionStore: store, tabSync: sync, websiteDataStore: .nonPersistent())
            window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
            return (browser, sync)
        }
        func age(_ browser: BrowserViewController, _ sync: SharedTabsSync) { for tab in browser.tabs { sync.recordUse(of: tab.id, at: old) } }

        // With no other device: the time starts, then the unused go.
        let (fresh, _) = makeBrowser(tabs: 13, name: "fresh")
        try check("nothing-goes-when-time-first-starts", fresh.tabsDueForArchiving().isEmpty)
        let (alone, aloneSync) = makeBrowser(tabs: 13, name: "alone")
        age(alone, aloneSync)
        let due = alone.tabsDueForArchiving(), reading = alone.tabs[alone.tabIndex]
        try check("all-but-the-ten-that-always-stay-are-due", due.count == 3)
        try check("the-tab-being-read-is-not-due", !due.contains { $0 === reading })
        await alone.archiveUnusedTabs()
        try check("unused-tabs-are-archived-with-no-mac", alone.tabs.count == 10 && alone.archivedEntries.count == 3)
        try check("the-tab-being-read-stays-shown", alone.tabs[alone.tabIndex] === reading)
        try check("their-closures-are-shared", due.allSatisfy { aloneSync.isClosed($0.id) && aloneSync.isArchived($0.id) })
        try check("a-toast-says-so", alone.toast?.accessibilityLabel == "Archived 3 unused tabs")
        await settle(); shot("toast")
        alone.toast?.dismiss(animated: false)

        // The list, in History's panel.
        let bar = alone.bottomBar
        alone.openArchivedTabs(); await settle()
        try check("the-list-opens", bar.panel == .history && bar.history.header.title == "Archived Tabs" && bar.history.entries.count == 3)
        shot("archived-list")
        let toDelete = due[1], toReopen = due[0], address = toReopen.sessionTab.url!
        alone.removeArchived([toDelete.sessionTab.url!.absoluteString])
        try check("deleting-is-shared", aloneSync.isRemovedFromArchive(toDelete.id) && alone.archivedEntries.count == 2)
        alone.reopenArchived(address.absoluteString); await settle()
        try check("reopening-goes-to-the-front", alone.tabs[0].sessionTab.url == address && alone.tabIndex == 0 && alone.webView === alone.tabs[0].webView)
        try check("reopening-is-a-new-identity", alone.tabs[0].id != toReopen.id && aloneSync.isRemovedFromArchive(toReopen.id))
        alone.saveSession(flush: true)
        try check("reopened-it-is-shared-again", aloneSync.tabs.contains { $0.id == alone.tabs[0].id })
        try check("reopened-it-has-its-time-started", aloneSync.use(of: alone.tabs[0].id).map { $0.lastUsed > Date().addingTimeInterval(-60) } == true)
        try check("the-tab-it-left-stays", alone.tabs.contains { $0 === reading })
        alone.openHistory(); await settle()
        try check("history-is-still-history-afterwards", bar.history.header.title == "History")
        alone.closePanel(); await settle()

        // What another device says.
        let (kept, keptSync) = makeBrowser(tabs: 14, name: "kept")
        age(kept, keptSync)
        let pinned = kept.tabs[1], usedElsewhere = kept.tabs[2]
        keptSync.setKept(pinned.id, true)
        keptSync.recordUse(of: usedElsewhere.id)
        let keptDue = kept.tabsDueForArchiving()
        try check("a-tab-pinned-on-the-mac-stays", !keptDue.contains { $0 === pinned })
        try check("a-tab-used-on-the-mac-stays", !keptDue.contains { $0 === usedElsewhere })
        let (arriving, arrivingSync) = makeBrowser(tabs: 3, name: "arriving")
        let arrived = arriving.tabs[1]
        // As it reaches a phone: closed in the list of tabs, and marked in the list of archived tabs.
        arrivingSync.archive([arrived.id])
        arrivingSync.capture(arriving.tabs.filter { $0 !== arrived }.map {
            SharedBrowserTab(id: $0.id, url: $0.sessionTab.url?.absoluteString, title: $0.sessionTab.title)
        })
        arrivingSync.onTabsChange?(arrivingSync.tabs)
        try check("a-tab-archived-elsewhere-closes-here", !arriving.tabs.contains { $0 === arrived })
        try check("and-is-in-the-list-here", arriving.archivedEntries.map(\.title) == ["Page 1"])

        // Real pages in the background.
        let (pages, pagesSync) = makeBrowser(tabs: 12, name: "pages")
        let form = pages.tabs[2], plain = pages.tabs[3]
        // Longest unused, so that only the page's being in use can save either from the two that go.
        for tab in pages.tabs { pagesSync.recordUse(of: tab.id, at: tab === form || tab === plain ? old.addingTimeInterval(-3600) : old) }
        for (tab, html) in [(form, "<title>Form</title><input id=a value=''>"), (plain, "<title>Plain</title><p>Nothing here")] {
            tab.webView.loadHTMLString(html, baseURL: tab.sessionTab.url)
            let deadline = Date().addingTimeInterval(10)
            while tab.webView.isLoading || tab.webView.url == nil, Date() < deadline { await settle(25) }
        }
        _ = try? await form.webView.evaluateJavaScript("document.getElementById('a').value = 'Still writing'; true")
        let pagesDue = pages.tabsDueForArchiving()
        try check("real-pages-are-next-to-go", pagesDue.contains { $0 === form } && pagesDue.contains { $0 === plain })
        await pages.archiveUnusedTabs()
        try check("the-page-with-something-part-filled-stays", pages.tabs.contains { $0 === form })
        try check("the-page-with-nothing-part-filled-goes", !pages.tabs.contains { $0 === plain })
        pages.toast?.dismiss(animated: false)

        // Never, and the panels.
        let (settings, settingsSync) = makeBrowser(tabs: 14, name: "settings")
        age(settings, settingsSync)
        settings.setTabArchiveHours(0)
        try check("never-turns-it-off", settings.tabsDueForArchiving().isEmpty && settings.bottomBar.appSettings.archiveRow.button.accessibilityValue == "Never")
        settings.setTabArchiveHours(168)
        try check("the-choice-shows", settings.bottomBar.appSettings.archiveRow.button.accessibilityValue == "After 1 week")
        settings.setTabArchiveHours(48)
        settings.bottomBar.moreButton.sendActions(for: .primaryActionTriggered); await settle(200)
        settings.openSiteSettings(); settings.openAppSettings(); await settle()
        try check("settings-open", settings.bottomBar.panel == .appSettings)
        shot("settings")
        settings.closePanel(); await settle()
        settings.openPanel(.tabMenu); await settle()
        shot("tab-menu")
    }
}
#endif
