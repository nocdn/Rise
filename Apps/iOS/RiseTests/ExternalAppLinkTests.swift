import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class ExternalAppLinkTests: XCTestCase {
    private static let invitation = URL(string: "itms-beta://testflight.apple.com/join/Ky55DFz5")!
    private static let source = URL(string: "https://testflight.apple.com/join/Ky55DFz5")!

    @MainActor func testAppSchemesExcludeWebDocumentsAndRiseRoutes() {
        for value in [Self.invitation.absoluteString, "mailto:hello@example.com", "tel:+441234567890", "some-app://open/item"] {
            XCTAssertTrue(BrowserViewController.isExternalAppURL(URL(string: value)!), value)
        }
        for value in [Self.source.absoluteString, "http://example.com", "about:blank", "data:text/html,hello",
                      "file:///tmp/page.html", "blob:https://example.com/id", "javascript:alert(1)",
                      "rise://open?url=https://example.com", "\(MobileTabHistory.scheme)://history", "/relative"] {
            XCTAssertFalse(BrowserViewController.isExternalAppURL(URL(string: value)!), value)
        }
    }

    @MainActor private func fixture(_ browser: BrowserViewController, body: String? = nil) async throws -> NavigationProbe {
        browser.loadViewIfNeeded()
        let probe = NavigationProbe(browser: browser)
        browser.webView.navigationDelegate = probe
        browser.webView.loadHTMLString("""
        <html><head><title>TestFlight invitation</title></head><body>
        \(body ?? "<a id='open' href='\(Self.invitation)' target='_self'>View in TestFlight</a>")
        </body></html>
        """, baseURL: Self.source)
        for _ in 0..<500 {
            if !browser.webView.isLoading,
               (try? await browser.webView.evaluateJavaScript("document.title")) as? String == "TestFlight invitation" { return probe }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "Rise.ExternalAppLinkTests.Fixture", code: 1)
    }

    @MainActor private func waitForAppLink(_ probe: NavigationProbe) async throws {
        for _ in 0..<200 {
            if probe.appPolicy != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fixture did not request an app link")
    }

    @MainActor func testTestFlightButtonHandsExactInvitationToIOSAndPreservesPage() async throws {
        let browser = BrowserViewController(startURL: nil)
        var opened: [URL] = []
        browser.openExternalURL = { url, completion in opened.append(url); completion(true) }
        let probe = try await fixture(browser)
        let originalURL = browser.webView.url
        try await browser.webView.evaluateJavaScript("document.getElementById('open').click()")
        try await waitForAppLink(probe)
        XCTAssertEqual(opened, [Self.invitation])
        XCTAssertEqual(probe.appPolicy, .cancel)
        XCTAssertEqual(browser.webView.url, originalURL)
        XCTAssertEqual(browser.tabs.count, 1)
        let title = try await browser.webView.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "TestFlight invitation")
        XCTAssertNil(browser.toast)
    }

    @MainActor func testMissingAppReportsFailureWithoutReplacingTheInvitation() async throws {
        let browser = BrowserViewController(startURL: nil)
        browser.openExternalURL = { _, completion in completion(false) }
        let probe = try await fixture(browser)
        let originalURL = browser.webView.url
        try await browser.webView.evaluateJavaScript("document.getElementById('open').click()")
        try await waitForAppLink(probe)
        XCTAssertEqual(probe.appPolicy, .cancel)
        XCTAssertEqual(browser.webView.url, originalURL)
        XCTAssertEqual(browser.toast?.accessibilityLabel, "Couldn't open this link")
    }

    @MainActor func testAutomaticScriptNavigationDoesNotLaunchAnApp() async throws {
        let browser = BrowserViewController(startURL: nil)
        var opened: [URL] = []
        browser.openExternalURL = { url, completion in opened.append(url); completion(true) }
        let probe = try await fixture(browser)
        try await browser.webView.evaluateJavaScript("location.href = '\(Self.invitation)'")
        try await waitForAppLink(probe)
        XCTAssertEqual(probe.appPolicy, .cancel)
        XCTAssertTrue(opened.isEmpty)
    }

    @MainActor func testNewWindowAppLinkDoesNotCreateBlankTabWhenPopupsAreAllowed() async throws {
        let browser = BrowserViewController(startURL: nil, adBlocker: MobileAdBlocker(preferences: nil))
        browser.adBlocker.popups.setEnabled(false, for: Self.source)
        var opened: [URL] = []
        browser.openExternalURL = { url, completion in opened.append(url); completion(true) }
        let probe = try await fixture(browser, body: "<a id='open' href='\(Self.invitation)' target='_blank'>View in TestFlight</a>")
        try await browser.webView.evaluateJavaScript("document.getElementById('open').click()")
        for _ in 0..<200 where opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        withExtendedLifetime(probe) {
            XCTAssertEqual(opened, [Self.invitation])
            XCTAssertEqual(browser.tabs.count, 1)
        }
    }

    @MainActor func testNewWindowAppLinkStillPassesPopupProtection() async throws {
        let browser = BrowserViewController(startURL: nil, adBlocker: MobileAdBlocker(preferences: nil))
        var opened: [URL] = []
        browser.openExternalURL = { url, completion in opened.append(url); completion(true) }
        let probe = try await fixture(browser, body: "<a id='open' href='\(Self.invitation)' target='_blank'>View in TestFlight</a>")
        try await browser.webView.evaluateJavaScript("document.getElementById('open').click()")
        try await waitForAppLink(probe)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(opened.isEmpty, "A synthetic click has no trusted popup activation")
        XCTAssertEqual(browser.tabs.count, 1)
    }
}

@MainActor private final class NavigationProbe: NSObject, WKNavigationDelegate {
    let browser: BrowserViewController
    var appPolicy: WKNavigationActionPolicy?
    init(browser: BrowserViewController) { self.browser = browser }

    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        browser.webView(page, decidePolicyFor: action) { [self] policy in
            if action.request.url?.scheme == "itms-beta" { appPolicy = policy }
            decisionHandler(policy)
        }
    }
}
