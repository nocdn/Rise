#if DEBUG
import UIKit
import WebKit

/// Real HTTP loads, including a delayed resource and a restored request stopped before commit.
@MainActor enum PageLoadingAudit {
    static let argument = "-RisePageLoadingAudit"
    struct Failure: Error { let name: String }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PageLoadingAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try await exercise(in: host.view.window!, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch { try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
        }
    }
    static func exercise(in window: UIWindow, folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ passed: Bool) throws {
            checks[name] = passed
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
            if !passed { throw Failure(name: name) }
        }
        func wait(_ name: String, _ ready: () -> Bool) async throws {
            for _ in 0..<800 {
                if ready() { try check(name, true); return }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(name, false)
        }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let previous = window.rootViewController
        defer { window.rootViewController = previous }
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let url = fixture.url.appendingPathComponent("preview/slow")
        let browser = BrowserViewController(startURL: url, websiteDataStore: .nonPersistent())
        window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
        let page = browser.webView, bar = browser.bottomBar, line = bar.loadingLine, address = bar.menu.address
        try await wait("real-page-load-shows-the-glowing-line") { page.isLoading && browser.tabs[0].hasCommittedDocument && line.isLoading && (line.progress ?? 0) > 0.05 }
        try check("line-is-along-the-toolbar-top-edge", line.frame == bar.bounds && (line.progressLine.path?.boundingBox.maxY ?? 100) < 1)
        let style = PageLoadProgress.Style()
        try check("line-uses-desktops-glow", line.progressLine.shadowRadius == style.glow && line.progressLine.shadowOpacity == style.glowOpacity && line.progressLine.shadowOffset == .zero)
        try check("line-does-not-intercept-toolbar-taps", !line.isUserInteractionEnabled && line.accessibilityElementsHidden)
        try await Task.sleep(for: .milliseconds(350))
        try capture("loading-toolbar")
        let previousProgress = line.progress ?? 0
        page.load(URLRequest(url: url))
        try await wait("a-new-navigation-rewinds-the-previous-loads-progress") { page.isLoading && (line.progress ?? 1) < previousProgress }
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(550))
        try check("menu-has-stop-while-page-loads", address.reloadButton.symbolName == "xmark" && address.reloadButton.accessibilityLabel == "Stop Loading")
        try check("glow-stays-on-expanded-panels-top-edge", line.frame == bar.bounds && !line.progressLine.isHidden)
        try capture("loading-menu-stop")
        let field = SearchField()
        address.prepareEditing(field, url: page.url)
        address.showLoading(true)
        try check("loading-updates-preserve-the-url-editors-clear-button", address.reloadButton.symbolName == "xmark" && address.reloadButton.accessibilityLabel == "Clear Address")
        address.endEditingAddress()
        try check("ending-url-editing-restores-stop", address.reloadButton.accessibilityLabel == "Stop Loading")
        try await wait("natural-completion-swaps-stop-back-to-reload") { !page.isLoading && address.reloadButton.symbolName == "arrow.clockwise" }
        try check("reload-uses-the-existing-animated-symbol-swap", address.reloadButton.subviews.count > 1)
        try await wait("completed-load-runs-to-end-and-fades") { line.progressLine.animation(forKey: PageLoadingLine.fadeKey) != nil }
        try check("fade-is-the-desktops-exact-duration", line.progressLine.animation(forKey: PageLoadingLine.fadeKey)?.duration == PageLoadProgress.fadeDuration && line.progress == 1)
        try await wait("completed-load-removes-the-line") { line.progress == nil && line.progressLine.isHidden }
        try check("completion-keeps-the-menu-open", browser.isPanelOpen)
        address.reloadButton.sendActions(for: .primaryActionTriggered)
        try await wait("reload-closes-menu-and-starts-a-new-load") { !browser.isPanelOpen && page.isLoading && line.isLoading }
        try check("new-load-clears-old-fade", line.progressLine.animation(forKey: PageLoadingLine.fadeKey) == nil && line.progressLine.opacity == 1)
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(200))
        address.reloadButton.sendActions(for: .primaryActionTriggered)
        try await wait("stop-closes-menu-and-cancels-the-load") { !browser.isPanelOpen && !page.isLoading && !line.isLoading }
        try check("stopping-preserves-the-committed-page", browser.tabs[0].hasCommittedDocument && browser.tabs[0].wasStopped && browser.tabs[0].navigationError == nil)
        try await wait("stop-restores-reload-and-finishes-the-glow") { address.reloadButton.symbolName == "arrow.clockwise" && line.progress == nil }
        let folderURL = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let store = MobileBrowserSessionStore(fileURL: folderURL.appendingPathComponent("session.json"))
        let earlyURL = fixture.url.appendingPathComponent("preview/precommit")
        let saved = MobileBrowserSession.Tab(url: earlyURL, title: "Restored destination")
        store.save(.init(tabs: [saved], selectedTabID: saved.id)); store.flush()
        let early = BrowserViewController(sessionStore: store, websiteDataStore: .nonPersistent())
        window.rootViewController = early; early.view.layoutIfNeeded()
        try await wait("restored-request-is-loading-before-commit") { early.webView.isLoading && !early.tabs[0].hasCommittedDocument && fixture.requestCount(for: "/preview/precommit") == 1 }
        early.openPanel(.menu)
        early.bottomBar.menu.address.reloadButton.sendActions(for: .primaryActionTriggered)
        try await wait("stop-cancels-a-restored-provisional-request") { !early.webView.isLoading && early.tabs[0].wasStopped }
        try await Task.sleep(for: .milliseconds(900))
        try check("explicit-stop-does-not-trigger-startup-recovery", !early.webView.isLoading && fixture.requestCount(for: "/preview/precommit") == 1)
        try check("stopped-initial-load-has-no-stuck-spinner", !early.navigationStatus.spinner.isAnimating && early.navigationStatus.title.text == "Loading stopped")
        try check("stopping-keeps-the-destination-for-reload", early.tabs[0].addressURL == earlyURL && early.bottomBar.menu.address.reloadButton.symbolName == "arrow.clockwise")
        early.openPanel(.menu)
        early.bottomBar.menu.address.reloadButton.sendActions(for: .primaryActionTriggered)
        try await wait("reload-after-stop-retries-the-original-destination") { early.webView.isLoading && fixture.requestCount(for: "/preview/precommit") == 2 }
        early.tabs[0].stopLoading()
        window.rootViewController = browser; browser.view.layoutIfNeeded()
        page.load(URLRequest(url: url))
        try await wait("another-slow-page-loads") { page.isLoading && line.isLoading }
        browser.openLinks([fixture.url.appendingPathComponent("preview/blue")])
        try await wait("switching-to-a-finished-tab-resets-the-loading-line") { browser.webView !== page && !browser.webView.isLoading && !line.isLoading && line.progress == nil }
        try check("background-load-does-not-own-foreground-controls", page.isLoading && address.reloadButton.symbolName == "arrow.clockwise")
        browser.tabs.first { $0.webView === page }?.stopLoading()
        fixture.shouldFail = true
        browser.reloadPage()
        try await wait("failed-load-stops-the-loading-animation") { browser.tabs[browser.tabIndex].navigationError != nil && !line.isLoading && line.progress == nil }
        try check("failed-load-keeps-reload-available", address.reloadButton.symbolName == "arrow.clockwise")
    }
}
#endif
