#if DEBUG
import UIKit
import WebKit

/// Real failed HTTP restoration, retry and relaunch, with an isolated session store.
@MainActor enum BrowserRecoveryAudit {
    static let argument = "-RiseBrowserRecoveryAudit"
    struct Failure: Error { let name: String }
    static func exercise(in window: UIWindow, folder: URL) async throws -> [String: Bool] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
            if !value { throw Failure(name: name) }
        }
        func wait(_ predicate: @MainActor () async -> Bool) async throws {
            for _ in 0..<500 {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(name: "Timed out waiting for a page")
        }
        let server = try AdBlockHTTPFixture(); try await server.start()
        defer { server.stop() }
        server.shouldFail = true
        let store = MobileBrowserSessionStore(fileURL: URL.temporaryDirectory.appendingPathComponent("RiseRecovery-\(UUID())/session.json"))
        let saved = MobileBrowserSession.Tab(url: server.url, title: "Saved page")
        store.save(.init(tabs: [saved], selectedTabID: saved.id)); store.flush()
        let browser = BrowserViewController(sessionStore: store)
        window.rootViewController = browser
        browser.view.layoutIfNeeded()
        try await wait { browser.tabs[0].navigationError != nil && !browser.webView.isLoading }
        try check("failed-load-keeps-the-saved-destination", browser.tabs[0].sessionTab.url == server.url)
        try check("failed-load-shows-a-retry-state", !browser.navigationStatus.isHidden && !browser.navigationStatus.retryButton.isHidden)
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(350))
        try check("saved-address-is-visible-before-a-live-document", browser.bottomBar.menu.address.host.text == server.url.host)
        try check("saved-link-can-be-copied-and-shared", browser.bottomBar.menu.copyTile.isEnabled && browser.bottomBar.menu.shareTile.isEnabled)
        try check("unloaded-page-cannot-be-summarised", !browser.bottomBar.menu.summariseTile.isEnabled)
        try check("unloaded-page-cannot-be-searched", !browser.bottomBar.menu.findTile.isEnabled)
        server.shouldFail = false
        browser.bottomBar.menu.address.reloadButton.sendActions(for: .primaryActionTriggered)
        try await wait {
            let loaded = (try? await browser.webView.evaluateJavaScript("window.normalLoaded === true")) as? Bool
            return browser.tabs[0].hasCommittedDocument && !browser.webView.isLoading && loaded == true
        }
        try check("reload-retries-the-saved-url-and-loads-real-content", browser.webView.url == server.url)
        try check("successful-retry-removes-the-status-view", browser.navigationStatus.isHidden && browser.tabs[0].navigationError == nil)
        browser.saveSession(flush: true)
        try check("retry-preserves-the-tab-id", store.load()?.selectedTabID == saved.id)
        let restored = BrowserViewController(sessionStore: MobileBrowserSessionStore(fileURL: store.fileURL))
        window.rootViewController = restored
        restored.view.layoutIfNeeded()
        try await wait { restored.tabs[0].hasCommittedDocument && !restored.webView.isLoading }
        try check("relaunch-restores-and-loads-the-selected-url", restored.webView.url == server.url && restored.tabs[0].id == saved.id)
        try check("restoration-keeps-the-existing-list", restored.tabs.count == 1)
        // Interrupt a real provisional HTTP request before its document commits.
        let cancelled = BrowserViewController(sessionStore: MobileBrowserSessionStore(fileURL: store.fileURL))
        window.rootViewController = cancelled
        cancelled.view.layoutIfNeeded()
        try await wait { cancelled.tabs[0].restorationHasStarted && !cancelled.tabs[0].hasCommittedDocument }
        try check("interrupted-request-has-not-committed", !cancelled.tabs[0].hasCommittedDocument)
        cancelled.webView.stopLoading()
        do {
            try await wait { cancelled.tabs[0].hasCommittedDocument && !cancelled.webView.isLoading }
        } catch {
            let tab = cancelled.tabs[0]
            let state: [String: Any] = ["loading": cancelled.webView.isLoading,
                "started": tab.restorationHasStarted, "committed": tab.hasCommittedDocument,
                "errorCode": tab.navigationError.map { ($0 as NSError).code } ?? 0]
            try JSONSerialization.data(withJSONObject: state).write(to: folder.appendingPathComponent("navigation-state.json"))
            throw error
        }
        try check("cancelled-startup-recovers-instead-of-staying-blank", cancelled.webView.url == server.url)
        let count = server.pageRequests
        cancelled.webViewWebContentProcessDidTerminate(cancelled.webView)
        try await wait { server.pageRequests > count && cancelled.tabs[0].hasCommittedDocument && !cancelled.webView.isLoading }
        try check("web-content-termination-reloads-the-page", cancelled.webView.url == server.url && cancelled.navigationStatus.isHidden)
        let pending = BrowserTab(webView: BrowserViewController.makeWebView(), restoring: saved)
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        try check("startup-cancellation-retries-once", pending.didFail(nil, error: cancellation))
        try check("startup-cancellation-cannot-loop", !pending.didFail(nil, error: cancellation) && pending.navigationError != nil)
        // Two real pages also exercise the card styling and the shadow handoff during the flight.
        cancelled.openPanel(); cancelled.openFromPanel(server.url.appendingPathComponent("replacement"))
        try await wait { cancelled.tabs.count == 2 && cancelled.tabs[1].hasCommittedDocument && !cancelled.webView.isLoading }
        cancelled.showTabSwitcher()
        let switcher = cancelled.tabSwitcher
        try check("moving-card-leaves-no-shadow-remnant", switcher.cells[switcher.current].cardShadow.alpha == 0)
        try await Task.sleep(for: .milliseconds(850))
        try check("cards-have-subtle-path-based-shadows", switcher.cells.allSatisfy { $0.cardShadow.layer.shadowPath != nil && $0.cardShadow.layer.shadowOpacity == 0.10 && $0.cardShadow.alpha == 1 })
        try check("close-buttons-are-slightly-smaller", switcher.cells.allSatisfy { $0.closeButton.bounds.width == 22 })
        var white: CGFloat = 0, alpha: CGFloat = 0
        switcher.cells[0].closeButton.backgroundColor!.getWhite(&white, alpha: &alpha)
        try check("close-button-background-is-light", white > 0.9)
        switcher.cells[0].closeButton.tintColor.getWhite(&white, alpha: &alpha)
        try check("close-button-cross-is-medium-grey", (0.3...0.45).contains(white))
        let image = UIGraphicsImageRenderer(bounds: cancelled.view.bounds).image { _ in
            cancelled.view.drawHierarchy(in: cancelled.view.bounds, afterScreenUpdates: true)
        }
        try image.pngData()?.write(to: folder.appendingPathComponent("tab-cards.png"))
        return checks
    }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("BrowserRecoveryAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                let checks = try await exercise(in: host.view.window!, folder: folder)
                try "Passed \(checks.count) native checks\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
