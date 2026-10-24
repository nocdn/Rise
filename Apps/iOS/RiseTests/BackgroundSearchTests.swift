import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class BackgroundSearchTests: XCTestCase {
    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private func host() throws -> (BrowserViewController, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let browser = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
        browser.bottomBar.search.allowsRemoteSuggestions = false
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        browser.view.layoutIfNeeded()
        return (browser, window)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Resume search did not settle")
        throw NSError(domain: "BackgroundSearchTests", code: 1)
    }

    @MainActor private func resume(_ browser: BrowserViewController, after seconds: Int = 300) {
        let start = ContinuousClock().now
        browser.backgroundSearch.enteredBackground(at: start)
        browser.backgroundSearch.becameActive(at: start.advanced(by: .seconds(seconds))) { [weak browser] in
            browser?.reopenSearchAfterInactivity()
        }
    }

    @MainActor func testFiveMinuteBoundaryAndShortReturnsConsumeTheAbsence() async {
        let policy = BackgroundSearch(), start = ContinuousClock().now
        var openings = 0
        policy.becameActive(at: start.advanced(by: .seconds(3600))) { openings += 1 }
        policy.enteredBackground(at: start)
        policy.becameActive(at: start.advanced(by: .milliseconds(299_999))) { openings += 1 }
        await drainMainQueue()
        XCTAssertEqual(openings, 0)
        // Becoming active later without another background event must not reuse the old date.
        policy.becameActive(at: start.advanced(by: .seconds(3600))) { openings += 1 }
        await drainMainQueue()
        XCTAssertEqual(openings, 0)

        policy.enteredBackground(at: start)
        policy.becameActive(at: start.advanced(by: .seconds(300))) { openings += 1 }
        policy.becameActive(at: start.advanced(by: .seconds(301))) { openings += 1 }
        await drainMainQueue()
        XCTAssertEqual(openings, 1, "Exactly five minutes qualifies, once per return")
    }

    @MainActor func testExplicitIntentCancelsBeforeOrAfterActivationAndRebackgroundingCancelsQueuedWork() async {
        let policy = BackgroundSearch(), start = ContinuousClock().now
        var openings = 0
        policy.enteredBackground(at: start)
        policy.cancel()
        policy.becameActive(at: start.advanced(by: .seconds(300))) { openings += 1 }
        policy.enteredBackground(at: start)
        policy.becameActive(at: start.advanced(by: .seconds(300))) { openings += 1 }
        policy.cancel()
        await drainMainQueue()
        XCTAssertEqual(openings, 0)

        policy.enteredBackground(at: start)
        policy.becameActive(at: start.advanced(by: .seconds(300))) { openings += 1 }
        policy.enteredBackground(at: start.advanced(by: .seconds(301)))
        await drainMainQueue()
        XCTAssertEqual(openings, 0, "Do not open the keyboard after returning to the background")
        policy.becameActive(at: start.advanced(by: .seconds(601))) { openings += 1 }
        await drainMainQueue()
        XCTAssertEqual(openings, 1)
    }

    @MainActor func testLongReturnOpensSearchOverTheSamePageWithoutCreatingATabOrLosingScroll() async throws {
        let (browser, window) = try host()
        defer { window.isHidden = true }
        let page = browser.webView, ids = browser.tabs.map(\.id)
        page.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='height:5000px'>Keep this page</body>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete", !page.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await page.evaluateJavaScript("window.scrollTo(0, 700)")
        let initialOffset = try await page.evaluateJavaScript("window.scrollY") as? Double
        let offset = try XCTUnwrap(initialOffset)
        XCTAssertGreaterThan(offset, 100)
        resume(browser)
        try await wait { browser.isPanelOpen && browser.bottomBar.search.field.isFirstResponder }
        XCTAssertEqual(browser.bottomBar.panel, .search)
        XCTAssertEqual(browser.tabs.map(\.id), ids)
        XCTAssertTrue(browser.webView === page)
        let resumedOffset = try await page.evaluateJavaScript("window.scrollY") as? Double
        let after = try XCTUnwrap(resumedOffset)
        XCTAssertEqual(after, offset, accuracy: 1)
        browser.closePanel()
        XCTAssertTrue(browser.webView === page)
        XCTAssertEqual(browser.tabs.map(\.id), ids)
    }

    @MainActor func testOpenSearchPreservesDraftSelectionAndPrivateMode() async throws {
        let (browser, window) = try host()
        defer { window.isHidden = true }
        browser.openPanel(privateBrowsing: true)
        let search = browser.bottomBar.search, field = search.field
        field.insertText("unfinished search")
        let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 3))
        let end = try XCTUnwrap(field.position(from: start, offset: 5))
        field.selectedTextRange = field.textRange(from: start, to: end)
        browser.prepareForInactivity()
        field.resignFirstResponder()
        resume(browser, after: 3600)
        try await wait { field.isFirstResponder }
        XCTAssertEqual(field.text, "unfinished search")
        XCTAssertTrue(search.isPrivateBrowsing)
        let selected = try XCTUnwrap(field.selectedTextRange)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: selected.start), 3)
        XCTAssertEqual(field.offset(from: selected.start, to: selected.end), 5)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    @MainActor func testIncomingLinksTakePriorityOnEitherSideOfActivation() async throws {
        for arrivesBeforeActivation in [true, false] {
            let (browser, window) = try host()
            defer { window.isHidden = true }
            let start = ContinuousClock().now, url = URL(string: "https://resume-link.invalid/article")!
            browser.backgroundSearch.enteredBackground(at: start)
            if arrivesBeforeActivation { browser.openLinks([url]) }
            browser.backgroundSearch.becameActive(at: start.advanced(by: .seconds(300))) { [weak browser] in
                browser?.reopenSearchAfterInactivity()
            }
            if !arrivesBeforeActivation { browser.openLinks([url]) }
            await drainMainQueue()
            XCTAssertFalse(browser.isPanelOpen)
            XCTAssertEqual(browser.tabs.count, 2)
            XCTAssertEqual(browser.tabs.last?.sessionTab.url, url)
        }
    }

    @MainActor func testShortcutsSuppressAutomaticSearchBeforeAndAfterActivation() async throws {
        for action in HomeScreenAction.allCases {
            for arrivesBeforeActivation in [true, false] {
                let (browser, window) = try host()
                defer { window.isHidden = true }
                let start = ContinuousClock().now
                var automaticOpenings = 0
                browser.backgroundSearch.enteredBackground(at: start)
                if arrivesBeforeActivation { browser.quickActions.open(action) }
                browser.backgroundSearch.becameActive(at: start.advanced(by: .seconds(300))) { automaticOpenings += 1 }
                if !arrivesBeforeActivation { browser.quickActions.open(action) }
                await drainMainQueue()
                XCTAssertEqual(automaticOpenings, 0)
                XCTAssertEqual(browser.bottomBar.panel, action == .downloads ? .downloads : action == .history ? .history : .search)
                if action == .newPrivateTab { XCTAssertTrue(browser.bottomBar.search.isPrivateBrowsing) }
            }
        }
    }

    @MainActor func testReturnFromMoreAndTabSwitcherUsesExistingTransitionsAndKeepsSelection() async throws {
        for fromTabs in [false, true] {
            let (browser, window) = try host()
            defer { window.isHidden = true }
            let ids = browser.tabs.map(\.id)
            if fromTabs { browser.showTabSwitcher() } else { browser.openPanel(.menu) }
            try await Task.sleep(for: .milliseconds(500))
            resume(browser)
            try await wait { browser.isPanelOpen && browser.bottomBar.panel == .search && browser.bottomBar.search.field.isFirstResponder }
            XCTAssertEqual(browser.tabs.map(\.id), ids)
            XCTAssertEqual(browser.tabIndex, 0)
            XCTAssertTrue(browser.tabSwitcher.isHidden)
        }
    }

    @MainActor func testLinkWhileMoreClosesCancelsDeferredSearch() async throws {
        let (browser, window) = try host()
        defer { window.isHidden = true }
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(500))
        resume(browser)
        await drainMainQueue() // Automatic reopening is now waiting for More to close.
        let url = URL(string: "https://resume-link.invalid/late")!
        browser.openLinks([url])
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(browser.isPanelOpen)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.tabs.last?.sessionTab.url, url)
    }

    @MainActor func testBackgroundingDuringPanelClosureCancelsThePreviousReturn() async throws {
        let (browser, window) = try host()
        defer { window.isHidden = true }
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(500))
        resume(browser)
        await drainMainQueue()
        browser.prepareForInactivity()
        let start = ContinuousClock().now
        browser.backgroundSearch.enteredBackground(at: start)
        browser.backgroundSearch.becameActive(at: start.advanced(by: .seconds(1))) { [weak browser] in
            browser?.reopenSearchAfterInactivity()
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(browser.isPanelOpen, "An earlier long absence must not reopen search on a short return")
        XCTAssertFalse(browser.bottomBar.search.field.isFirstResponder)
    }
}
