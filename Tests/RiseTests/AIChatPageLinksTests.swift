import XCTest
import WebKit
@testable import Rise

/// A WebKit page standing in for Rise's engine page: the scripts are plain DOM.
@MainActor private final class WebKitPage: NSObject, ScriptablePage, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
    private var loaded: CheckedContinuation<Void, Never>?
    var url: URL? { view.url }
    var title: String? { view.title }
    func runScript(_ body: String, arguments: [String: Any], world: String?) async throws -> Any? {
        try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world.map { WKContentWorld.world(name: $0) } ?? .defaultClient)
    }
    func load(_ html: String, base: String) async {
        view.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            view.loadHTMLString(html, baseURL: URL(string: base))
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
}

@MainActor final class AIChatPageLinksTests: XCTestCase {
    func testAPageGivesWhereItsLinksGoOnceEachSkippingItselfAndOtherSchemes() async throws {
        let page = WebKitPage()
        await page.load("""
        <nav style="display:none"><a href="/pricing">Pricing</a></nav>
        <a href="/pricing#plans">Plans
           and   prices</a>
        <a href="#top">Top</a><a href="https://site.test/a">This page</a>
        <a href="mailto:hi@site.test">Email</a><a href="javascript:void 0">Nothing</a>
        <a href="https://docs.site.test/start"><img alt=""></a>
        <a href="https://docs.site.test/start" aria-label="Get started"><img alt=""></a>
        """, base: "https://site.test/a")
        let links = await PageAssistant.links(of: page)
        XCTAssertEqual(links, [.init(text: "Pricing", url: "https://site.test/pricing"),
                               .init(text: "Get started", url: "https://docs.site.test/start")])
    }

    func testAPageFillingInAfterItsLoadIsReadOnceItStopsChanging() async throws {
        let page = WebKitPage()
        await page.load("""
        <p>Loading…</p>
        <script>setTimeout(() => { document.body.insertAdjacentHTML('beforeend', '<table><tr><td>Pro</td><td>$20</td></tr></table>') }, 900)</script>
        """, base: "https://site.test/pricing")
        let start = Date()
        await AIChatPageReader.settle(page)
        let text = try await page.runScript("return document.body.innerText", arguments: [:], world: nil) as? String
        XCTAssertTrue(text?.contains("$20") == true, text ?? "")
        XCTAssertLessThan(Date().timeIntervalSince(start), AIChatPageReader.settleLimit)
    }

    func testTheModelGetsAPagesLinksWithItAttachedOrRead() {
        var page = PageAssistant.Page(title: "Site", url: "https://site.test", selection: "", text: "Welcome.")
        page.links = [.init(text: "Pricing", url: "https://site.test/pricing")]
        XCTAssertEqual(AIChatPrompt.context([page]),
                       "<page>\nTitle: Site\nURL: https://site.test\n\nWelcome.\n\nLinks on the page (text: address):\n- Pricing: https://site.test/pricing\n</page>")
        XCTAssertTrue(AIChatBrowserTools.describe(page, offset: 0, more: "read_url").contains("- Pricing: https://site.test/pricing\n</page>"))
        XCTAssertFalse(AIChatBrowserTools.describe(page, offset: 3, more: "read_url").contains("Links on the page"), "Only with the first part")
    }
}
