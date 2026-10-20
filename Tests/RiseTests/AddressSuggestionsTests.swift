import XCTest
import AppKit
import RiseCore
@testable import Rise

final class AddressSuggestionsTests: XCTestCase {
    @MainActor func testCollapsedSidebarCentersPaletteAndTogglingDismissesBothModes() {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil)
        // New tab and the page's address alike: centred over the window, sidebar or not, and
        // toggling the sidebar closes it.
        for createsTab in [true, false] {
            for sidebar in [true, false] {
                if browser.sidebarVisible != sidebar { browser.toggleSidebar() }
                if createsTab { browser.newTab() } else { browser.focusAddress() }
                XCTAssertTrue(browser.palette.isPresented); XCTAssertTrue(browser.palette.isCentered)
                XCTAssertEqual(browser.palette.frame.midX, browser.root.bounds.midX, accuracy: 0.5)
                XCTAssertEqual(browser.palette.frame.minY, max(8, round(browser.root.bounds.midY-CenteredPaletteStyle.maximumHeight/2)), accuracy: 0.01)
                browser.toggleSidebar()
                XCTAssertFalse(browser.palette.isPresented); XCTAssertTrue(browser.dismissArea.isHidden)
            }
        }
    }

    @MainActor func testOpenTabsMatchTitlesWordsAndExactAddressesWithoutDuplicatingHistory() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://news.ycombinator.com/")!; tab.rename("Hacker News")
        browser.browsingHistory.record(tab.url!, title: "Old page title")
        browser.paletteCreatesTab = true
        for query in ["", "hacker", "news hacker", "news.ycombinator.com", "https://news.ycombinator.com/"] {
            let matches = browser.suggestions(for: query).filter { $0.tabID == tab.id }
            XCTAssertEqual(matches.count, 1, "An open tab should be suggested once for \(query)")
        }
        XCTAssertFalse(browser.suggestions(for: "news missingword").contains { $0.tabID == tab.id })
        XCTAssertNil(browser.suggestions(for: "news.ycombinator.com/newest").first?.tabID, "Sharing an origin does not make a different page a switch target")
        browser.paletteCreatesTab = false
        XCTAssertFalse(browser.suggestions(for: tab.url!.absoluteString).contains { $0.tabID == tab.id }, "Editing its own address, the page isn't offered again")
    }
    @MainActor func testCompletedAddressEnterAndClickReuseTheOpenTabWithoutABadge() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let existing = browser.addTab(); existing.requestedURL = URL(string: "https://news.ycombinator.com/")!; existing.rename("Hacker News")
        browser.browsingHistory.record(existing.url!, title: existing.title)
        let current = browser.addTab(); current.requestedURL = URL(string: "https://example.com/")!
        browser.showWindow(nil)
        let palette = browser.palette
        let count = browser.tabs.count
        for click in [false, true] {
            browser.select(current.id); browser.newTab()
            let editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
            editor.insertText("news.y", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "news.ycombinator.com")
            XCTAssertEqual(palette.suggestions.first?.tabID, existing.id)
            let row = try XCTUnwrap(palette.buttons.first)
            let text = try XCTUnwrap(row.subviews.last as? NSTextField)
            XCTAssertTrue(row.subviews.allSatisfy { $0 is NSImageView || $0 is NSTextField }, "Only the favicon, title and address: no badge")
            XCTAssertEqual(text.frame.maxX, row.bounds.maxX-CenteredPaletteStyle.rowPadding, "The text uses the space formerly reserved for the badge")
            if click { row.performClick(nil) }
            else { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
            XCTAssertEqual(browser.selectedID, existing.id); XCTAssertEqual(browser.tabs.count, count)
            XCTAssertFalse(palette.isPresented)
        }
        browser.newTab()
        palette.refresh(query: "hacker")
        let index = try XCTUnwrap(palette.suggestions.firstIndex { $0.tabID == existing.id })
        palette.selectResult(index)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: event))
        XCTAssertEqual(browser.selectedID, existing.id); XCTAssertEqual(browser.tabs.count, count)
        XCTAssertFalse(palette.isPresented)
        XCTAssertFalse(palette.handleKeyEquivalent(event), "The shortcut is inactive when the picker is closed")
        browser.newTab(); palette.refresh(query: "unrelated search")
        XCTAssertFalse(palette.handleKeyEquivalent(event), "A search result cannot switch to an unrelated tab")
        XCTAssertTrue(palette.isPresented)
    }
    @MainActor func testReuseRequiresTheExactDestinationAndChecksOpenTabsAtSubmission() throws {
        let browser = browser(); defer { clean(browser) }
        let existing = browser.addTab(); existing.requestedURL = URL(string: "https://example.com/docs?q=one#intro")!
        let other = browser.addTab(); other.requestedURL = URL(string: "https://other.example/")!
        XCTAssertTrue(browser.openTab(for: URL(string: "https://EXAMPLE.com:443/docs?q=one#intro")!) === existing)
        for address in ["https://example.com/other?q=one#intro", "https://example.com/docs?q=two#intro",
                        "https://example.com/docs?q=one#other", "https://example.com/docs?q=one",
                        "http://example.com/docs?q=one#intro"] {
            XCTAssertNil(browser.openTab(for: URL(string: address)!))
        }
        browser.paletteCreatesTab = true
        let count = browser.tabs.count
        browser.submitAddress(existing.url!.absoluteString, suggestion: nil)
        XCTAssertEqual(browser.selectedID, existing.id); XCTAssertEqual(browser.tabs.count, count)
        browser.select(other.id); browser.paletteCreatesTab = false
        browser.submitAddress(existing.url!.absoluteString, suggestion: nil)
        XCTAssertEqual(browser.selectedID, existing.id); XCTAssertEqual(browser.tabs.count, count)
    }
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
                NSPoint(x: palette.bounds.midX, y: palette.buttons[0].frame.minY-2),
                // Between rows; the new tab palette's have no gap, so below the last instead. A row
                // itself would track the press until a release that never comes.
                palette.isCentered ? NSPoint(x: palette.bounds.midX, y: palette.buttons.last!.frame.maxY+CenteredPaletteStyle.listPadding/2)
                    : NSPoint(x: palette.bounds.midX, y: palette.buttons[0].frame.maxY+AddressAppearance.rowSpacing/2),
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
        XCTAssertEqual(focused.count, 8, "Other destinations fill the list")
        XCTAssertFalse(focused.contains { $0.url == tab.url }, "Not the page whose address is being edited")
        XCTAssertFalse(focused.contains { $0.isTypedAction }, "Unchanged, the address has nothing for Enter to open but itself")
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
    @MainActor func testPaletteIsCentredWithKerosSearchGlyphForNewTabsAndTheAddressAlike() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.browsingHistory.record(URL(string: "https://weather.example/")!, title: "Weather")
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, glyph = CenteredPaletteStyle.searchIcon
        XCTAssertTrue(palette.isCentered)
        XCTAssertTrue(glyph.representations.first.map { "\(type(of: $0))".contains("SVG") } ?? false, "Kero's own glyph, not a stand-in")
        XCTAssertEqual(palette.frame.width, CenteredPaletteStyle.width)
        XCTAssertEqual(palette.frame.minY, max(8, round(browser.root.bounds.midY-CenteredPaletteStyle.maximumHeight/2)), "Centred at its tallest")
        XCTAssertTrue(palette.leadingIcon.image === glyph)
        let editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("weather", replacementRange: editor.selectedRange())
        let search = try XCTUnwrap(palette.suggestions.firstIndex { $0.symbol == "magnifyingglass" })
        XCTAssertTrue((palette.buttons[search].subviews.first as? NSImageView)?.image === glyph, "Search rows have the same glyph")
        // As in Kero, the pointer tints a row and leaves the choice where it was.
        let row = try XCTUnwrap(palette.buttons.first { $0.layer?.backgroundColor?.alpha == 0 }, "A row not already chosen"), picked = palette.selectedIndex
        palette.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: palette.convert(NSPoint(x: row.frame.midX, y: row.frame.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        XCTAssertEqual(palette.selectedIndex, picked)
        XCTAssertEqual(row.layer?.backgroundColor, CenteredPaletteStyle.hover(browser.theme).cgColor)
        browser.hidePalette(); browser.focusAddress()
        XCTAssertTrue(palette.isCentered); XCTAssertTrue(palette.leadingIcon.image === glyph, "⌘L is the same panel")
    }
    @MainActor func testNewTabArrowKeysMoveFromTheChosenRowAndComingBackFillsTheAddressInAgain() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        for _ in 0..<3 { browser.browsingHistory.record(URL(string: "https://news.ycombinator.com/")!, title: "Hacker News") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("news", replacementRange: editor.selectedRange())
        let filled = editor.string, filledRange = editor.selectedRange(), offer = palette.offeredSite?.name
        XCTAssertEqual(filled, "news.ycombinator.com"); XCTAssertEqual(offer, "Hacker News")
        func chosen() -> Int? { palette.buttons.firstIndex { $0.layer?.backgroundColor == CenteredPaletteStyle.selection(browser.theme).cgColor } }
        let resting = chosen()
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(chosen(), (resting ?? -1)+1, "One press moves to the next row")
        XCTAssertEqual(palette.selectedIndex, (resting ?? -1)+1); XCTAssertEqual(editor.string, "news")
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(chosen(), resting); XCTAssertEqual(palette.selectedIndex, -1)
        XCTAssertEqual(editor.string, filled, "Back where it was, the address fills in again")
        XCTAssertEqual(editor.selectedRange(), filledRange); XCTAssertEqual(palette.offeredSite?.name, offer)
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(chosen(), resting, "Nothing above it to move to")
    }
    @MainActor func testEscapeFromASiteSearchKeepsAFilledInPageOfferingTheSiteAgain() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let page = URL(string: "https://github.com/pingdotgg/t3code/pull/21819")!
        for _ in 0..<5 { browser.browsingHistory.record(page, title: "docs: explain which environment variables T3 Code reads") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("git", replacementRange: editor.selectedRange())
        let filled = editor.string, selection = editor.selectedRange()
        XCTAssertEqual(filled, "github.com/pingdotgg/t3code/pull/21819"); XCTAssertEqual(palette.offeredSite?.name, "GitHub")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(palette.siteSearch?.name, "GitHub")
        // Escape as the window takes it.
        XCTAssertTrue(try XCTUnwrap(browser.window as? BrowserWindow).escapeAction?() == true)
        let back = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        XCTAssertNil(palette.siteSearch); XCTAssertEqual(back.string, filled); XCTAssertEqual(back.selectedRange(), selection)
        XCTAssertEqual(palette.offeredSite?.name, "GitHub", "Its search is offered again")
        back.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(palette.siteSearch?.name, "GitHub", "And Tab searches it again")
    }
    @MainActor func testPressingTheSidebarAddressOpensThePaletteBeforeTheButtonComesUp() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil)
        if !browser.sidebarVisible { browser.toggleSidebar() }
        let address = browser.sidebar.address
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: address.convert(NSPoint(x: address.bounds.midX, y: address.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // A plain button would track the press here until a release, which never comes.
        address.mouseDown(with: down)
        XCTAssertTrue(browser.palette.isPresented); XCTAssertTrue(browser.palette.isCentered)
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
        let suggestions = browser.suggestions(for: "ex")
        XCTAssertEqual(suggestions.first?.url, URL(string: "https://example.com/"), "Typing a site's name fills in the site")
        XCTAssertNotNil(suggestions.first?.favicon, "The site shows its pages' icon")
        let suggestion = try XCTUnwrap(suggestions.first { $0.tabID == tab.id })
        XCTAssertNotNil(suggestion.favicon)
        browser.newTab()
        let image = try XCTUnwrap(browser.palette.buttons.first?.subviews.first as? NSImageView)
        XCTAssertNotNil(image.image); XCTAssertNil(image.contentTintColor)
        browser.hidePalette(); browser.closeTab(tab.id); browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.suggestionFavicons.cancel(); restored.saveWork?.cancel(); restored.window?.orderOut(nil) }
        XCTAssertNotNil(restored.suggestions(for: "ex").first?.favicon)
        XCTAssertEqual(restored.suggestions(for: "ex").first?.completion, "example.com")
        XCTAssertEqual(restored.suggestions(for: "example.com/").first?.completion, "example.com/docs", "Past the site, its pages fill in")
    }
    @MainActor func testNativeInlineCompletionSelectsOnlySuffixSupportsTypingDeletionAndArrowSelection() throws {
        let browser = browser(); defer { clean(browser) }
        browser.browsingHistory.record(URL(string: "https://example.com/docs")!, title: "Docs")
        browser.browsingHistory.record(URL(string: "https://toggle.example/docs")!, title: "Other docs")
        XCTAssertEqual(browser.suggestions(for: "tog").first?.completion, "toggle.example", "A matching command must not displace a learned URL prefix")
        XCTAssertEqual(browser.suggestions(for: "tog").first?.title, "toggle.example", "A site never opened by itself is named by its domain")
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("ex", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "example.com")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 9))
        editor.insertText("a", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "example.com")
        XCTAssertEqual(editor.selectedRange().location, 3)
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(editor.string, "exa", "Deleting the suffix must not immediately add it again")
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(editor.string, "ex")
        editor.insertText("a", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "example.com")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(editor.string, "exa")
        XCTAssertEqual(palette.selectedIndex, 1, "Down moves on from the row shown as chosen, the one filling in")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(palette.isPresented)
    }
    @MainActor func testPointerTintsRowsArrowKeysPickThemWithoutRebuildingAndEnterUsesThePick() throws {
        let browser = browser(); defer { clean(browser) }
        for index in 0..<3 {
            browser.browsingHistory.record(URL(string: "https://example.com/docs/\(index)")!, title: "Document \(index)")
        }
        browser.theme = .dark; browser.showWindow(nil); browser.focusAddress()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("ex", replacementRange: editor.selectedRange())
        let rows = palette.buttons, frames = rows.map(\.frame), typed = editor.string, targetIndex = 2
        let target = rows[targetIndex].frame
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: palette.convert(NSPoint(x: target.midX, y: target.midY), to: nil), modifierFlags: [],
                                                   timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        palette.mouseMoved(with: event)
        XCTAssertEqual(palette.selectedIndex, -1, "The pointer tints a row without picking it")
        XCTAssertEqual(editor.string, typed, "Nor does it take back what the field filled in")
        XCTAssertEqual(rows[targetIndex].layer?.backgroundColor, CenteredPaletteStyle.hover(.dark).cgColor)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:))); editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(palette.selectedIndex, targetIndex)
        XCTAssertTrue(zip(rows, palette.buttons).allSatisfy { $0 === $1 }, "Picking doesn't rebuild the rows")
        XCTAssertEqual(palette.buttons.map(\.frame), frames)
        var submitted: URL?
        palette.submit = { _, suggestion in submitted = suggestion?.url }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted, palette.suggestions[targetIndex].url)
        rows[1].performClick(nil)
        XCTAssertEqual(submitted, palette.suggestions[1].url)
        palette.hide(); palette.mouseMoved(with: event)
        XCTAssertEqual(palette.selectedIndex, 1, "Hidden results ignore pointer events")
    }
    @MainActor func testAFrequentlyVisitedPathFillsTheNativeFieldAndKeepsTheSitesSearchAvailable() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let account = URL(string: "https://amazon.co.uk/account")!
        browser.browsingHistory.record(URL(string: "https://amazon.co.uk/")!, title: "Amazon")
        for _ in 0..<10 { browser.browsingHistory.record(account, title: "Your account") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        for letter in "ama" { editor.insertText(String(letter), replacementRange: editor.selectedRange()) }
        XCTAssertEqual(palette.input.stringValue, "amazon.co.uk/account")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: "zon.co.uk/account".utf16.count))
        XCTAssertEqual(palette.offeredSite?.name, "Amazon", "Completing a learned path must keep Search in Amazon available")
        var destination: URL?
        palette.submit = { _, suggestion in destination = suggestion?.url }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(destination, account)
    }
    @MainActor func testAPopularSiteFillsInAndTabSearchesItThroughItsOwnSearch() throws {
        let region = PopularSites.region; PopularSites.region = "GB"; defer { PopularSites.region = region }
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        palette.siteFavicon = { $0.host == "amazon.co.uk" ? icon : nil }
        for letter in "ama" { editor.insertText(String(letter), replacementRange: editor.selectedRange()) }
        editor.insertText("z", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.input.stringValue, "amazon.co.uk")
        XCTAssertTrue(palette.leadingIcon.image === icon, "Filling in Amazon, Amazon's icon leads the field")
        XCTAssertFalse(palette.suggestions.contains { $0.url?.host == "amazon.co.uk" }, "No row repeats what the field fills in")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 8), "The filled-in part is selected, to type over")
        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, AddressAppearance.textSelection(browser.theme), "In gray, not blue")
        XCTAssertEqual(palette.offeredSite?.name, "Amazon", "The site's search is offered")

        let rowsBeforeTab = palette.suggestions.map(\.title)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(palette.siteSearch?.name, "Amazon")
        XCTAssertTrue(palette.leadingIcon.image === icon)
        XCTAssertNil(palette.offeredSite)
        XCTAssertEqual(palette.input.stringValue, "", "The field empties, for the search from scratch")
        XCTAssertTrue(palette.siteHint.isSearching); XCTAssertEqual(palette.siteHint.siteName, "Amazon")
        XCTAssertEqual(palette.siteHint.alphaValue, 1, "The hint stays, naming the site being searched")
        XCTAssertTrue(palette.suggestions.isEmpty, "A site's search doesn't match addresses")
        XCTAssertEqual(palette.frame.height, AddressAppearance.newTabHeaderHeight, "With no rows, as much room below the field as above")
        var submitted: AddressSuggestion?
        let original = palette.submit
        palette.submit = { submitted = $1 }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted?.url, palette.siteSearch?.homeURL, "Left empty, Enter goes to the site")
        editor.insertText("usb c", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.input.stringValue, "usb c")
        XCTAssertTrue(palette.suggestions.isEmpty)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted?.url?.absoluteString, "https://www.amazon.co.uk/s?k=usb%20c")
        palette.submit = original

        // Escape goes back to the address as it was, rather than closing.
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(palette.siteSearch); XCTAssertTrue(palette.isPresented)
        XCTAssertEqual(palette.input.stringValue, "amazon.co.uk")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 8), "The filled-in part selected again")
        XCTAssertEqual(palette.suggestions.map(\.title), rowsBeforeTab, "With the same rows")
        XCTAssertEqual(palette.offeredSite?.name, "Amazon"); XCTAssertFalse(palette.siteHint.isSearching)
        // ⌘Z steps back too: what's typed first, back to the empty search, then out of the site's search.
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        editor.insertText("cable", replacementRange: editor.selectedRange())
        let window = try XCTUnwrap(browser.window as? BrowserWindow)
        let undo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        XCTAssertEqual(palette.siteSearch?.name, "Amazon"); XCTAssertEqual(palette.input.stringValue, "")
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        XCTAssertNil(palette.siteSearch); XCTAssertEqual(palette.input.stringValue, "amazon.co.uk")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(palette.siteSearch?.name, "Amazon")
        // Deleting past the start of the search goes back to the address, offering it again.
        editor.insertText("", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.siteSearch?.name, "Amazon", "Clearing the field is still the site's search")
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertNil(palette.siteSearch)
        XCTAssertEqual(palette.input.stringValue, "amazon.co.uk"); XCTAssertEqual(palette.offeredSite?.name, "Amazon")

        // A deleted autofill no longer stands for what's typed: Enter searches the letters.
        editor.selectAll(nil); editor.insertText("amaz", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(palette.input.stringValue, "amaz")
        XCTAssertNil(palette.offeredSite, "Not a site's address any more")
        XCTAssertFalse(palette.leadingIcon.image === icon, "Its icon goes with it")
        XCTAssertEqual(palette.chosenSuggestion?.url, browser.searchEngine.searchURL(for: "amaz"))
        // ⌘⌫ over a fill-in clears the whole field, without filling it back in.
        editor.insertText("o", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.input.stringValue, "amazon.co.uk")
        editor.doCommand(by: #selector(NSResponder.deleteToBeginningOfLine(_:)))
        XCTAssertEqual(palette.input.stringValue, ""); XCTAssertNil(palette.offeredSite)
    }
    @MainActor func testEditingTheCurrentAddressShowsThePageIconAndEnterOnlyOpensWhatIsPicked() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.browsingHistory.record(URL(string: "https://example.com/other")!, title: "Other")
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/page")!
        tab.favicon = NSImage(size: NSSize(width: 16, height: 16))
        browser.showWindow(nil); browser.focusAddress()
        let palette = browser.palette
        XCTAssertEqual(palette.input.stringValue, "https://example.com/page")
        XCTAssertTrue(palette.leadingIcon.image === tab.favicon, "The page's icon stands in for the magnifying glass")
        XCTAssertFalse(palette.suggestions.contains { $0.url == tab.url }, "No row repeats the address being edited")
        XCTAssertEqual(palette.selectedIndex, -1)
        var submitted: (String, AddressSuggestion?)?
        let original = palette.submit
        palette.submit = { submitted = ($0, $1) }
        palette.chooseSelected()
        XCTAssertNil(submitted?.1, "With nothing picked, Enter opens the field's own text, the page it's already on")
        palette.submit = original
        // Typing a command's name and pressing Enter searches for it; the command needs picking.
        palette.input.currentEditor()?.selectAll(nil)
        (palette.input.currentEditor() as? NSTextView)?.insertText("split", replacementRange: NSRange(location: 0, length: palette.input.stringValue.utf16.count))
        XCTAssertTrue(palette.suggestions.contains { $0.command == "Split View" })
        XCTAssertNotEqual(palette.leadingIcon.image, tab.favicon, "Changed, it's a search or address again")
        palette.submit = { submitted = ($0, $1) }
        palette.chooseSelected()
        XCTAssertNil(submitted?.1?.command); XCTAssertEqual(submitted?.1?.isTypedAction, true)
    }
    @MainActor func testAFinishedLoadRecordsVisitsButTypingPrefetchAndFailuresDoNotAndResetPersists() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab()
        tab.open(URL(string: "https://example.com/docs")!, title: "Learned page")
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
