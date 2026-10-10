import XCTest
import AppKit
import WebKit
@testable import Rise
@testable import RiseCore

final class SiteSearchLearningTests: XCTestCase {
    @MainActor private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor func testSearchingOnASiteTeachesTheAddressBarToSearchItWithTab() async throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer {
            browser.hidePalette(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
        }
        let tab = browser.addTab(), web = tab.webView
        // A site that shows its results in place, as YouTube and GitHub do, with the search in the address.
        web.loadHTMLString("""
        <!doctype html><meta property="og:site_name" content="Lamp Shop"><title>Lamps</title>
        <form><input name=user value=someone><input type=search name=find><button>Search</button></form>
        <script>document.querySelector('form').addEventListener('submit', event => {
          event.preventDefault(); history.pushState({}, '', '/results/?sort=new&term=' + encodeURIComponent(event.target.find.value))
        })</script>
        """, baseURL: URL(string: "https://lamps.example/"))
        try await waitUntil("Shop loaded") { !web.isLoading && web.title == "Lamps" }
        XCTAssertNil(browser.siteSearchLearner.searches.site(forAddress: "lamps.example"))
        _ = try await web.evaluateJavaScript("document.querySelector('[name=find]').value = 'desk lamp'; document.querySelector('form').requestSubmit(); location.href")
        try await waitUntil("Learned from the search") { browser.siteSearchLearner.searches.site(forAddress: "lamps.example") != nil }
        let site = try XCTUnwrap(browser.siteSearchLearner.searches.site(forAddress: "lamps.example"))
        XCTAssertEqual(site.name, "Lamp Shop")
        XCTAssertEqual(site.searchURL(for: "floor lamp")?.absoluteString, "https://lamps.example/results/?term=floor%20lamp")

        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("lamps.example", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.offeredSite?.name, "Lamp Shop", "The learned search is offered with Tab")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(palette.siteSearch?.name, "Lamp Shop")
        editor.insertText("floor lamp", replacementRange: editor.selectedRange())
        var opened: URL?
        palette.submit = { _, suggestion in opened = suggestion?.url }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened?.absoluteString, "https://lamps.example/results/?term=floor%20lamp")
    }
    @MainActor func testTypingASiteFillsInTheSiteNotItsLastPage() throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent()) }
        browser.browsingHistory.record(URL(string: "https://www.youtube.com/watch?v=Y0tR-1WUxCo")!, title: "It's Finally Happened")
        let youtube = try XCTUnwrap(browser.suggestions(for: "yout").first)
        XCTAssertEqual(youtube.completion, "youtube.com")
        XCTAssertEqual(youtube.title, "YouTube")
        browser.browsingHistory.record(URL(string: "https://szukaj.onet.pl/wyniki/?qt=atak")!, title: "atak - Szukaj w Onet.pl")
        let onet = try XCTUnwrap(browser.suggestions(for: "szu").first)
        XCTAssertEqual(onet.completion, "szukaj.onet.pl"); XCTAssertEqual(onet.url, URL(string: "https://szukaj.onet.pl/"))
        XCTAssertTrue(onet.isTypedAction)
        XCTAssertEqual(browser.suggestions(for: "youtube.com/w").first?.completion, "youtube.com/watch?v=Y0tR-1WUxCo")
    }
}
