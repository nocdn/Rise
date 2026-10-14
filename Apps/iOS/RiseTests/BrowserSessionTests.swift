import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class BrowserSessionTests: XCTestCase {
    @MainActor private func store() -> MobileBrowserSessionStore {
        let directory = URL.temporaryDirectory.appending(path: "RiseSessionTests-\(UUID())", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MobileBrowserSessionStore(fileURL: directory.appending(path: "BrowserSession.json"))
    }

    @MainActor private func host(_ browser: BrowserViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        browser.view.layoutIfNeeded()
        return window
    }

    @MainActor private func waitForPage(_ page: WKWebView) async throws {
        for _ in 0..<1000 {
            if !page.isLoading, (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The HTTP page did not finish loading")
    }

    @MainActor private func open(_ url: URL, in browser: BrowserViewController) async throws {
        let count = browser.tabs.count
        browser.openPanel()
        browser.openFromPanel(url)
        for _ in 0..<200 where browser.tabs.count == count { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(browser.tabs.count, count+1)
        try await waitForPage(browser.webView)
    }

    @MainActor private func select(_ index: Int, in browser: BrowserViewController) async throws {
        browser.showTabSwitcher()
        browser.selectTab(index)
        try await Task.sleep(for: .milliseconds(450))
    }

    @MainActor func testStorePreservesBlankTabsAndOrderAndRejectsInvalidRecords() throws {
        let store = store()
        XCTAssertNil(store.load())
        let first = MobileBrowserSession.Tab(url: URL(string: "https://example.com/article"), title: "Article")
        let blank = MobileBrowserSession.Tab(url: nil)
        let last = MobileBrowserSession.Tab(url: URL(string: "https://example.org/"), title: "Another site")
        let expected = MobileBrowserSession(tabs: [first, blank, last], selectedTabID: blank.id)
        store.save(MobileBrowserSession(tabs: [first], selectedTabID: first.id))
        store.save(expected)
        store.flush()
        XCTAssertEqual(MobileBrowserSessionStore(fileURL: store.fileURL).load(), expected)

        let invalid = MobileBrowserSession.Tab(url: URL(string: "javascript:alert(1)"))
        let mixed = MobileBrowserSession(tabs: [first, invalid, first, blank], selectedTabID: invalid.id)
        store.save(mixed); store.flush()
        XCTAssertEqual(store.load(), MobileBrowserSession(tabs: [first, blank], selectedTabID: first.id))

        var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        unsupported["version"] = 99
        try JSONSerialization.data(withJSONObject: unsupported).write(to: store.fileURL)
        XCTAssertNil(store.load())
        try Data("incomplete JSON".utf8).write(to: store.fileURL)
        XCTAssertNil(store.load())
    }

    @MainActor func testTabsRestoreSelectionBackgroundNavigationAndTitlesWithoutLoadingEveryPage() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let store = store(), second = fixture.url.appendingPathComponent("replacement")
        let third = URL(string: second.absoluteString+"#third")!
        var browser: BrowserViewController? = BrowserViewController(startURL: fixture.url, sessionStore: store)
        let window = try host(try XCTUnwrap(browser))
        defer { window.isHidden = true }
        try await waitForPage(try XCTUnwrap(browser).webView)
        let firstPage = try XCTUnwrap(browser).webView
        try await firstPage.evaluateJavaScript("document.title = 'First tab'")
        try await open(second, in: try XCTUnwrap(browser))
        try await (try XCTUnwrap(browser)).webView.evaluateJavaScript("document.title = 'Second tab'")
        try await open(third, in: try XCTUnwrap(browser))
        try await (try XCTUnwrap(browser)).webView.evaluateJavaScript("document.title = 'Third tab'")
        try await select(1, in: try XCTUnwrap(browser))
        // History API changes in a background tab must save too, without a didFinish callback.
        try await firstPage.evaluateJavaScript("history.pushState({}, '', '/#background'); document.title = 'Updated first tab'")
        let updatedURL = URL(string: fixture.url.absoluteString+"#background")!
        for _ in 0..<200 {
            let tab = try XCTUnwrap(browser).tabs[0].sessionTab
            if tab.url == updatedURL && tab.title == "Updated first tab" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try XCTUnwrap(browser).saveSession(flush: true)
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.tabs.map(\.url), [updatedURL, second, third])
        XCTAssertEqual(saved.tabs.map(\.title), ["Updated first tab", "Second tab", "Third tab"])
        XCTAssertEqual(saved.selectedTabID, saved.tabs[1].id)
        window.rootViewController = nil
        browser = nil

        let requests = fixture.pageRequests
        let restoredStore = MobileBrowserSessionStore(fileURL: store.fileURL)
        let restored = BrowserViewController(opensSearchOnFirstAppearance: true, sessionStore: restoredStore)
        XCTAssertEqual(restored.tabs.map(\.id), saved.tabs.map(\.id))
        XCTAssertEqual(restored.tabs.map(\.title), saved.tabs.compactMap(\.title))
        XCTAssertEqual(restored.tabIndex, 1)
        XCTAssertTrue(restored.tabs.allSatisfy { $0.webView.url == nil })
        window.rootViewController = restored
        restored.view.layoutIfNeeded()
        try await waitForPage(restored.webView)
        XCTAssertTrue(restored.isPanelOpen, "A fresh launch opens New Page above the restored session")
        XCTAssertEqual(restored.bottomBar.panel, .search)
        restored.closePanel()
        XCTAssertEqual(restored.webView.url, second)
        XCTAssertEqual(fixture.pageRequests, requests+1, "Only the selected tab should load at launch")
        XCTAssertNil(restored.tabs[0].webView.url)
        XCTAssertNil(restored.tabs[2].webView.url)
        restored.saveSession(flush: true)
        XCTAssertEqual(restoredStore.load()?.tabs[0], saved.tabs[0], "Saving must not erase an unloaded tab")
        XCTAssertEqual(restoredStore.load()?.tabs[2], saved.tabs[2])
        try await select(0, in: restored)
        try await waitForPage(restored.webView)
        XCTAssertEqual(restored.webView.url, saved.tabs[0].url)
        XCTAssertEqual(fixture.pageRequests, requests+2)
    }

    @MainActor func testClosingTabsPersistsTheSurvivingSelectionAndDoesNotReopenClosedTabs() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let store = store()
        let entries = (0..<3).map { MobileBrowserSession.Tab(url: URL(string: fixture.url.absoluteString+"#tab\($0)"), title: "Tab \($0)") }
        store.save(MobileBrowserSession(tabs: entries, selectedTabID: entries[1].id)); store.flush()
        let browser = BrowserViewController(sessionStore: store), window = try host(browser)
        defer { window.isHidden = true }
        try await waitForPage(browser.webView)
        browser.showTabSwitcher()
        browser.tabSwitcher.onClose(0)
        browser.saveSession(flush: true)
        XCTAssertEqual(browser.tabIndex, 0)
        XCTAssertEqual(store.load()?.selectedTabID, entries[1].id)
        browser.tabSwitcher.onClose(0)
        try await waitForPage(browser.webView)
        browser.saveSession(flush: true)
        XCTAssertEqual(store.load()?.tabs.map(\.id), [entries[2].id])
        XCTAssertEqual(store.load()?.selectedTabID, entries[2].id)
        browser.tabSwitcher.onClose(0)
        XCTAssertEqual(browser.tabs.count, 1, "The last tab's existing close behavior is preserved")
        let restored = BrowserViewController(sessionStore: MobileBrowserSessionStore(fileURL: store.fileURL))
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs[0].id, entries[2].id)
    }

    @MainActor func testPeekPagesStayTemporaryUntilAdoptedAndReturningBackIsSaved() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let store = store(), browser = BrowserViewController(startURL: fixture.url, sessionStore: store)
        let window = try host(browser)
        defer { window.isHidden = true }
        try await waitForPage(browser.webView)
        browser.saveSession(flush: true)
        let original = try XCTUnwrap(store.load())
        let destination = fixture.url.appendingPathComponent("replacement")
        let peek = BrowserViewController(startURL: destination, allowsPeek: false, sessionStore: store)
        peek.loadViewIfNeeded()
        try await waitForPage(peek.webView)
        peek.saveSession(flush: true)
        XCTAssertEqual(store.load(), original, "A temporary browser must not replace the main session")
        browser.adopt(peek.webView)
        browser.saveSession(flush: true)
        XCTAssertEqual(store.load()?.tabs.first?.url, destination)
        XCTAssertEqual(store.load()?.tabs.first?.id, original.tabs.first?.id)
        browser.returnToPreviousPage()
        browser.saveSession(flush: true)
        XCTAssertEqual(store.load()?.tabs.first?.url, fixture.url)
        XCTAssertEqual(store.load()?.tabs.count, 1)
    }
}
