import XCTest
import AppKit
import WebKit
@testable import Rise

@MainActor private final class NavigationProbe: NSObject, WKNavigationDelegate {
    var finished: (() -> Void)?
    var failed: ((Error) -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed?(error) }
}
final class WebKitSmokeTests: XCTestCase {
    @MainActor func testBrowserIdentityAdvertisesSafariCompatibilityForNormalAndSuppliedConfigurations() async throws {
        _ = NSApplication.shared
        for configuration in [nil, WKWebViewConfiguration()] as [WKWebViewConfiguration?] {
            let tab = BrowserTab(configuration: configuration)
            let value = try await tab.webView.evaluateJavaScript("navigator.userAgent")
            let identity = try XCTUnwrap(value as? String)
            XCTAssertTrue(identity.contains("Macintosh"))
            XCTAssertTrue(identity.contains("AppleWebKit/"))
            XCTAssertTrue(identity.contains("Version/"))
            XCTAssertTrue(identity.contains("Safari/"))
            XCTAssertTrue(identity.contains("Rise/1.0"))
            XCTAssertTrue(tab.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        }
    }
    @MainActor func testWebKitLoadsLocalHTMLAndExecutesJavaScript() throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let probe = NavigationProbe(); web.navigationDelegate = probe
        let loaded = expectation(description: "WebKit loads and executes page script")
        probe.finished = {
            web.evaluateJavaScript("({title: document.title, sum: 21 * 2})") { value, error in
                XCTAssertNil(error)
                let object = value as? [String: Any]
                XCTAssertEqual(object?["title"] as? String, "Rise WebKit")
                XCTAssertEqual(object?["sum"] as? Int, 42)
                loaded.fulfill()
            }
        }
        probe.failed = { error in XCTFail(error.localizedDescription); loaded.fulfill() }
        web.loadHTMLString("<!doctype html><title>Rise WebKit</title><p>Native WebKit rendering</p>", baseURL: nil)
        wait(for: [loaded], timeout: 15)
        web.stopLoading()
    }
}
