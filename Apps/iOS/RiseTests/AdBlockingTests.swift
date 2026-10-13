import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class AdBlockingTests: XCTestCase {
    @MainActor private func blocker() -> MobileAdBlocker {
        let name = "Rise.AdBlock.Tests."+UUID().uuidString
        return MobileAdBlocker(preferences: UserDefaults(suiteName: name)!)
    }

    @MainActor private func waitForPage(_ page: WKWebView) async throws {
        for _ in 0..<1500 {
            if !page.isLoading, (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" {
                try await Task.sleep(for: .milliseconds(150)); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The WebKit fixture didn't complete")
    }

    @MainActor private func assertScript(_ expression: String, in page: WKWebView, equals expected: Bool?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await page.evaluateJavaScript(expression) as? Bool
        XCTAssertEqual(value, expected, expression, file: file, line: line)
    }
    @MainActor private func assertScript(_ expression: String, in page: WKWebView, equals expected: String?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await page.evaluateJavaScript(expression) as? String
        XCTAssertEqual(value, expected, expression, file: file, line: line)
    }

    @MainActor func testDefaultsPersistenceAndMandatoryYouTubePolicy() throws {
        let defaults = UserDefaults(suiteName: "Rise.AdBlock.Policy."+UUID().uuidString)!
        let filter = MobileAdBlocker(preferences: defaults)
        let site = URL(string: "https://www.example.com/path")!
        XCTAssertTrue(filter.isEnabled(for: site))
        filter.setEnabled(false, for: site)
        XCTAssertFalse(MobileAdBlocker(preferences: defaults).isEnabled(for: URL(string: "https://example.com/another")))
        XCTAssertTrue(filter.isEnabled(for: URL(string: "https://other.example.com/")))
        filter.setEnabled(true, for: site)
        XCTAssertTrue(filter.isEnabled(for: site))
        for host in ["youtube.com", "m.youtube.com", "music.youtube.com", "www.youtube.com.", "youtube-nocookie.com", "youtu.be", "www.youtubekids.com"] {
            let url = URL(string: "https://"+host+"/")!
            filter.setEnabled(true, for: url)
            XCTAssertTrue(MobileAdBlocker.isYouTube(url), host)
            XCTAssertFalse(filter.isEnabled(for: url), host)
        }
        for host in ["notyoutube.com", "youtube.com.example.org", "youtu.be.example.org"] {
            XCTAssertTrue(filter.isEnabled(for: URL(string: "https://"+host+"/")), host)
        }
    }

    @MainActor func testNativeFilteringSwitchReloadAndSpinner() async throws {
        let fixture = try AdBlockHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let filter = blocker()
        let browser = BrowserViewController(startURL: nil, adBlocker: filter)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        XCTAssertTrue(browser.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
        browser.webView.load(URLRequest(url: fixture.url))
        try await waitForPage(browser.webView)
        XCTAssertTrue(filter.isInstalled(on: browser.webView), "The actual bundled native lists compiled and installed")
        try await assertScript("window.normalLoaded", in: browser.webView, equals: true)
        try await assertScript("window.adLoaded", in: browser.webView, equals: nil as Bool?)
        // The upstream list exempts localhost from generic cosmetic hiding. Network
        // blocking still applies; cosmetic behavior is tested on a public-origin fixture.
        try await assertScript("getComputedStyle(document.querySelector('.ad-banner')).display", in: browser.webView, equals: "block")
        try await assertScript("document.querySelector('main').textContent", in: browser.webView, equals: "Normal article")
        let nonAdScripts = browser.webView.configuration.userContentController.userScripts.filter { !$0.source.hasPrefix(MobileAdBlocker.scriptMarker) }.map(\.source)
        XCTAssertFalse(nonAdScripts.isEmpty)
        browser.openPanel(.menu); browser.openSiteSettings()
        try await Task.sleep(for: .milliseconds(600))
        let panel = browser.bottomBar.siteSettings
        panel.switches[0].setOn(false, animated: false); panel.switches[0].sendActions(for: .valueChanged)
        XCTAssertTrue(panel.isUpdatingAdBlocking)
        XCTAssertFalse(panel.switches[0].isEnabled)
        for _ in 0..<1500 where panel.isUpdatingAdBlocking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(panel.isUpdatingAdBlocking)
        XCTAssertTrue(panel.switches[0].isEnabled)
        XCTAssertFalse(filter.isInstalled(on: browser.webView))
        try await assertScript("window.adLoaded", in: browser.webView, equals: true)
        try await assertScript("getComputedStyle(document.querySelector('.ad-banner')).display", in: browser.webView, equals: "block")
        XCTAssertEqual(browser.webView.configuration.userContentController.userScripts.map(\.source), nonAdScripts)
        panel.switches[0].setOn(true, animated: false); panel.switches[0].sendActions(for: .valueChanged)
        XCTAssertTrue(panel.isUpdatingAdBlocking)
        for _ in 0..<1500 where panel.isUpdatingAdBlocking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(panel.isUpdatingAdBlocking)
        XCTAssertTrue(filter.isInstalled(on: browser.webView))
        try await assertScript("window.adLoaded", in: browser.webView, equals: nil as Bool?)
        XCTAssertGreaterThanOrEqual(fixture.pageRequests, 3, "Both toggles reloaded the page behind the panel")
        XCTAssertTrue(browser.isPanelOpen)
        XCTAssertTrue(browser.bottomBar.shown === panel)
        browser.changeAdBlocking(false)
        for _ in 0..<100 where browser.adBlockingNavigation == nil { try await Task.sleep(for: .milliseconds(1)) }
        let replacement = fixture.url.appendingPathComponent("replacement")
        browser.webView.load(URLRequest(url: replacement))
        for _ in 0..<200 where panel.isUpdatingAdBlocking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(panel.isUpdatingAdBlocking, "An interrupted reload must also clear the native spinner")
        XCTAssertTrue(panel.switches[0].isEnabled)
        XCTAssertEqual(browser.webView.url, replacement)
        try await waitForPage(browser.webView)
        fixture.shouldFail = true
        browser.changeAdBlocking(true)
        for _ in 0..<1500 where panel.isUpdatingAdBlocking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(panel.isUpdatingAdBlocking, "A network failure also settles the spinner")
        XCTAssertTrue(panel.switches[0].isEnabled)
    }

    @MainActor func testCosmeticFilteringPreservesContentAndCanBeRemoved() async throws {
        let filter = blocker(), page = WKWebView()
        let url = URL(string: "https://example.com/")!
        let html = "<html><body><main>Normal article</main><div id='ad-slot-1'>Advertisement</div></body></html>"
        try await filter.prepare(page, for: url)
        page.loadHTMLString(html, baseURL: url); try await waitForPage(page)
        try await assertScript("getComputedStyle(document.getElementById('ad-slot-1')).display", in: page, equals: "none")
        try await assertScript("document.querySelector('main').textContent", in: page, equals: "Normal article")
        filter.setEnabled(false, for: url); try await filter.prepare(page, for: url)
        page.loadHTMLString(html, baseURL: url); try await waitForPage(page)
        try await assertScript("getComputedStyle(document.getElementById('ad-slot-1')).display", in: page, equals: "block")
    }

    @MainActor func testDocumentStartDetectorFixAndYouTubeScriptExclusion() async throws {
        let filter = blocker(), page = WKWebView()
        let html = """
        <html><body><main>Real content</main><script>
        window.showModal = () => 'detected'; window.modalResult = window.showModal();
        </script></body></html>
        """
        try await filter.prepare(page, for: URL(string: "https://reporterpb.com.br/"))
        page.loadHTMLString(html, baseURL: URL(string: "https://reporterpb.com.br/"))
        try await waitForPage(page)
        try await assertScript("window.modalResult", in: page, equals: nil as String?)
        try await filter.prepare(page, for: URL(string: "https://www.youtube.com/"))
        XCTAssertFalse(filter.isInstalled(on: page))
        XCTAssertFalse(page.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileAdBlocker.scriptMarker) })
        page.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/"))
        try await waitForPage(page)
        try await assertScript("window.modalResult", in: page, equals: "detected")
    }

    @MainActor func testYouTubeNativeExemptionsWithoutDelegateAndAdoptedPage() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start(); defer { fixture.stop() }
        let filter = blocker(), page = WKWebView()
        // Leave all lists installed deliberately: the fallback exclusions must work even
        // before a navigation callback can remove the catalog.
        try await filter.prepare(page, for: URL(string: "https://example.com/"))
        page.loadHTMLString(AdBlockHTTPFixture.html(scriptBase: fixture.url.absoluteString), baseURL: URL(string: "http://www.youtube.com/"))
        try await waitForPage(page)
        try await assertScript("window.adLoaded", in: page, equals: true)
        try await assertScript("getComputedStyle(document.querySelector('.ad-banner')).display", in: page, equals: "block")
        // A second browser owner can remove this catalog without removing other scripts.
        try await blocker().prepare(page, for: URL(string: "https://youtu.be/"))
        XCTAssertFalse(page.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileAdBlocker.scriptMarker) })
        try await filter.prepare(page, for: URL(string: "https://example.com/"))
        XCTAssertTrue(page.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileAdBlocker.scriptMarker) }, "The previous owner can reinstall after adoption")
    }
}
