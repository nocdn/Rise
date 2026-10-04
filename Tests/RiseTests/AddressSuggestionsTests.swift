import XCTest
import AppKit
import RiseCore
@testable import Rise

final class AddressSuggestionsTests: XCTestCase {
    @MainActor func testTypedAddressReusesTheFaviconOfAnOpenPageOnTheSameOrigin() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://calendar.example/other")!
        tab.favicon = NSImage(size: NSSize(width: 16, height: 16))
        let suggestion = try XCTUnwrap(browser.suggestions(for: "calendar.example").first)
        XCTAssertEqual(suggestion.url, URL(string: "https://calendar.example"))
        XCTAssertTrue(suggestion.favicon === tab.favicon)
        XCTAssertNil(suggestion.tabID, "Entering an address still navigates, rather than switching to a different path")
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad(); $0.iconTask?.cancel() }
        browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testSuggestionsUseRealUntintedIconsAndKeepThemAfterClosingTheTabAndRelaunching() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/docs")!; tab.rename("Docs")
        tab.iconOrigin = SitePermissions.origin(tab.url)
        tab.favicon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in NSColor.systemBlue.setFill(); bounds.fill(); return true }
        browser.suggestionFavicons.remember(tab)
        browser.browsingHistory.record(tab.url!, title: "Docs")
        let suggestion = try XCTUnwrap(browser.suggestions(for: "ex").first)
        XCTAssertEqual(suggestion.tabID, tab.id); XCTAssertNotNil(suggestion.favicon)
        browser.newTab()
        let image = try XCTUnwrap(browser.palette.buttons.first?.subviews.first as? NSImageView)
        XCTAssertNotNil(image.image); XCTAssertNil(image.contentTintColor)
        browser.hidePalette(); browser.closeTab(tab.id); browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.suggestionFavicons.cancel(); restored.saveWork?.cancel(); restored.window?.orderOut(nil) }
        XCTAssertNotNil(restored.suggestions(for: "ex").first?.favicon)
        XCTAssertEqual(restored.suggestions(for: "ex").first?.completion, "example.com/docs")
    }
    @MainActor func testNativeInlineCompletionSelectsOnlySuffixSupportsTypingDeletionAndArrowSelection() throws {
        let browser = browser(); defer { clean(browser) }
        browser.browsingHistory.record(URL(string: "https://example.com/docs")!, title: "Docs")
        browser.browsingHistory.record(URL(string: "https://toggle.example/docs")!, title: "Other docs")
        XCTAssertEqual(browser.suggestions(for: "tog").first?.completion, "toggle.example/docs", "A matching command must not displace a learned URL prefix")
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("ex", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "example.com/docs")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 14))
        editor.insertText("a", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "example.com/docs")
        XCTAssertEqual(editor.selectedRange().location, 3)
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(editor.string, "exa", "Deleting the suffix must not immediately add it again")
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(editor.string, "ex")
        editor.insertText("a", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "example.com/docs")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(editor.string, "exa")
        XCTAssertEqual(palette.selectedIndex, 1)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(palette.isPresented)
    }
    @MainActor func testActualWebKitFinishRecordsVisitsButTypingPrefetchAndFailuresDoNotAndResetPersists() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab()
        tab.webView.loadHTMLString("<title>Learned page</title><p>Hello</p>", baseURL: URL(string: "https://example.com/docs"))
        let deadline = Date().addingTimeInterval(8)
        while browser.browsingHistory.entries.first?.title != "Learned page" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(browser.browsingHistory.entries.first?.visits, 1)
        XCTAssertEqual(browser.browsingHistory.entries.first?.title, "Learned page")
        _ = browser.suggestions(for: "unvisited.example")
        XCTAssertEqual(browser.browsingHistory.entries.count, 1)
        browser.saveNow()
        XCTAssertEqual(BrowsingHistory(storageURL: browser.browsingHistory.storageURL).entries, browser.browsingHistory.entries)
        try browser.clearBrowsingHistory()
        XCTAssertTrue(BrowsingHistory(storageURL: browser.browsingHistory.storageURL).entries.isEmpty)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertNil(browser.suggestions(for: "ex").first?.completion)
        XCTAssertNotNil(browser.makeMoreSiteMenu().items.first { $0.title == "Clear Browsing History…" })
    }
}
