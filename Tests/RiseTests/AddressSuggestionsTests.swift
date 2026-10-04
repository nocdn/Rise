import XCTest
import AppKit
import RiseCore
@testable import Rise

final class AddressSuggestionsTests: XCTestCase {
    @MainActor func testPopupPaddingAndSearchIconDoNotDismissButOutsideClickDoes() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        for index in 0..<4 { browser.browsingHistory.record(URL(string: "https://example.com/\(index)")!, title: "Document \(index)") }
        browser.showWindow(nil)
        for createsTab in [false, true] {
            browser.paletteCreatesTab = createsTab; browser.showPalette(text: "")
            let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
            let selected = editor.selectedRange(), selectedResult = palette.selectedIndex
            let points = [NSPoint(x: 2, y: palette.bounds.midY), NSPoint(x: palette.bounds.maxX-2, y: palette.bounds.midY),
                NSPoint(x: palette.bounds.midX, y: 2), NSPoint(x: palette.bounds.midX, y: palette.bounds.maxY-2),
                NSPoint(x: palette.bounds.midX, y: AddressAppearance.headerHeight-2),
                NSPoint(x: palette.bounds.midX, y: palette.buttons[0].frame.maxY+AddressAppearance.rowSpacing/2),
                NSPoint(x: palette.leadingIcon.frame.midX, y: palette.leadingIcon.frame.midY)]
            for point in points {
                let position = palette.convert(point, to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: position, modifierFlags: [], timestamp: 0,
                    windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
                let hit = try XCTUnwrap(browser.root.hitTest(browser.root.superview!.convert(position, from: nil)))
                XCTAssertTrue(hit === palette || hit.isDescendant(of: palette))
                hit.mouseDown(with: event)
                browser.dismissArea.mouseDown(with: event) // Also reject any event forwarded to the dismissal surface.
                XCTAssertTrue(palette.isPresented, "Popup padding must keep the popup open at \(point)")
                XCTAssertTrue(palette.input.currentEditor() === editor)
                XCTAssertEqual(editor.selectedRange(), selected); XCTAssertEqual(palette.selectedIndex, selectedResult)
            }
            let outside = palette.convert(NSPoint(x: palette.bounds.maxX+12, y: 20), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: outside, modifierFlags: [], timestamp: 0,
                windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let hit = try XCTUnwrap(browser.root.hitTest(browser.root.superview!.convert(outside, from: nil)))
            XCTAssertTrue(hit === browser.dismissArea)
            hit.mouseDown(with: event)
            XCTAssertFalse(palette.isPresented, "An outside click still dismisses the popup")
        }
    }
    @MainActor func testLongAddressStaysOnOneLineAndScrollsWithoutTruncatingEditableText() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil)
        let address = "https://example.com/search?q=" + String(repeating: "long%20query%20", count: 30)
        browser.showPalette(text: address)
        let palette = browser.palette
        palette.place(at: NSPoint(x: 6, y: 48), width: 260)
        let editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        let manager = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        XCTAssertEqual(lines, 1, "A long address must never wrap in the native field editor")
        XCTAssertEqual(editor.string, address)
        XCTAssertTrue(editor.isDescendant(of: palette.input), "The fade must include the field editor as well as the resting text")
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollRangeToVisible(editor.selectedRange())
        palette.input.updateFade()
        XCTAssertNotNil(palette.input.layer?.mask, "Text beyond the right edge fades out")
        editor.setSelectedRange(NSRange(location: address.utf16.count, length: 0)); editor.scrollRangeToVisible(editor.selectedRange())
        palette.input.updateFade()
        XCTAssertGreaterThan(editor.visibleRect.minX, 0, "Keyboard caret movement scrolls horizontally")
        XCTAssertNil(palette.input.layer?.mask, "The final characters and caret remain readable at the end")
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        editor.insertText("X", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, String(address.dropLast()) + "X" + String(address.suffix(1)))
        var submitted: String?
        palette.submit = { text, _ in submitted = text }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted, editor.string, "Submitting keeps the entire edited URL")
    }
    @MainActor func testExpandedSuggestionsIncludeEightDistinctHistoryMatchesAndKeepCompletionPriority() throws {
        let browser = browser(); defer { clean(browser) }
        for index in 0..<12 {
            browser.browsingHistory.record(URL(string: "https://example.com/docs/\(index)")!, title: "Document \(index)")
        }
        let suggestions = browser.suggestions(for: "example.com/docs/")
        XCTAssertEqual(suggestions.count, 8)
        XCTAssertEqual(Set(suggestions.compactMap { BrowsingHistory.key($0.url) }).count, 8)
        XCTAssertTrue(try XCTUnwrap(suggestions.first?.completion).hasPrefix("example.com/docs/"))
        XCTAssertEqual(suggestions.filter { $0.title.hasPrefix("Document ") }.count, 7)
        XCTAssertTrue(suggestions.contains { $0.url?.absoluteString == "https://example.com/docs/" && $0.tabID == nil })
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/docs/0")!
        let focused = browser.suggestions(for: tab.url!.absoluteString)
        XCTAssertEqual(focused.count, 8)
        XCTAssertEqual(focused.first?.url, tab.url, "Opening the current URL must keep Enter pointed at that page")
        XCTAssertNil(focused.first?.tabID)
    }
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
    @MainActor func testMouseAndArrowKeysShareSelectionWithoutRebuildingRowsAndEnterUsesHoveredResult() throws {
        let browser = browser(); defer { clean(browser) }
        for index in 0..<3 {
            browser.browsingHistory.record(URL(string: "https://example.com/docs/\(index)")!, title: "Document \(index)")
        }
        browser.theme = .dark; browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("ex", replacementRange: editor.selectedRange())
        let rows = palette.buttons, frames = rows.map(\.frame), targetIndex = 2
        let target = rows[targetIndex].frame
        let point = palette.convert(NSPoint(x: target.midX, y: target.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        palette.mouseMoved(with: event)
        XCTAssertEqual(palette.selectedIndex, targetIndex)
        XCTAssertEqual(editor.string, "ex", "Hover removes the inline suffix without replacing the user's query")
        XCTAssertTrue(zip(rows, palette.buttons).allSatisfy { $0 === $1 })
        XCTAssertEqual(palette.buttons.map(\.frame), frames)
        let hoveredTitle = try XCTUnwrap(rows[targetIndex].subviews.last as? NSTextField)
        XCTAssertEqual(hoveredTitle.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor(hex: 0xFFFFFF))
        XCTAssertEqual(hoveredTitle.attributedStringValue.attribute(.foregroundColor, at: hoveredTitle.attributedStringValue.length-1, effectiveRange: nil) as? NSColor, RiseTheme.dark.muted)
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(palette.selectedIndex, targetIndex-1)
        palette.mouseMoved(with: event)
        XCTAssertEqual(palette.selectedIndex, targetIndex, "Moving within the same row hands selection back to the pointer")
        var submitted: URL?
        palette.submit = { _, suggestion in submitted = suggestion?.url }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted, palette.suggestions[targetIndex].url)
        rows[1].performClick(nil)
        XCTAssertEqual(submitted, palette.suggestions[1].url)
        palette.hide(); palette.mouseMoved(with: event)
        XCTAssertEqual(palette.selectedIndex, 1, "Hidden results ignore pointer events")
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
