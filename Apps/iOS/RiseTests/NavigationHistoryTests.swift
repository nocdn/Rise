import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class NavigationHistoryTests: XCTestCase {
    @MainActor private func host(_ browser: BrowserViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = browser; window.makeKeyAndVisible()
        browser.view.layoutIfNeeded(); return window
    }
    @MainActor private func wait(_ browser: BrowserViewController, at url: URL) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if browser.webView.url == url, !browser.webView.isLoading, browser.tabs[browser.tabIndex].hasCommittedDocument {
                try await Task.sleep(for: .milliseconds(100)); return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("History navigation did not reach \(url); actual \(String(describing: browser.webView.url))")
    }
    @MainActor private func addresses(_ fixture: AdBlockHTTPFixture) -> [URL] {
        [fixture.url, fixture.url.appendingPathComponent("replacement"),
         URL(string: fixture.url.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")+"#third")!]
    }

    @MainActor func testLocalSessionRestoresNativeBackForwardListAndMiddleCursor() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start(); defer { fixture.stop() }
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseNativeHistory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let urls = addresses(fixture)
        let browser = BrowserViewController(startURL: urls[0], sessionStore: store)
        let window = try host(browser); defer { window.isHidden = true }
        try await wait(browser, at: urls[0])
        for url in urls.dropFirst() { browser.webView.load(URLRequest(url: url)); try await wait(browser, at: url) }
        browser.webView.goBack(); try await wait(browser, at: urls[1])
        browser.saveSession(flush: true)
        let saved = try XCTUnwrap(store.load()?.tabs.first)
        XCTAssertNotNil(saved.interactionState)
        XCTAssertEqual(saved.navigationHistory?.entries.map(\.url), urls.map(\.absoluteString))
        XCTAssertEqual(saved.navigationHistory?.index, 1)
        let restored = BrowserViewController(sessionStore: store)
        window.rootViewController = restored; restored.view.layoutIfNeeded()
        try await wait(restored, at: urls[1])
        XCTAssertTrue(restored.webView.canGoBack); XCTAssertTrue(restored.webView.canGoForward)
        restored.webView.goBack(); try await wait(restored, at: urls[0])
        restored.webView.goForward(); try await wait(restored, at: urls[1])
        restored.webView.goForward(); try await wait(restored, at: urls[2])
        XCTAssertFalse(restored.webView.canGoForward)
    }

    @MainActor func testPortableHistoryLoadsOnlyTheSelectedPageAndUsesNativeAndScriptTraversal() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start(); defer { fixture.stop() }
        let folder = URL.temporaryDirectory.appendingPathComponent("RisePortableHistory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), cloudAvailable: false)
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let browser = BrowserViewController(startURL: nil, sessionStore: store, tabSync: sync)
        let window = try host(browser); defer { window.isHidden = true }
        let urls = addresses(fixture)
        let history = TabNavigationHistory(entries: urls.enumerated().map { .init(url: $0.element.absoluteString, title: "Page \($0.offset)") }, index: 1)
        let remote = SharedBrowserTab(id: browser.tabs[0].id, url: urls[1].absoluteString, title: "Page 1", navigationHistory: history)
        let before = fixture.pageRequests
        sync.capture([remote]); sync.onTabsChange?([remote])
        try await wait(browser, at: urls[1])
        XCTAssertEqual(fixture.pageRequests, before+1, "Restoration must not visit Back/Forward destinations")
        XCTAssertTrue(browser.webView.canGoBack); XCTAssertTrue(browser.webView.canGoForward)
        XCTAssertEqual(browser.tabs[0].navigationHistory?.entries.map(\.url), urls.map(\.absoluteString), "Imported history")
        try await browser.webView.evaluateJavaScript("history.back()")
        try await wait(browser, at: urls[0])
        browser.webView.goForward(); try await wait(browser, at: urls[1])
        browser.webView.goForward(); try await wait(browser, at: urls[2])
        browser.saveSession(flush: true)
        XCTAssertEqual(sync.tabs.first?.navigationHistory?.index, 2, "Synced cursor after Forward")
        XCTAssertEqual(sync.tabs.first?.navigationHistory?.entries.map(\.url), urls.map(\.absoluteString), "Synced history after Forward")
        // A new branch discards Forward, including not-yet-loaded placeholders.
        browser.webView.goBack(); try await wait(browser, at: urls[1])
        let branch = URL(string: urls[1].absoluteString+"#branch")!
        browser.webView.load(URLRequest(url: branch)); try await wait(browser, at: branch)
        XCTAssertFalse(browser.webView.canGoForward)
        XCTAssertEqual(browser.tabs[0].navigationHistory?.entries.last?.url, branch.absoluteString)
    }

    @MainActor func testRepeatedSameURLPushStateAndReplaceStateAreSavedWithoutDuplicatingNavigation() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start(); defer { fixture.stop() }
        let browser = BrowserViewController(startURL: fixture.url)
        let window = try host(browser); defer { window.isHidden = true }
        try await wait(browser, at: fixture.url)
        try await browser.webView.evaluateJavaScript("history.pushState({step:1}, '', location.href); history.pushState({step:2}, '', location.href); history.replaceState({step:3}, '', location.href)")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(browser.tabs[0].sessionTab.navigationHistory?.entries.count, 3)
        XCTAssertEqual(browser.tabs[0].sessionTab.navigationHistory?.index, 2)
        browser.webView.goBack()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(browser.tabs[0].sessionTab.navigationHistory?.index, 1)
        XCTAssertTrue(browser.webView.canGoForward)
    }

    @MainActor func testPeekHistoryAndItsForwardPageSurvivePortableRestoration() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start(); defer { fixture.stop() }
        let folder = URL.temporaryDirectory.appendingPathComponent("RisePeekHistory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileBrowserSessionStore(fileURL: folder.appendingPathComponent("session.json"))
        let urls = addresses(fixture)
        let browser = BrowserViewController(startURL: urls[0], sessionStore: store)
        let window = try host(browser); defer { window.isHidden = true }
        try await wait(browser, at: urls[0])
        let peek = BrowserViewController(startURL: urls[1], allowsPeek: false)
        let peekWindow = try host(peek); defer { peekWindow.isHidden = true }
        try await wait(peek, at: urls[1])
        browser.adopt(peek.webView)
        peekWindow.isHidden = true; window.makeKeyAndVisible()
        browser.returnToPreviousPage()
        browser.saveSession(flush: true)
        let saved = try XCTUnwrap(store.load()?.tabs.first)
        XCTAssertEqual(saved.navigationHistory?.entries.map(\.url), Array(urls.prefix(2)).map(\.absoluteString))
        XCTAssertEqual(saved.navigationHistory?.index, 0)
        XCTAssertNil(saved.interactionState, "Two live pages need one portable history on relaunch")
        let restored = BrowserViewController(sessionStore: store)
        window.rootViewController = restored; restored.view.layoutIfNeeded()
        try await wait(restored, at: urls[0])
        XCTAssertTrue(restored.webView.canGoForward)
        restored.webView.goForward(); try await wait(restored, at: urls[1])
    }

    @MainActor func testReloadKeepsHeldForwardButSameURLPushStateDiscardsIt() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start(); defer { fixture.stop() }
        let browser = BrowserViewController(startURL: fixture.url)
        let window = try host(browser); defer { window.isHidden = true }
        try await wait(browser, at: fixture.url)
        let peek = BrowserViewController(startURL: fixture.url.appendingPathComponent("replacement"), allowsPeek: false)
        let peekWindow = try host(peek); defer { peekWindow.isHidden = true }
        try await wait(peek, at: fixture.url.appendingPathComponent("replacement"))
        browser.adopt(peek.webView); browser.returnToPreviousPage()
        peekWindow.isHidden = true; window.makeKeyAndVisible()
        browser.reloadPage(); try await wait(browser, at: fixture.url)
        XCTAssertEqual(browser.tabs[0].forwardPages.count, 1)
        try await browser.webView.evaluateJavaScript("history.pushState({}, '', location.href)")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(browser.tabs[0].forwardPages.isEmpty)
        XCTAssertEqual(browser.tabs[0].sessionTab.navigationHistory?.entries.map(\.url), [fixture.url.absoluteString, fixture.url.absoluteString])
        XCTAssertFalse(browser.webView.canGoForward)
    }

    @MainActor func testMalformedOptionalHistoryDoesNotDiscardTheLocalSession() throws {
        let id = UUID()
        let object: [String: Any] = ["version":1, "selectedTabID":id.uuidString, "tabs":[[
            "id":id.uuidString, "url":"https://example.com/", "title":"Kept",
            "navigationHistory":["entries": [["url":"javascript:alert(1)"]], "index":999],
            "interactionState":"invalid base64"
        ]]]
        let session = try JSONDecoder().decode(MobileBrowserSession.self, from: JSONSerialization.data(withJSONObject: object)).validated
        XCTAssertEqual(session?.tabs.first?.url?.absoluteString, "https://example.com/")
        XCTAssertNil(session?.tabs.first?.navigationHistory)
        XCTAssertNil(session?.tabs.first?.interactionState)
    }
}
