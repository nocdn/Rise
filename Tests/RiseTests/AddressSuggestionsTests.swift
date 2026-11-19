import XCTest
import AppKit
import RiseCore
@testable import Rise

final class AddressSuggestionsTests: XCTestCase {
    @MainActor func testBlankPanelRefreshesFromCurrentHabitsAndShowsOnePagePerSite() {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let old = URL(string: "https://old.example/")!, account = URL(string: "https://work.example/account")!
        let now = Date()
        for _ in 0..<100 { browser.browsingHistory.record(old, title: "Old habit", at: now.addingTimeInterval(-45*86400)) }
        for _ in 0..<8 { browser.browsingHistory.record(account, title: "Current account", at: now) }
        browser.browsingHistory.record(URL(string: "https://www.work.example/other")!, title: "Same site", at: now)
        browser.showWindow(nil); browser.newTab()
        XCTAssertEqual(browser.palette.suggestions.first?.url, account)
        XCTAssertEqual(browser.palette.suggestions.filter { $0.url?.host?.hasSuffix("work.example") == true }.count, 1)
        browser.hidePalette()
        let newer = URL(string: "https://newer.example/")!
        for _ in 0..<12 { browser.browsingHistory.record(newer, title: "A new routine") }
        browser.newTab()
        XCTAssertEqual(browser.palette.suggestions.first?.url, newer)
        XCTAssertFalse(browser.palette.suggestions.contains { ["Wikipedia", "GitHub"].contains($0.title) })
    }

    @MainActor func testALongSearchUsesTheRowsWidthWhileAPageLeavesRoomForItsAddress() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil); browser.newTab()
        let long = "cloudflare please wait while your request is being verified by the security service"
        browser.palette.replaceSuggestions([
            AddressSuggestion(title: long, subtitle: "", symbol: "magnifyingglass", url: URL(string: "https://www.google.com/search?q=x"), tabID: nil, command: nil),
            AddressSuggestion(title: long, subtitle: "https://example.com/page", symbol: "globe", url: URL(string: "https://example.com/page"), tabID: nil, command: nil)])
        browser.palette.layoutSubtreeIfNeeded()
        let titles = browser.palette.subviews.compactMap { row in row.subviews.first { ($0 as? NSTextField)?.identifier == AddressPalette.titleID } }
        XCTAssertEqual(titles.count, 2)
        XCTAssertGreaterThan(titles[0].frame.width, CenteredPaletteStyle.titleMaximumWidth+100, "A search isn't cut short with room to spare")
        XCTAssertLessThanOrEqual(titles[1].frame.width, CenteredPaletteStyle.titleMaximumWidth, "A page's title leaves room for its address")
    }
    @MainActor func testATitleThatIsAnAddressReadsAsOneWithoutRepeatingIt() {
        func row(_ title: String, _ address: String) -> AddressSuggestion {
            AddressSuggestion(title: title, subtitle: address, symbol: "globe", url: URL(string: address), tabID: nil, command: nil)
        }
        let bare = row("https://remotedesktop.google.com/", "https://remotedesktop.google.com/")
        XCTAssertEqual(AddressPalette.shownTitle(bare), "remotedesktop.google.com/", "https:// is hidden, as it is for addresses")
        XCTAssertFalse(AddressPalette.showsAddress(row("remotedesktop.google.com/access", "https://remotedesktop.google.com/access")))
        XCTAssertTrue(AddressPalette.showsAddress(row("Remote Access", "https://remotedesktop.google.com/access")))
        XCTAssertEqual(AddressPalette.shownTitle(row("Remote Access", "https://remotedesktop.google.com/access")), "Remote Access")
    }
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
    @MainActor func testLongInlineCompletionKeepsTypedPrefixVisibleUntilTheUserAcceptsIt() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette
        let editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        let manager = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        let prefixes = ["dev", "developers.example/👩🏽‍💻/", "developers.example/"+String(repeating: "typed-path/", count: 25)]
        for prefix in prefixes {
            let completed = prefix + String(repeating: "autofilled-path/", count: 45)
            palette.queryChanged = { _ in
                [AddressSuggestion(title: "A long address", subtitle: completed, symbol: "globe", url: URL(string: "https://developers.example/"),
                                   tabID: nil, command: nil, completion: completed, isTypedAction: true)]
            }
            palette.input.selectText(nil)
            editor.insertText(prefix, replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, completed)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: prefix.utf16.count, length: completed.utf16.count-prefix.utf16.count))
            // AppKit asks to reveal the selected suffix after insertion. That
            // must not move what the user typed off the left side of the field.
            editor.scrollRangeToVisible(editor.selectedRange())
            palette.place(at: NSPoint(x: 6, y: 48), width: 300)
            palette.layoutSubtreeIfNeeded()
            manager.ensureLayout(for: container)
            let last = NSRange(location: prefix.utf16.count-1, length: 1)
            let glyphs = manager.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
            let typedEnd = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            XCTAssertTrue(editor.visibleRect.intersects(typedEnd), "The text being typed remains visible, including a long prefix")
            if prefix.utf16.count < 40 {
                XCTAssertEqual(editor.visibleRect.minX, 0, accuracy: 1, "A short prefix must remain visible in full")
            }
            let prefixViewport = editor.visibleRect.minX
            editor.setSelectedRange(NSRange(location: completed.utf16.count, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            XCTAssertGreaterThan(editor.visibleRect.minX, prefixViewport, "Accepting the completion restores normal caret scrolling")
            XCTAssertEqual(editor.string, completed, "The complete destination is preserved")
        }
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
        // The veil fades in quickly, while the palette shows at once, and out a little quicker,
        // while the next click already goes where it's aimed.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(browser.veil.layer?.animation(forKey: PanelVeil.animationKey)?.duration, PanelVeil.fadeInDuration)
            browser.hidePalette()
            XCTAssertTrue(browser.dismissArea.isHidden); XCTAssertFalse(browser.veil.isHidden)
            XCTAssertNil(browser.veil.hitTest(NSPoint(x: 10, y: 10)))
            XCTAssertEqual(browser.veil.layer?.animation(forKey: PanelVeil.animationKey)?.duration, PanelVeil.fadeOutDuration)
            browser.newTab()
        }
        XCTAssertNil(palette.layer?.animationKeys(), "The palette itself doesn't animate in")
        XCTAssertTrue(glyph.representations.first.map { "\(type(of: $0))".contains("SVG") } ?? false, "Kero's own glyph, not a stand-in")
        XCTAssertEqual(palette.frame.width, CenteredPaletteStyle.width)
        XCTAssertEqual(palette.frame.minY, max(8, round(browser.root.bounds.midY-CenteredPaletteStyle.maximumHeight/2)), "Centred at its tallest")
        XCTAssertTrue(palette.leadingIcon.image === glyph)
        let editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("weather", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.typedSearch?.url, browser.searchProvider.searchURL("weather"))
        XCTAssertFalse(palette.suggestions.contains { $0.url == palette.typedSearch?.url }, "Enter searches what's typed without a row repeating it")
        // No blue: nothing's highlighted until the pointer or the arrow keys pick a row, then in gray.
        XCTAssertTrue(palette.buttons.allSatisfy { $0.layer?.backgroundColor?.alpha == 0 })
        let last = palette.buttons.count-1, row = palette.buttons[last]
        palette.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: palette.convert(NSPoint(x: row.frame.midX, y: row.frame.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        XCTAssertEqual(palette.selectedIndex, last)
        XCTAssertEqual(row.layer?.backgroundColor, CenteredPaletteStyle.hover(browser.theme).cgColor)
        palette.mouseExited(with: NSEvent())
        XCTAssertEqual(palette.selectedIndex, -1, "Off the rows, the gray goes")
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0)
        browser.hidePalette(); browser.focusAddress()
        XCTAssertTrue(palette.isCentered); XCTAssertTrue(palette.leadingIcon.image === glyph, "⌘L is the same panel")
    }
    @MainActor func testArrowKeysPickRowsInGrayFillingThemInAndPuttingBackWhatWasTyped() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        for _ in 0..<3 { browser.browsingHistory.record(URL(string: "https://news.ycombinator.com/")!, title: "Hacker News") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("news", replacementRange: editor.selectedRange())
        let filled = editor.string, filledRange = editor.selectedRange()
        XCTAssertEqual(filled, "news.ycombinator.com"); XCTAssertEqual(palette.offeredSite?.name, "Hacker News")
        func highlighted() -> [Int] { palette.buttons.indices.filter { palette.buttons[$0].layer?.backgroundColor == CenteredPaletteStyle.hover(browser.theme).cgColor } }
        func cursorAtEnd() -> Bool { editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0) }
        XCTAssertEqual(highlighted(), [])
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(highlighted(), [0]); XCTAssertEqual(editor.string, "news.ycombinator.com", "A page fills in its address")
        XCTAssertTrue(cursorAtEnd(), "To edit from the end"); XCTAssertEqual(palette.offeredSite?.name, "Hacker News")
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(highlighted(), [], "Above the first row, none"); XCTAssertEqual(palette.selectedIndex, -1)
        XCTAssertEqual(editor.string, filled, "And what was typed comes back, filled in as it was")
        XCTAssertEqual(editor.selectedRange(), filledRange); XCTAssertEqual(palette.offeredSite?.name, "Hacker News")
    }
    @MainActor func testArrowingOntoACommandShowsWhatWasTypedAndTheCommandsIcon() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        for _ in 0..<3 { browser.browsingHistory.record(URL(string: "https://zoom.us/")!, title: "Zoom") }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/")
        browser.showWindow(nil); browser.focusAddress()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        let favicon = NSImage(size: NSSize(width: 16, height: 16)); palette.siteFavicon = { _ in favicon }
        editor.selectAll(nil); editor.insertText("/zoom", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "/zoom")
        let zoom = try XCTUnwrap(palette.suggestions.firstIndex { $0.command == "Zoom" })
        palette.selectResult(-1)
        for _ in 0...zoom { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        XCTAssertEqual(palette.selectedIndex, zoom)
        XCTAssertEqual(editor.string, "/zoom", "Arrow keys keep the slash query intact")
        XCTAssertFalse(palette.leadingIcon.image === favicon); XCTAssertFalse(palette.leadingIcon.image === CenteredPaletteStyle.searchIcon)
        XCTAssertEqual(palette.leadingIcon.contentTintColor, CenteredPaletteStyle.fieldIcon(browser.theme), "The command's own glyph")
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
    @MainActor func testAddressesShowWithoutHTTPSAndWWWUnlessTurnedOffInSettings() {
        let browser = browser(); defer { clean(browser) }
        let address = "https://www.youtube.com/watch?v=1"
        XCTAssertEqual(AddressDisplay.text(address), "youtube.com/watch?v=1", "Both hidden by default")
        browser.setRiseSetting("hideAddressScheme", false)
        XCTAssertEqual(AddressDisplay.text(address), "https://youtube.com/watch?v=1")
        browser.setRiseSetting("hideAddressScheme", true); browser.setRiseSetting("hideAddressWWW", false)
        XCTAssertEqual(AddressDisplay.text(address), "www.youtube.com/watch?v=1")
        browser.setRiseSetting("hideAddressWWW", true)
        XCTAssertEqual(AddressDisplay.text("http://www.example.com/"), "example.com/")
    }
    @MainActor func testChangeThemeListsTheThemesToPickNarrowedByTypingAndEscapeGoesBack() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.theme = .neutral; browser.automaticTheme = false; browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("/theme", replacementRange: editor.selectedRange())
        let rows = palette.suggestions.map(\.title)
        palette.selectResult(try XCTUnwrap(palette.suggestions.firstIndex { $0.command == "Change Theme" }))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(palette.isPresented, "Change Theme lists the themes rather than cycling them")
        XCTAssertEqual(palette.suggestions.map(\.title), ["Light", "Dark", "Automatic"])
        XCTAssertEqual(palette.selectedIndex, 0, "Starting on the theme in use"); XCTAssertEqual(editor.string, "")
        editor.insertText("da", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.suggestions.map(\.title), ["Dark"])
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(palette.isChoosing); XCTAssertEqual(editor.string, "/theme", "Escape goes back to what was typed")
        XCTAssertEqual(palette.suggestions.map(\.title), rows)
        XCTAssertEqual(browser.paletteCommandUsage.count(for: "Change Theme"), 0, "Cancelling the submenu isn't a use")
        palette.selectResult(try XCTUnwrap(palette.suggestions.firstIndex { $0.command == "Change Theme" }))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(browser.theme, .dark); XCTAssertFalse(browser.automaticTheme); XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(browser.paletteCommandUsage.count(for: "Change Theme"), 1)
    }
    @MainActor func testALongListScrollsInsideThePanelToKeepThePickedRowInView() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil)
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/"); browser.select(tab.id)
        browser.setPageZoom(1.75); browser.focusAddress()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        palette.enterChoice(try XCTUnwrap(browser.paletteChoice(for: "Zoom")))
        palette.layoutSubtreeIfNeeded()
        let shown = { palette.buttons.indices.filter { !palette.buttons[$0].isHidden } }
        XCTAssertLessThanOrEqual(palette.frame.height, CenteredPaletteStyle.maximumHeight)
        XCTAssertEqual(shown().count, CenteredPaletteStyle.visibleRows)
        XCTAssertEqual(palette.suggestions[palette.selectedIndex].title, "175%")
        XCTAssertTrue(shown().contains(palette.selectedIndex), "Starting scrolled to the zoom in use")
        XCTAssertTrue(palette.buttons.filter { !$0.isHidden }.allSatisfy { palette.bounds.contains($0.frame) })
        for _ in 0..<palette.selectedIndex { editor.doCommand(by: #selector(NSResponder.moveUp(_:))) }
        XCTAssertEqual(palette.selectedIndex, 0); XCTAssertEqual(shown().first, 0, "↑ scrolls back up")
        for _ in 1..<palette.suggestions.count { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        XCTAssertGreaterThan(palette.firstRow, 0)
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: try commandUp(in: browser)))
        XCTAssertEqual(palette.selectedIndex, 0); XCTAssertEqual(palette.firstRow, 0)
        XCTAssertEqual(palette.chosenSuggestion?.title, "25%", "⌘↑ also works inside command choices")
    }
    @MainActor func testSlashListsEveryCommandScrollsToTheLastAndFilteringResetsTheViewport() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        for index in 0..<3 { let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/\(index)") }
        browser.select(browser.tabs[1].id); browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("/", replacementRange: editor.selectedRange())
        let commands = browser.paletteCommands(matching: "").map(\.id)
        XCTAssertGreaterThan(commands.count, CenteredPaletteStyle.visibleRows)
        XCTAssertEqual(palette.suggestions.compactMap(\.command), commands, "Every command remains reachable in usage order")
        for index in commands.indices.dropFirst() {
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            XCTAssertEqual(palette.selectedIndex, index)
            XCTAssertFalse(palette.buttons[index].isHidden)
            XCTAssertTrue(palette.bounds.contains(palette.buttons[index].frame))
        }
        XCTAssertEqual(palette.selectedIndex, commands.count-1)
        XCTAssertGreaterThan(palette.firstRow, 0)
        XCTAssertLessThanOrEqual(palette.frame.height, CenteredPaletteStyle.maximumHeight)
        XCTAssertEqual(editor.string, "/", "Browsing commands preserves the editable filter")
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: try commandUp(in: browser)))
        XCTAssertEqual(palette.selectedIndex, 0); XCTAssertEqual(palette.firstRow, 0)
        XCTAssertEqual(editor.string, "/")
        for _ in commands.indices.dropFirst() { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        let fullHeight = palette.frame.height
        editor.insertText("settings", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.suggestions.compactMap(\.command), ["Open Settings"])
        XCTAssertEqual(palette.firstRow, 0); XCTAssertEqual(palette.selectedIndex, 0)
        XCTAssertLessThan(palette.frame.height, fullHeight, "The panel shrinks around the matching results")
        editor.selectAll(nil); editor.insertText("/not-a-browser-command", replacementRange: editor.selectedRange())
        XCTAssertTrue(palette.suggestions.isEmpty)
        let message = try XCTUnwrap(palette.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "No matching commands" })
        XCTAssertFalse(message.isHidden); XCTAssertTrue(palette.bounds.contains(message.frame))
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: try commandUp(in: browser)))
        XCTAssertEqual(palette.selectedIndex, -1, "An empty list has no selectable result")
        editor.selectAll(nil); editor.insertText("/", replacementRange: editor.selectedRange())
        XCTAssertTrue(message.isHidden)
        XCTAssertEqual(palette.suggestions.compactMap(\.command), commands)
        XCTAssertEqual(palette.firstRow, 0)
    }

    @MainActor func testCommandUpSelectsTheFirstNormalSuggestionAndKeepsKeyboardOwnershipAfterHover() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        for index in 0..<8 { browser.browsingHistory.record(URL(string: "https://document\(index).example.com/")!, title: "Document \(index)") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        XCTAssertGreaterThan(palette.suggestions.count, 1)
        for _ in palette.suggestions.indices { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        XCTAssertEqual(palette.selectedIndex, palette.suggestions.count-1)
        let jump = try commandUp(in: browser)
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: jump))
        XCTAssertEqual(palette.selectedIndex, 0)
        XCTAssertEqual(editor.string, AddressPalette.fieldText(for: palette.suggestions[0]))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveToBeginningOfDocument(_:)))
        XCTAssertEqual(palette.selectedIndex, 0, "The native text command uses the same jump")
        let last = try XCTUnwrap(palette.buttons.last)
        let point = palette.convert(NSPoint(x: last.frame.midX, y: last.frame.midY), to: nil)
        let mouse = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        palette.mouseMoved(with: mouse)
        XCTAssertEqual(palette.selectedIndex, palette.suggestions.count-1)
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: jump))
        palette.mouseExited(with: mouse)
        XCTAssertEqual(palette.selectedIndex, 0, "Leaving the pointer doesn't restore an old selection after ⌘↑")
        browser.hidePalette()
        XCTAssertFalse(palette.handleKeyEquivalent(jump), "The shortcut stays within the open palette")
    }

    @MainActor private func commandUp(in browser: BrowserController) throws -> NSEvent {
        let arrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .numericPad, .function], timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 126))
    }
    @MainActor func testSplitViewSplitsWithTheTabBeforeThisOne() {
        let browser = browser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab(), third = browser.addTab()
        let current = third, fallback = browser.tabs.first { $0.id != current.id }!
        let previous = [first, second].first { $0.id != fallback.id }!
        browser.select(previous.id); browser.select(current.id)
        browser.submitAddress("split", suggestion: AddressSuggestion(title: "Split View", subtitle: "", symbol: "rectangle.split.2x1", url: nil, tabID: nil, command: "Split View"))
        let group = browser.activeSplitGroup
        XCTAssertEqual(Set([group?.leftID, group?.rightID]), [current.id, previous.id], "The tab you were just on, not the first in the list")
    }
    @MainActor func testPaletteCommandsAnswerToTheirWordsShowOnlyWhenUsefulAndRun() {
        let browser = browser(); defer { clean(browser) }
        let tabs = (0..<3).map { index -> BrowserTab in
            let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/\(index)"); return tab
        }
        let middle = browser.tabs[1]; browser.select(middle.id)
        func titles(_ query: String) -> [String] { browser.paletteCommands(matching: query).map(\.title) }
        XCTAssertEqual(Set(titles("close")), ["Close Tab", "Close Tabs Below", "Close Tabs Above"])
        XCTAssertEqual(titles("url"), ["Copy Link"], "Keywords count too")
        XCTAssertEqual(titles("pin"), ["Pin Tab"]); XCTAssertEqual(titles("develop"), ["Enable Developer Mode"])
        XCTAssertEqual(titles("swap"), [], "Only in a split")
        let above = browser.tabs[0]
        browser.runPaletteCommand("Close Tabs Above")
        XCTAssertFalse(browser.tabs.contains { $0 === above }); XCTAssertEqual(browser.selectedID, middle.id)
        browser.toggleSplit()
        let group = try! XCTUnwrap(browser.activeSplitGroup)
        XCTAssertEqual(titles("swap"), ["Swap Sides"])
        browser.runPaletteCommand("Swap Sides")
        XCTAssertEqual(browser.activeSplitGroup?.leftID, group.rightID); XCTAssertEqual(browser.activeSplitGroup?.rightID, group.leftID)
        XCTAssertEqual(browser.paletteChoice(for: "Capture Page")?.rows.map(\.title), ["JPEG", "PDF"])
        _ = tabs
    }
    @MainActor func testHiddenAliasesFindActionsFromCommonDescriptionsAndPunctuation() {
        let browser = browser(); defer { clean(browser) }
        for index in 0..<3 { let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/\(index)") }
        let closed = browser.addTab(); closed.requestedURL = URL(string: "https://closed.example/")
        browser.closeTab(closed.id); browser.select(browser.tabs[1].id)
        browser.setSidebarVisible(true); browser.setPageZoom(1.5)
        let titles = Dictionary(uniqueKeysWithValues: browser.paletteCommands.map { ($0.id, $0.title) })
        let queries: [(String, String)] = [
            ("dismiss", "Close Tab"), ("bring back", "Reopen Closed Tab"), ("clone", "Duplicate Tab"),
            ("keep open", "Toggle Pin"), ("quiet", "Toggle Mute"),
            ("close tabs after", "Close Tabs Below"), ("close tabs before", "Close Tabs Above"),
            ("tidy", "Sort Tabs by Domain"), ("group by site", "Sort Tabs by Domain"),
            ("side-by-side", "Split View"), ("compare pages", "Split View"), ("update page", "Reload"),
            ("clipboard", "Copy Link"), ("locate", "Find in Page"), ("screen-shot", "Capture Page"),
            ("snapshot", "Capture Page"), ("export page", "Capture Page"), ("magnify", "Zoom"),
            ("text size", "Zoom"), ("default size", "Actual Size"), ("100%", "Actual Size"),
            ("NIGHT MODE", "Change Theme"), ("color", "Change Theme"), ("colour", "Change Theme"),
            ("collapse sidebar", "Toggle Sidebar"), ("options", "Open Settings"), ("config", "Open Settings"),
            ("customise", "Open Settings"), ("customize", "Open Settings"), ("add-ons", "Extensions"),
            ("plug-in", "Extensions"), ("addons", "Extensions"), ("files", "Downloads"),
            ("transfer", "Downloads"), ("advanced controls", "Toggle Developer Mode")
        ]
        for (query, command) in queries {
            let match = browser.suggestions(for: "/"+query).first { $0.command == command }
            XCTAssertNotNil(match, "\(query) should find \(command)")
            XCTAssertEqual(match?.title, titles[command], "Aliases never replace the displayed title")
            XCTAssertEqual(browser.paletteCommandUsage.count(for: command), 0, "Searching is not executing a command")
        }
        XCTAssertTrue(browser.suggestions(for: "side-by-side").allSatisfy { $0.command == nil })
        XCTAssertTrue(browser.suggestions(for: "/---").isEmpty, "Punctuation alone doesn't match everything")
    }

    @MainActor func testDirectionalAliasesFollowToggleStateAndActionAvailability() {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/")
        func has(_ query: String, _ command: String) -> Bool {
            browser.suggestions(for: "/"+query).contains { $0.command == command }
        }
        XCTAssertFalse(has("bring back", "Reopen Closed Tab"))
        XCTAssertFalse(has("flip sides", "Swap Sides"))
        XCTAssertFalse(has("unsplit", "Split View"))
        XCTAssertTrue(has("turn off sound", "Toggle Mute"))
        XCTAssertFalse(has("turn on sound", "Toggle Mute"))
        browser.runPaletteCommand("Toggle Mute")
        XCTAssertTrue(has("turn on sound", "Toggle Mute"))
        XCTAssertFalse(has("turn off sound", "Toggle Mute"))
        XCTAssertTrue(has("keep open", "Toggle Pin"))
        browser.pinCurrentTab()
        XCTAssertTrue(has("release tab", "Toggle Pin"))
        XCTAssertFalse(has("keep open", "Toggle Pin"))
        browser.pinCurrentTab()
        browser.setSidebarVisible(true)
        XCTAssertTrue(has("hide sidebar", "Toggle Sidebar")); XCTAssertFalse(has("show sidebar", "Toggle Sidebar"))
        browser.toggleSidebar()
        XCTAssertTrue(has("show sidebar", "Toggle Sidebar")); XCTAssertFalse(has("hide sidebar", "Toggle Sidebar"))
        let other = browser.addTab(); other.requestedURL = URL(string: "https://other.example/")
        browser.toggleSplit()
        XCTAssertTrue(has("unsplit", "Split View")); XCTAssertTrue(has("flip sides", "Swap Sides"))
    }

    @MainActor func testAliasResultsKeepUsageRanking() {
        let browser = browser(); defer { clean(browser) }
        _ = browser.addTab()
        browser.runPaletteCommand("Zoom:1.5")
        XCTAssertEqual(browser.suggestions(for: "/size").first?.command, "Zoom")
        for _ in 0..<3 { browser.setPageZoom(1.5); browser.runPaletteCommand("Actual Size") }
        browser.setPageZoom(1.5)
        XCTAssertEqual(browser.suggestions(for: "/size").first?.command, "Actual Size")
    }
    @MainActor func testBrowserCommandsOnlyAppearAfterASlashEvenWithMatchingHistory() {
        let browser = browser(); defer { clean(browser) }
        for index in 0..<2 { let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/\(index)") }
        browser.setPageZoom(1.5)
        for command in browser.paletteCommands {
            let word = command.title.split(separator: " ")[0].lowercased()
            for page in 0..<10 { browser.browsingHistory.record(URL(string: "https://\(word).com/\(page)")!, title: "\(word) \(page)") }
            XCTAssertTrue(browser.suggestions(for: word).allSatisfy { $0.command == nil })
            let rows = browser.suggestions(for: "/"+word)
            XCTAssertTrue(rows.contains { $0.command == command.id }, "\(command.title) missing for “\(word)”: \(rows.map(\.title))")
            XCTAssertTrue(rows.allSatisfy { $0.command != nil && $0.url == nil && $0.completion == nil })
            XCTAssertEqual(rows.compactMap(\.command), browser.paletteCommands(matching: word).map(\.id))
        }
        XCTAssertNotNil(browser.suggestions(for: "zoom").first?.completion, "The completion still leads")
        XCTAssertFalse(browser.suggestions(for: "/").isEmpty)
        XCTAssertTrue(browser.suggestions(for: "/").allSatisfy { $0.command != nil })
        for query in ["", "settings", "some /zoom", "https://example.com/zoom"] {
            XCTAssertTrue(browser.suggestions(for: query).allSatisfy { $0.command == nil })
        }
    }

    @MainActor func testDeletingSlashImmediatelyRestoresNormalSuggestionsAndUnknownCommandsDoNotNavigate() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        _ = browser.addTab()
        browser.browsingHistory.record(URL(string: "https://zoom.us/")!, title: "Zoom")
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("/", replacementRange: editor.selectedRange())
        XCTAssertTrue(palette.isCommandMode); XCTAssertNil(palette.offeredSite); XCTAssertNil(palette.autofill)
        XCTAssertEqual(palette.selectedIndex, 0)
        editor.insertText("zoom", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.chosenSuggestion?.command, "Zoom")
        XCTAssertEqual(editor.string, "/zoom")
        editor.setSelectedRange(NSRange(location: 0, length: 1)); editor.deleteBackward(nil)
        XCTAssertFalse(palette.isCommandMode)
        XCTAssertEqual(editor.string, "zoom")
        XCTAssertTrue(palette.suggestions.allSatisfy { $0.command == nil })
        XCTAssertEqual(palette.selectedIndex, -1)
        editor.selectAll(nil); editor.insertText("/", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(editor.string, ""); XCTAssertFalse(palette.isCommandMode)
        XCTAssertTrue(palette.suggestions.allSatisfy { $0.command == nil })
        editor.insertText("/no-such-browser-command", replacementRange: editor.selectedRange())
        XCTAssertTrue(palette.suggestions.isEmpty)
        var submitted = false
        palette.submit = { _, _ in submitted = true }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(submitted); XCTAssertTrue(palette.isPresented)
        browser.submitAddress(editor.string, suggestion: nil)
        XCTAssertTrue(palette.isPresented)
    }

    @MainActor func testCommandRankingCountsExecutedActionsAndSubmenuChoicesAndSurvivesRelaunch() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/")
        let original = browser.suggestions(for: "/").compactMap(\.command)
        XCTAssertEqual(original, browser.suggestions(for: "/").compactMap(\.command), "Unused commands keep a stable order")
        _ = browser.paletteChoice(for: "Change Theme")
        XCTAssertEqual(browser.paletteCommandUsage.count(for: "Change Theme"), 0, "Opening a submenu does not count")
        browser.runPaletteCommand("Zoom:1.25")
        browser.runPaletteCommand("Zoom:1.5")
        browser.runPaletteCommand("Actual Size")
        XCTAssertEqual(browser.suggestions(for: "/").first?.command, "Zoom")
        XCTAssertEqual(browser.suggestions(for: "/zoom").map(\.command), ["Zoom"])
        browser.runPaletteCommand("Zoom:1.25")
        XCTAssertEqual(browser.suggestions(for: "/zoom").map(\.command), ["Zoom", "Actual Size"])
        XCTAssertEqual(browser.paletteCommandUsage.count(for: "Zoom"), 3)
        browser.runPaletteCommand("not a command")
        XCTAssertEqual(browser.paletteCommandUsage.count(for: "not a command"), 0)
        browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.saveWork?.cancel(); restored.suggestionFavicons.cancel(); restored.window?.orderOut(nil); restored.tabs.forEach { $0.cancelLoad() } }
        XCTAssertEqual(restored.paletteCommandUsage.count(for: "Zoom"), 3)
        XCTAssertEqual(restored.suggestions(for: "/").first?.command, "Zoom")
        XCTAssertEqual(browser.suggestions(for: "/open settings").map(\.command), ["Open Settings"])
    }
    @MainActor func testZoomPicksALevelAndThePageBarButtonShowsWhileThePageIsZoomed() {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/"); browser.select(tab.id); browser.update()
        let zoom = try! XCTUnwrap(browser.paletteChoice(for: "Zoom"))
        XCTAssertEqual(zoom.rows.first?.title, "25%"); XCTAssertEqual(zoom.rows.last?.title, "200%")
        XCTAssertEqual(zoom.picked.map { zoom.rows[$0].title }, "100%", "Starting on the zoom in use")
        XCTAssertFalse(browser.navBar.showsZoom)
        browser.runPaletteCommand("Zoom:1.5")
        XCTAssertEqual(tab.page.zoom, 1.5, accuracy: 0.001)
        XCTAssertTrue(browser.navBar.showsZoom); XCTAssertTrue(browser.navBar.zoomButton.allowsInteraction, "Zoom remains available without hovering")
        browser.navBar.setHovered(true)
        XCTAssertTrue(browser.navBar.zoomButton.allowsInteraction)
        browser.zoomIn(); XCTAssertEqual(tab.page.zoom, 1.75, accuracy: 0.001, "⌘+ steps through the same levels")
        browser.actualSize()
        XCTAssertFalse(browser.navBar.showsZoom); XCTAssertFalse(browser.navBar.zoomButton.allowsInteraction)
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
        XCTAssertEqual(palette.selectedIndex, 0, "Down from the field picks the first row")
        XCTAssertEqual(editor.string, "example.com", "And fills it in, to edit")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(palette.isPresented)
    }
    @MainActor func testPointerAndArrowKeysPickRowsWithoutRebuildingAndEnterUsesThePick() throws {
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
        XCTAssertEqual(palette.selectedIndex, targetIndex, "The row under the pointer is picked")
        XCTAssertEqual(editor.string, typed, "Without taking back what the field filled in")
        XCTAssertEqual(rows[targetIndex].layer?.backgroundColor, CenteredPaletteStyle.hover(.dark).cgColor)
        var submitted: URL?
        palette.submit = { _, suggestion in submitted = suggestion?.url }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted, palette.suggestions[targetIndex].url, "Enter opens the row under the pointer")
        palette.mouseExited(with: NSEvent())
        XCTAssertEqual(palette.selectedIndex, -1)
        for _ in 0...targetIndex { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        XCTAssertEqual(palette.selectedIndex, targetIndex)
        XCTAssertTrue(zip(rows, palette.buttons).allSatisfy { $0 === $1 }, "Picking doesn't rebuild the rows")
        XCTAssertEqual(palette.buttons.map(\.frame), frames)
        submitted = nil; editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted, palette.suggestions[targetIndex].url)
        rows[1].performClick(nil)
        XCTAssertEqual(submitted, palette.suggestions[1].url)
        palette.hide(); palette.mouseMoved(with: event)
        XCTAssertEqual(palette.selectedIndex, 1, "Hidden results ignore pointer events")
    }
    @MainActor func testASingleLearnedLetterFillsTheNativeFieldAndEnterOpensItsAddress() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let home = URL(string: "https://x.com/")!
        for _ in 0..<12 { browser.browsingHistory.record(home, title: "X") }
        browser.showWindow(nil)
        for newTab in [true, false] {
            if newTab { browser.newTab() } else { browser.focusAddress() }
            let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
            editor.insertText("x", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "x.com")
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 4))
            XCTAssertEqual(palette.chosenSuggestion?.url, home)
            editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            XCTAssertEqual(editor.string, "x", "Backspace removes the completion without immediately filling it again")
            XCTAssertEqual(palette.chosenSuggestion?.url, browser.searchProvider.searchURL("x"))
            XCTAssertFalse(palette.suggestions.contains { $0.url == browser.searchProvider.searchURL("x") }, "Enter searches what's typed without a row repeating it")
            editor.selectAll(nil); editor.insertText("x", replacementRange: editor.selectedRange())
            var destination: URL?
            let submit = palette.submit
            palette.submit = { _, suggestion in destination = suggestion?.url }
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(destination, home)
            palette.submit = submit
            browser.hidePalette()
        }
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
    @MainActor func testAccountPathCompletesInTheNativeFieldDespiteMoreSignInRedirects() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        let account = URL(string: "https://www.voxi.co.uk/account")!
        for _ in 0..<22 { browser.browsingHistory.record(account, title: "Your account") }
        for _ in 0..<30 { browser.browsingHistory.record(URL(string: "https://www.voxi.co.uk/sign-in?returnTo=account")!, title: "Sign in") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        for letter in "vox" { editor.insertText(String(letter), replacementRange: editor.selectedRange()) }
        XCTAssertEqual(palette.input.stringValue, "voxi.co.uk/account")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: "i.co.uk/account".utf16.count))
        XCTAssertEqual(palette.chosenSuggestion?.url, account)
    }
    @MainActor func testAssistantOffersSayAskAndSubmitAnExplicitRequestInsteadOfAPrefillURL() throws {
        let browser = browser(); defer { browser.hidePalette(); clean(browser) }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette
        for assistant in ChatAssistant.allCases {
            palette.enterSiteSearch(try XCTUnwrap(PopularSites.site(forAddress: assistant.domain)))
            XCTAssertEqual(palette.siteHint.action, "Ask")
            XCTAssertEqual(palette.input.placeholderAttributedString?.string, "Ask \(assistant.name)…")
            let editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
            editor.insertText("hello & \"world\" 日本語", replacementRange: editor.selectedRange())
            var submitted: AddressSuggestion?
            palette.submit = { _, value in submitted = value }
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(submitted?.title, "Ask \(assistant.name)")
            XCTAssertEqual(submitted?.url, assistant.entryURL)
            XCTAssertEqual(submitted?.assistantPrompt?.text, "hello & \"world\" 日本語")
            XCTAssertEqual(submitted?.assistantPrompt?.service, assistant)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }
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
        // Without the slash, a command's name remains an ordinary web search.
        palette.input.currentEditor()?.selectAll(nil)
        (palette.input.currentEditor() as? NSTextView)?.insertText("split", replacementRange: NSRange(location: 0, length: palette.input.stringValue.utf16.count))
        XCTAssertFalse(palette.suggestions.contains { $0.command != nil })
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

    /// A reload, or the tab coming back at launch, isn't going anywhere new.
    @MainActor func testReloadingOrRestoringATabDoesNotCountAsAnotherVisit() async throws {
        let browser = browser(); defer { clean(browser) }
        let url = try XCTUnwrap(URL(string: "https://example.com/docs")), tab = browser.addTab()
        tab.open(url, title: "Docs")
        let deadline = Date().addingTimeInterval(8)
        while browser.browsingHistory.entries.first?.visits != 1 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        browser.pageFinishedLoading(tab.page.view)
        XCTAssertEqual(browser.browsingHistory.entries.first?.visits, 1, "Reloaded")
        XCTAssertEqual(BrowserTab(saved: tab.saved).visitedAddress, BrowsingHistory.key(url), "Back at launch, its page has been counted")
    }
}
