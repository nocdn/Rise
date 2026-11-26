import XCTest
import UIKit
import WebKit
@testable import RiseiOS

@MainActor final class PaywallBypassTests: XCTestCase {
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for WebKit", file: file, line: line)
    }

    private func display(_ selector: String, in page: WKWebView) async -> String? {
        try? await page.evaluateJavaScript("getComputedStyle(document.querySelector('\(selector)')).display") as? String
    }

    func testSitePreferencePersistsAndPrivateModeIsIndependent() {
        let suite = "Rise.PaywallBypass.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let regular = MobilePaywallBypass(preferences: defaults)
        let privateMode = MobilePaywallBypass(preferences: nil)
        let site = URL(string: "https://www.example.org./article")!
        let bare = URL(string: "https://example.org/another")!
        XCTAssertFalse(regular.isEnabled(for: site))
        regular.setEnabled(true, for: site)
        XCTAssertTrue(MobilePaywallBypass(preferences: defaults).isEnabled(for: bare))
        XCTAssertFalse(regular.isEnabled(for: URL(string: "https://account.example.org/")))
        XCTAssertFalse(privateMode.isEnabled(for: bare))
        privateMode.setEnabled(true, for: bare)
        XCTAssertTrue(privateMode.isEnabled(for: site))
        XCTAssertFalse(MobilePaywallBypass(preferences: nil).isEnabled(for: bare))
        regular.setEnabled(false, for: bare)
        XCTAssertFalse(regular.isEnabled(for: site))
        XCTAssertTrue(privateMode.isEnabled(for: site))
        XCTAssertFalse(regular.isAvailable(for: URL(string: "file:///article.html")))
        XCTAssertFalse(regular.isAvailable(for: URL(string: "about:blank")))
        XCTAssertFalse(regular.isAvailable(for: nil))
    }

    func testUnrelatedPagesSkipWebKitAfterBypassHasBeenUsedInTheTab() {
        let bypass = MobilePaywallBypass(preferences: nil)
        let page = WKWebView()
        let newTab = WKWebView()
        let site = URL(string: "https://www.foxnews.com/article")!
        let unrelated = URL(string: "https://example.org/article")!

        XCTAssertNil(bypass.stylesheetUpdate(for: site, in: page))
        bypass.setEnabled(true, for: site)
        XCTAssertNotNil(bypass.stylesheetUpdate(for: site, in: page))
        XCTAssertNil(bypass.stylesheetUpdate(for: unrelated, in: page))
        bypass.setEnabled(false, for: site)
        XCTAssertEqual(bypass.stylesheetUpdate(for: site, in: page), "")
        XCTAssertNil(bypass.stylesheetUpdate(for: site, in: newTab))
    }

    func testNativeSwitchReloadsInBothDirectionsAndWorksUnderCSP() async throws {
        let server = try AdBlockHTTPFixture()
        try await server.start()
        defer { server.stop() }
        let url = server.url.appendingPathComponent("paywall")
        let suite = "Rise.PaywallBypass.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let blocker = MobileAdBlocker(preferences: defaults)
        let browser = BrowserViewController(startURL: nil, adBlocker: blocker)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let page = browser.webView
        page.load(URLRequest(url: url))
        try await waitUntil { !page.isLoading && page.url == url }
        browser.openPanel(.menu)
        browser.openSiteSettings()
        let panel = browser.bottomBar.siteSettings
        let toggle = try XCTUnwrap(panel.switches.first { $0.accessibilityLabel == "Bypass paywall" })
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertFalse(toggle.isOn)
        let initial = await display("[data-paywall]", in: page)
        XCTAssertEqual(initial, "block")
        for enabled in [true, false] {
            let requests = server.requestCount(for: "/paywall")
            toggle.setOn(enabled, animated: false)
            toggle.sendActions(for: .valueChanged)
            try await waitUntil { !page.isLoading && server.requestCount(for: "/paywall") > requests }
            try await waitUntil { await self.display("[data-paywall]", in: page) == (enabled ? "none" : "block") }
            let unrelated = await display("#other", in: page)
            XCTAssertEqual(unrelated, "block")
            let lastParagraph = try await page.evaluateJavaScript("document.querySelector('article p:last-child').innerText") as? String
            XCTAssertEqual(lastParagraph, "Last paragraph")
            XCTAssertEqual(blocker.paywallBypass.isEnabled(for: url), enabled)
            XCTAssertTrue(browser.isPanelOpen)
        }

        // The same page in another host's site policy must keep the overlay.
        var otherSiteParts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        otherSiteParts.host = "localhost"
        let otherSite = try XCTUnwrap(otherSiteParts.url)
        blocker.paywallBypass.setEnabled(true, for: url)
        page.load(URLRequest(url: url))
        try await waitUntil { await self.display("[data-paywall]", in: page) == "none" }
        page.load(URLRequest(url: url.appendingPathComponent("redirect")))
        try await waitUntil { !page.isLoading && page.url == otherSite }
        let otherSiteGate = await display("[data-paywall]", in: page)
        XCTAssertEqual(otherSiteGate, "block")
        blocker.paywallBypass.setEnabled(false, for: url)
        XCTAssertNotNil(page.goBack())
        try await waitUntil { !page.isLoading && page.url == url }
        try await waitUntil { await self.display("[data-paywall]", in: page) == "block" }
    }

    func testLateWallsPaywallTeasersAndUnrelatedSites() async throws {
        let rules = MobilePaywallBypass(preferences: nil)
        let page = WKWebView()
        let fox = URL(string: "https://www.foxnews.com/rise-fixture")!
        rules.setEnabled(true, for: fox)
        let markup = """
        <!doctype html><article><p>Teaser</p></article>
        <div role="dialog" data-paywall>Subscribe</div>
        <div class="article-gating-wrapper">Publisher gate</div>
        <div class="gated-overlay" style="max-height:1px;overflow:hidden;filter:blur(10px)">Already loaded</div>
        """
        page.loadHTMLString(markup, baseURL: fox)
        try await waitUntil { !page.isLoading && page.url == fox }
        rules.apply(to: page)
        try await waitUntil { await self.display(".article-gating-wrapper", in: page) == "none" }
        let articleStyle = try await page.evaluateJavaScript("""
            (() => {
                const style = getComputedStyle(document.querySelector('.gated-overlay'));
                return [style.maxHeight, style.overflow, style.filter];
            })()
            """) as? [String]
        XCTAssertEqual(articleStyle, ["none", "visible", "none"])
        let teaserGate = await display("[data-paywall]", in: page)
        XCTAssertEqual(teaserGate, "block")
        _ = try await page.evaluateJavaScript("""
            document.querySelector('article').insertAdjacentHTML('beforeend', '<p>Second</p><p>Third</p>');
            document.querySelector('[data-paywall]').remove();
            document.documentElement.style.overflow = 'hidden';
            document.body.insertAdjacentHTML('beforeend', '<div data-testid="paywall-overlay">Late overlay</div>');
            """)
        try await waitUntil { await self.display("[data-testid=paywall-overlay]", in: page) == "none" }
        let unlocked = try await page.evaluateJavaScript("getComputedStyle(document.documentElement).overflow") as? String
        XCTAssertEqual(unlocked, "auto")
        rules.setEnabled(false, for: fox)
        rules.apply(to: page)
        try await waitUntil { await self.display("[data-testid=paywall-overlay]", in: page) == "block" }

        let unrelated = URL(string: "https://foxnews.com.example.org/rise-fixture")!
        rules.setEnabled(true, for: unrelated)
        page.loadHTMLString(markup, baseURL: unrelated)
        try await waitUntil { !page.isLoading && page.url == unrelated }
        rules.apply(to: page)
        let otherSiteGate = await display(".article-gating-wrapper", in: page)
        XCTAssertEqual(otherSiteGate, "block")
        XCTAssertFalse(MobilePaywallBypass.stylesheet(for: unrelated.host!).contains(".article-gating-wrapper"))
        XCTAssertTrue(MobilePaywallBypass.stylesheet(for: "m.foxnews.com.").contains(".article-gating-wrapper"))
    }
}
