import XCTest
import AppKit
import RiseCore
@testable import Rise

final class NavigationHistoryTests: XCTestCase {
    private let urls = ["http://127.0.0.1/a", "http://localhost/b", "http://127.0.0.1/c"]
    @MainActor private func makeBrowser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.syncedTabMetadata?.cancel()
        browser.tabs.forEach { browser.releaseHeldPages(of: $0); $0.cancelLoad() }
        browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testPortableAndNativeSessionsKeepBothDirectionsAndTheCursor() throws {
        let page = BlankPage(), tab = BrowserTab(page: page)
        urls.forEach { tab.load(URL(string: $0)!) }; page.goBack()
        let saved = tab.saved
        XCTAssertEqual(saved.navigationHistory?.entries.map(\.url), urls)
        XCTAssertEqual(saved.navigationHistory?.index, 1)
        for native in [true, false] {
            var value = saved; if !native { value.sessionState = nil }
            let restored = BrowserTab(saved: value)
            restored.load(URL(string: value.url)!)
            XCTAssertEqual(restored.url?.absoluteString, urls[1])
            XCTAssertTrue(restored.page.canGoBack); XCTAssertTrue(restored.page.canGoForward)
            restored.page.goBack(); XCTAssertEqual(restored.url?.absoluteString, urls[0])
            restored.page.goForward(); restored.page.goForward()
            XCTAssertEqual(restored.url?.absoluteString, urls[2])
            XCTAssertFalse(restored.page.canGoForward)
        }
    }
    @MainActor func testHistoryOnlySyncReplacesTheRouteWhileTitleOnlyUpdatesKeepTheLivePage() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let history = TabNavigationHistory(entries: urls.map { .init(url: $0) }, index: 1)
        let id = UUID()
        browser.applySharedTabs([SharedBrowserTab(id: id, url: urls[1], title: "B", navigationHistory: history)])
        let initial = try XCTUnwrap(browser.tabs.first { $0.id == id })
        let page = initial.page
        browser.applySharedTabs([SharedBrowserTab(id: id, url: urls[1], title: "Renamed", navigationHistory: history)])
        XCTAssertTrue(browser.tabs.first { $0.id == id }?.page === page)
        let changed = TabNavigationHistory(entries: history.entries + [.init(url: urls[1])], index: 3)
        browser.applySharedTabs([SharedBrowserTab(id: id, url: urls[1], title: "B again", navigationHistory: changed)])
        let replacement = try XCTUnwrap(browser.tabs.first { $0.id == id })
        XCTAssertFalse(replacement.page === page)
        XCTAssertEqual(replacement.saved.navigationHistory?.index, 3)
        XCTAssertEqual(replacement.saved.navigationHistory?.entries.map(\.url), urls+[urls[1]])
    }
    @MainActor func testPeekHistorySurvivesEvictingLivePagesAndReopening() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab(url: URL(string: urls[0])!)
        let addresses = (0..<6).map { "http://127.0.0.1/peek-\($0)" }
        for address in addresses {
            let peek = browser.configure(BrowserTab())
            peek.load(URL(string: address)!)
            browser.handOff(peek, into: tab)
        }
        let all = [urls[0]]+addresses
        XCTAssertEqual(tab.backPages.count, BrowserController.heldPageLimit)
        XCTAssertEqual(tab.saved.navigationHistory?.entries.map(\.url), all)
        XCTAssertNil(tab.saved.sessionState)
        for expected in all.dropLast().reversed() {
            browser.navigate(tab.page, .back)
            XCTAssertEqual(tab.url?.absoluteString, expected)
        }
        XCTAssertFalse(browser.canGo(.back, in: tab))
        let saved = tab.saved
        XCTAssertEqual(saved.navigationHistory?.index, 0)
        XCTAssertEqual(saved.navigationHistory?.entries.map(\.url), all)
        let restored = BrowserTab(saved: saved); restored.load(URL(string: saved.url)!)
        for expected in all.dropFirst() {
            restored.page.goForward(); XCTAssertEqual(restored.url?.absoluteString, expected)
        }
        restored.page.goBack(); restored.load(URL(string: "http://127.0.0.1/branch")!)
        XCTAssertFalse(restored.page.canGoForward)
    }
}
