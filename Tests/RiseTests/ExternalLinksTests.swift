import AppKit
import XCTest
@testable import Rise

@MainActor final class ExternalLinksTests: XCTestCase {
    private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.ExternalLinksTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let folder = URL.temporaryDirectory.appendingPathComponent(suite)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        addTeardownBlock { @MainActor in
            browser.closePeek(); browser.finishPeekMotion()
            for owner in Array(browser.suspendedPeeks.keys) { browser.discardPeek(for: owner) }
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        return browser
    }
    private func add(_ address: String, to browser: BrowserController) -> BrowserTab {
        let tab = browser.addTab(); tab.requestedURL = URL(string: address)!; return tab
    }

    func testExternalLinkSelectsTheExistingPageAndKeepsItsState() {
        let browser = browser(), url = URL(string: "https://example.com/account?view=all#details")!
        let existing = add(url.absoluteString, to: browser)
        existing.page.zoom = 1.5
        _ = add("https://other.example/", to: browser)
        XCTAssertTrue(browser.openExternalURL(url) === existing)
        XCTAssertEqual(browser.selectedID, existing.id)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(existing.page.zoom, 1.5, "The existing page is selected, not navigated again")
        XCTAssertTrue(browser.openExternalURL(url) === existing, "An already-selected tab is reused too")
        XCTAssertEqual(browser.tabs.count, 2)
    }

    func testOnlyEquivalentAddressesMatchNotOtherPathsQueriesFragmentsOrRequestPages() {
        let browser = browser()
        let root = add("https://example.com/", to: browser)
        XCTAssertTrue(browser.openExternalURL(URL(string: "https://EXAMPLE.com:443")!) === root)
        let urls = ["https://example.com/account", "https://example.com/?q=a", "https://example.com/#details",
                    "http://example.com/", "https://github.com/owner/repo/pull/1/files", "https://github.com/owner/repo/pull/1"]
        for address in urls {
            let count = browser.tabs.count, url = URL(string: address)!
            let tab = browser.openExternalURL(url)
            XCTAssertEqual(browser.tabs.count, count+1, address)
            XCTAssertEqual(tab.url, url)
            XCTAssertTrue(browser.openExternalURL(url) === tab)
            XCTAssertEqual(browser.tabs.count, count+1)
        }
    }

    func testExternalPreferenceDefaultsOnPersistsAndIsIndependentOfInPageClicks() throws {
        let browser = browser(), url = URL(string: "https://example.com/")!
        let original = add(url.absoluteString, to: browser)
        XCTAssertTrue(browser.openTabLinks.reusesExternalLinks)
        browser.setRiseSetting("goToOpenTabs", false)
        XCTAssertTrue(browser.openExternalURL(url) === original)
        browser.setRiseSetting("reuseExternalLinks", false)
        XCTAssertFalse(browser.openExternalURL(url) === original)
        XCTAssertEqual(browser.tabs.count, 2)
        let restored = OpenTabLinks(preferences: browser.preferences)
        XCTAssertFalse(restored.reusesExternalLinks)
        XCTAssertFalse(restored.enabled)
        browser.setRiseSetting("goToOpenTabs", true)
        XCTAssertFalse(restored.reusesExternalLinks)
        let row = try XCTUnwrap(browser.riseSettingRows("tabs").first { $0["key"] as? String == "reuseExternalLinks" })
        XCTAssertEqual(row["value"] as? Bool, false)
        browser.setRiseSetting("reuseExternalLinks", true)
        XCTAssertTrue(restored.reusesExternalLinks)
    }

    func testAppDelegateReusesRepeatedLinksInABatchAndShowsTheWindow() {
        let browser = browser(), delegate = AppDelegate(), url = URL(string: "https://example.com/new")!
        delegate.browser = browser
        delegate.application(NSApp, open: [url, url])
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.selectedTab?.url, url)
        XCTAssertTrue(browser.window?.isVisible == true)
    }

    func testAnUnrelatedPeekDoesNotCoverTheRequestedTabAndAMatchingPeekIsKept() throws {
        let browser = browser(), url = URL(string: "https://example.com/source")!
        let source = add(url.absoluteString, to: browser)
        browser.showPeek(url: URL(string: "https://example.com/peek")!, animated: false)
        let peek = try XCTUnwrap(browser.peekTab)
        XCTAssertTrue(browser.openExternalURL(peek.url!) === peek)
        XCTAssertTrue(browser.peekTab === peek)
        XCTAssertTrue(browser.openExternalURL(url) === source)
        XCTAssertNil(browser.peekTab, "The requested source page is visible")
        XCTAssertTrue(browser.peek(for: source.id) === peek, "The unrelated Peek's page is preserved")
        XCTAssertEqual(browser.tabs.count, 1)
    }
}
