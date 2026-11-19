#if DEBUG
import UIKit
import WebKit

/// Real HTTP/WebKit regression checks for imported tabs, without touching the user's session.
@MainActor enum TabPreviewAudit {
    static let argument = "-RiseTabPreviewAudit"
    struct Failure: Error { let name: String }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("TabPreviewAudit")
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
        func wait(_ name: String, seconds: TimeInterval = 30, until ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try check(name, ready())
        }
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let blank = MobileBrowserSession.Tab(url: nil)
        store.save(.init(tabs: [blank], selectedTabID: blank.id)); store.flush()
        let suite = "RiseTabPreviewSync-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        sync.setEnabled(true)
        let cache = folder.appendingPathComponent("previews")
        func makeBrowser() -> BrowserViewController {
            let browser = BrowserViewController(sessionStore: store, tabSync: sync, previewCacheURL: cache)
            window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
            // The beta simulator runner can leave a scene foreground-inactive. Preserve the
            // real gesture/panel gates while testing rendering in this isolated window.
            browser.tabPreviews!.canRender = { [weak browser] in
                guard let browser else { return false }
                return !browser.isPanelOpen && !browser.tabSwitcher.isAnimatingOrTracking
            }
            browser.setTabPreviewsActive(true)
            return browser
        }
        let browser = makeBrowser()
        defer { browser.setTabPreviewsActive(false) }
        let remote = (0..<12).map { index in
            SharedBrowserTab(id: UUID(), url: fixture.url.appendingPathComponent(index == 0 ? "preview/slow" : "preview/blue-\(index)").absoluteString,
                             title: "Imported page \(index)")
        }
        let incoming = [SharedBrowserTab(id: blank.id, url: nil, title: nil)] + remote
        sync.capture(incoming); sync.onTabsChange?(incoming)
        try await wait("synced-batch-is-applied") { browser.tabs.count == incoming.count }
        browser.showTabSwitcher()
        let began = Date()
        try await wait("the-visible-card-is-prioritized-over-offscreen-tabs", seconds: 6) {
            guard let index = browser.tabSwitcher.focusedIndex else { return false }
            return browser.tabs[index].snapshot != nil
        }
        try await wait("all-imported-tabs-get-favicons-independently", seconds: 8) { browser.tabs.dropFirst().allSatisfy { $0.favicon != nil } }
        try check("favicons-do-not-wait-for-the-slow-page-resource", Date().timeIntervalSince(began) < 8)
        var peak = 0
        try await wait("every-imported-tab-gets-a-nonblank-preview") {
            peak = max(peak, browser.tabPreviews!.host.subviews.count)
            return browser.tabs.dropFirst().allSatisfy { $0.snapshot.map { !TabPreviewRenderer.isBlank($0) } == true }
        }
        try check("rendering-pool-is-bounded-to-two-webviews", peak <= 2)
        try check("previewing-preserves-lazy-real-pages", browser.tabs.dropFirst().allSatisfy { $0.webView.url == nil })
        try check("previewing-preserves-selection", browser.tabs[browser.tabIndex].id == blank.id)
        try check("previewing-preserves-shared-titles-and-addresses", browser.tabs.dropFirst().map(\.sessionTab).map { SharedBrowserTab(id: $0.id, url: $0.url?.absoluteString, title: $0.title) } == remote)
        try check("open-switcher-receives-the-new-previews", browser.tabs.indices.dropFirst().allSatisfy {
            browser.tabSwitcher.cells[$0].card.image.image === browser.tabs[$0].snapshot
        })
        let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true) }
        try image.pngData()?.write(to: folder.appendingPathComponent("synced-previews.png"))
        browser.saveSession(flush: true); browser.tabPreviews!.cache.flush(); browser.setTabPreviewsActive(false)
        let requests = fixture.pageRequests
        let restored = makeBrowser()
        defer { restored.setTabPreviewsActive(false) }
        try await wait("relaunch-restores-pictures-and-icons-from-cache", seconds: 5) {
            restored.tabs.dropFirst().allSatisfy { $0.snapshot != nil && $0.favicon != nil }
        }
        try check("cached-previews-need-no-extra-page-loads", fixture.pageRequests == requests)
        restored.setTabPreviewsActive(false)

        let loader = BackgroundTabPreviews(cacheURL: folder.appendingPathComponent("retry-previews"), adBlocker: .shared, retryDelay: 0.5)
        restored.view.insertSubview(loader.host, at: 0); loader.host.frame = restored.view.bounds
        loader.canRender = { true }
        defer { loader.setActive(false) }
        let delayedURL = fixture.url.appendingPathComponent("preview/delayed")
        let delayed = BrowserTab(webView: WKWebView(), restoring: .init(url: delayedURL, title: "Delayed"))
        let white = UIGraphicsImageRenderer(size: restored.view.bounds.size).image { c in
            UIColor.white.setFill(); c.fill(restored.view.bounds)
        }
        loader.cache.save(id: delayed.id, url: delayedURL, picture: white, favicon: nil); loader.cache.flush()
        loader.update(tabs: [restored.tabs[restored.tabIndex], delayed], selected: restored.tabs[restored.tabIndex], viewport: restored.view.bounds.size, stripHeight: 60)
        try await wait("late-rendering-page-gets-its-icon-first", seconds: 3) { delayed.favicon != nil && delayed.snapshot == nil }
        loader.cache.flush()
        let iconOnly = await loader.cache.load(id: delayed.id, url: delayedURL)
        try check("favicon-is-cached-before-the-picture-is-ready", iconOnly?.favicon != nil && iconOnly?.picture == nil)
        try await wait("cached-blank-is-replaced-after-client-side-content-paints", seconds: 12) {
            delayed.snapshot.map { !TabPreviewRenderer.isBlank($0) } == true
        }
        try check("late-content-does-not-navigate-the-real-tab", delayed.webView.url == nil)
        let retryTab = BrowserTab(webView: WKWebView(), restoring: .init(url: fixture.url.appendingPathComponent("preview/retry")))
        loader.update(tabs: [restored.tabs[restored.tabIndex], retryTab], selected: restored.tabs[restored.tabIndex], viewport: restored.view.bounds.size, stripHeight: 60)
        try await wait("failed-page-retries-without-another-sync-update", seconds: 12) { retryTab.snapshot != nil }
        try check("retry-really-makes-another-request", fixture.requestCount(for: "/preview/retry") >= 2)
        loader.setActive(false)
        try await wait("backgrounding-removes-the-temporary-pages", seconds: 3) { loader.host.subviews.isEmpty }
        let slowIcons = try AdBlockHTTPFixture(slowIcons: true); try await slowIcons.start()
        defer { slowIcons.stop() }
        let independent = BackgroundTabPreviews(cacheURL: folder.appendingPathComponent("slow-icons"), adBlocker: .shared)
        restored.view.insertSubview(independent.host, at: 0); independent.host.frame = restored.view.bounds
        independent.canRender = { true }
        defer { independent.setActive(false) }
        let pages = (0..<6).map { index in
            BrowserTab(webView: WKWebView(), restoring: .init(url: slowIcons.url.appendingPathComponent("preview/blue-\(index)")))
        }
        independent.update(tabs: [restored.tabs[restored.tabIndex]]+pages, selected: restored.tabs[restored.tabIndex], viewport: restored.view.bounds.size, stripHeight: 60)
        try await wait("slow-declared-icons-never-block-the-next-pages-preview", seconds: 10) { pages.allSatisfy { $0.snapshot != nil } }
        try check("private-browsers-never-create-preview-workers", BrowserViewController(previewCacheURL: cache, isPrivateBrowsing: true).tabPreviews == nil)
    }
}
#endif
