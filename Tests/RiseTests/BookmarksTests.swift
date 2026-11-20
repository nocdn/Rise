import AppKit
import XCTest
@testable import Rise

@MainActor final class BookmarksTests: XCTestCase {
    private func makeBrowser() -> BrowserController {
        let suite = "BookmarksTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)/session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName("")
        return browser
    }
    private func clean(_ browser: BrowserController) {
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.close(); browser.saveWork?.cancel()
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    private func page(_ browser: BrowserController, _ address: String, _ title: String) -> BrowserTab {
        let tab = browser.addTab(); tab.open(URL(string: address)!, title: title); browser.update(); return tab
    }

    /// Bookmarks the page in front, as ⌘D and Enter do.
    private func keep(_ browser: BrowserController) {
        guard let tab = browser.selectedTab, let url = tab.url else { return }
        browser.bookmarks.add(url: url, title: tab.title, icon: nil, darkIcon: nil)
    }
    private func press(_ selector: Selector, in field: NSTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "Its title is being typed")
        _ = (field.delegate as? NSControlTextEditingDelegate)?.control?(field, textView: editor, doCommandBy: selector)
    }
    private func barField(_ browser: BrowserController) throws -> NSTextField {
        let item = try XCTUnwrap(browser.bookmarksBar.editingItem)
        return try XCTUnwrap(item.subviews.compactMap { $0 as? NSTextField }.first)
    }

    func testCommandDAddsToTheBarWithItsTitleChosenAndEnterKeepsIt() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        _ = page(browser, "https://example.com/docs#intro", "Docs")
        browser.bookmarkCurrentPage()
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["Docs"])
        XCTAssertFalse(browser.bookmarksBar.isHidden)
        let field = try barField(browser)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 4), "The whole title, to type over")
        XCTAssertTrue(BookmarkBarItem.editingWidth.contains(browser.bookmarksBar.editingItem!.frame.width))
        try press(#selector(NSResponder.insertNewline(_:)), in: field)
        XCTAssertNil(browser.bookmarksBar.editingItem)
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["Docs"], "Unchanged, it keeps the page's title")
        XCTAssertNotNil(browser.bookmarks.bookmark(for: URL(string: "https://EXAMPLE.com/docs/")), "The same page, whatever its fragment, case or slash")
        let restored = BrowserController(sessionURL: browser.sessionURL, restore: false, preferences: browser.preferences)
        XCTAssertEqual(restored.bookmarks.items.map(\.title), ["Docs"])
        restored.window?.close(); restored.saveWork?.cancel()

        // Again on the same page, its title is chosen to rename; Escape leaves it.
        browser.bookmarkCurrentPage()
        let again = try barField(browser)
        (again.currentEditor() as? NSTextView)?.string = "Something else"
        try press(#selector(NSResponder.cancelOperation(_:)), in: again)
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["Docs"])
        browser.bookmarkCurrentPage()
        let renamed = try barField(browser)
        (renamed.currentEditor() as? NSTextView)?.string = "Manual"
        try press(#selector(NSResponder.insertNewline(_:)), in: renamed)
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["Manual"])
        XCTAssertEqual(browser.bookmarksBar.items.first?.title, "Manual")
    }

    func testEscapeTakesAJustAddedBookmarkAwayAgain() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.bookmarks.add(url: URL(string: "https://one.example/")!, title: "One", icon: nil, darkIcon: nil)
        _ = page(browser, "https://example.com/", "Example")
        browser.bookmarkCurrentPage()
        XCTAssertEqual(browser.bookmarksBar.items.last?.isEditing, true, "At the bar's end")
        try press(#selector(NSResponder.cancelOperation(_:)), in: try barField(browser))
        XCTAssertEqual(browser.bookmarks.items.map(\.id), [first.id])
    }

    func testCommandDInTheSidebarRollsToBookmarksToNameItThenBack() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        browser.setRiseSetting("bookmarkPlacement", "sidebar")
        _ = browser.bookmarks.add(url: URL(string: "https://one.example/")!, title: "One", icon: nil, darkIcon: nil)
        _ = page(browser, "https://example.com/", "Example")
        browser.bookmarkCurrentPage()
        XCTAssertTrue(browser.showsSidebarBookmarks)
        let row = try XCTUnwrap(browser.sidebar.bookmarksPane.rows.last)
        XCTAssertTrue(row.isEditing, "The new one, at the end, being named")
        XCTAssertEqual((row.titleField.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 7))
        (row.titleField.currentEditor() as? NSTextView)?.string = "Mine"
        try press(#selector(NSResponder.insertNewline(_:)), in: row.titleField)
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["One", "Mine"])
        XCTAssertFalse(browser.showsSidebarBookmarks, "Back to the tabs it rolled from")

        _ = page(browser, "https://other.example/", "Other")
        browser.bookmarkCurrentPage()
        try press(#selector(NSResponder.cancelOperation(_:)), in: try XCTUnwrap(browser.sidebar.bookmarksPane.rows.last).titleField)
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["One", "Mine"], "Escape: not kept")
        XCTAssertFalse(browser.showsSidebarBookmarks)

        browser.toggleSidebarBookmarks()
        _ = page(browser, "https://third.example/", "Third")
        browser.bookmarkCurrentPage()
        try press(#selector(NSResponder.insertNewline(_:)), in: try XCTUnwrap(browser.sidebar.bookmarksPane.rows.last).titleField)
        XCTAssertTrue(browser.showsSidebarBookmarks, "Already showing, they stay")
    }

    func testTheBarTakesRoomUnderThePageBarOnlyOnceThereAreBookmarks() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = page(browser, "https://example.com/", "Example")
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height)
        XCTAssertTrue(browser.bookmarksBar.isHidden)
        keep(browser)
        XCTAssertFalse(browser.bookmarksBar.isHidden)
        XCTAssertEqual(browser.bookmarksBar.frame, NSRect(x: 0, y: PlainNavBar.Metrics.height, width: browser.pageClip.bounds.width, height: BookmarksBar.height))
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height+BookmarksBar.height)
        XCTAssertEqual(browser.bookmarksBar.items.count, 1)
        XCTAssertTrue(browser.bookmarksBar.superview === browser.pageClip)
        let index = try XCTUnwrap(browser.pageClip.subviews.firstIndex { $0 === browser.bookmarksBar })
        XCTAssertLessThan(index, try XCTUnwrap(browser.pageClip.subviews.firstIndex { $0 === browser.navBar }), "It comes from under the page bar")
        XCTAssertEqual(browser.selectedFindBar.topInset, PlainNavBar.Metrics.height+BookmarksBar.height)
    }

    func testTheBarTakesThePageBarsColourInTheSameFade() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        _ = page(browser, "https://example.com/", "Example"); keep(browser)
        browser.layoutChrome()
        let green = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        browser.tabBar.setColor(green, animated: true)
        XCTAssertEqual(browser.bookmarksBar.color, browser.tabBar.color)
        let fade = try XCTUnwrap(browser.tabBar.layer?.animation(forKey: "color") as? CABasicAnimation)
        let same = try XCTUnwrap(browser.bookmarksBar.layer?.animation(forKey: "color") as? CABasicAnimation)
        XCTAssertEqual(same.beginTime, fade.beginTime, "They start together")
        XCTAssertEqual(same.duration, fade.duration)
        XCTAssertEqual(same.timingFunction, fade.timingFunction)
        XCTAssertEqual(browser.bookmarksBar.layer?.backgroundColor, green.cgColor)
        // At once when the page bar changes at once.
        browser.tabBar.setColor(.white, animated: false)
        XCTAssertEqual(browser.bookmarksBar.color, NSColor.white.usingColorSpace(.sRGB)!)
        XCTAssertNil(browser.bookmarksBar.layer?.animation(forKey: "color"))
    }

    func testAHoveredBookmarkIsTheBarsColourAShadeDeeper() throws {
        func hsb(_ color: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
            let c = color.usingColorSpace(.sRGB)!; return (c.hueComponent, c.saturationComponent, c.brightnessComponent)
        }
        let white = hsb(BookmarksBar.shade(of: .white))
        XCTAssertEqual(white.s, 0, accuracy: 0.001, "White goes grey, not tinted")
        XCTAssertLessThan(white.b, 0.96); XCTAssertGreaterThan(white.b, 0.9)
        let yellow = NSColor(srgbRed: 1, green: 0.85, blue: 0.2, alpha: 1)
        XCTAssertEqual(hsb(BookmarksBar.shade(of: yellow)).h, hsb(yellow).h, accuracy: 0.001, "Its own hue")
        XCTAssertLessThan(hsb(BookmarksBar.shade(of: yellow)).b, hsb(yellow).b)
        let dark = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        XCTAssertGreaterThan(hsb(BookmarksBar.shade(of: dark)).b, hsb(dark).b, "On a dark bar, lighter")
    }

    func testAutoHiddenBarComesDownFromThePageBarAndGoesBackUp() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = page(browser, "https://example.com/", "Example")
        keep(browser)
        browser.setRiseSetting("autoHideBookmarksBar", true)
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height, "Hiding itself, it leaves the page where it was")
        let point = { (y: CGFloat) in browser.pageClip.convert(NSPoint(x: browser.pageClip.bounds.midX, y: y), to: nil) }
        browser.refreshBookmarksBar(pointer: point(200))
        XCTAssertTrue(browser.bookmarksBar.isHidden)
        XCTAssertFalse(browser.bookmarksBarHover.isHidden)
        XCTAssertNil(browser.bookmarksBarHover.hitTest(.zero))
        browser.refreshBookmarksBar(pointer: point(20))
        XCTAssertFalse(browser.bookmarksBar.isHidden)
        XCTAssertEqual(browser.bookmarksBar.frame.minY, PlainNavBar.Metrics.height)
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height, "Over the page, which doesn't move")
        browser.refreshBookmarksBar(pointer: point(PlainNavBar.Metrics.height+10))
        XCTAssertFalse(browser.bookmarksBar.isHidden, "Down, it stays while the pointer's in it")
        browser.refreshBookmarksBar(pointer: point(200))
        XCTAssertTrue(browser.bookmarksBar.isHidden)
        browser.refreshBookmarksBar(pointer: point(PlainNavBar.Metrics.height+10))
        XCTAssertTrue(browser.bookmarksBar.isHidden, "Where it would be doesn't bring it down: only the page bar does")
        let row = try XCTUnwrap(browser.riseSettingRows("appearance").first { $0["key"] as? String == "autoHideBookmarksBar" })
        XCTAssertEqual(row["value"] as? Bool, true)
        browser.setRiseSetting("bookmarkPlacement", "sidebar")
        XCTAssertNil(browser.riseSettingRows("appearance").first { $0["key"] as? String == "autoHideBookmarksBar" }, "Only for the bar")
        XCTAssertTrue(browser.bookmarksBar.isHidden); XCTAssertTrue(browser.bookmarksBarHover.isHidden)
    }

    func testSidebarBookmarksRollInWidenTheSidebarAndSwapSortForReturn() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        browser.setRiseSetting("bookmarkPlacement", "sidebar")
        _ = page(browser, "https://example.com/", "Example"); keep(browser)
        let sidebar = browser.sidebar!
        let width = sidebar.frame.width
        XCTAssertTrue(sidebar.bookmarksPane.isHidden); XCTAssertTrue(sidebar.bookmarksTitle.isHidden)
        browser.toggleSidebarBookmarks()
        XCTAssertTrue(browser.showsSidebarBookmarks)
        XCTAssertFalse(sidebar.bookmarksPane.isHidden); XCTAssertFalse(sidebar.bookmarksTitle.isHidden)
        XCTAssertEqual(sidebar.bookmarksTitle.stringValue, "Bookmarks")
        XCTAssertEqual(sidebar.bookmarksPane.rows.count, 1)
        let expected = width+(max(width, SidebarWidth.wide)-width)*SidebarRollMotion.widening
        XCTAssertEqual(sidebar.frame.width, expected, accuracy: 0.5, "Halfway to its Control-Command width")
        XCTAssertTrue(sidebar.cleanUpButton.showsReturn)
        XCTAssertEqual(sidebar.cleanUpButton.hoverHint?.text, SidebarSortButton.returnText)
        XCTAssertGreaterThan(sidebar.subviews.firstIndex { $0 === sidebar.bookmarksPane }!, sidebar.subviews.firstIndex { $0 === sidebar.scroll }!,
                             "Over the tabs")
        XCTAssertNotNil(sidebar.scroll.layer?.animation(forKey: SidebarRollMotion.key), "The tabs stay rolled out under them")
        XCTAssertNil(sidebar.bookmarksPane.layer?.backgroundColor, "Clear over the sidebar's material")
        XCTAssertLessThan(sidebar.bookmarksPane.frame.maxY, sidebar.cleanUpButton.frame.minY, "The bottom buttons stay")
        sidebar.cleanUpButton.performClick(nil)
        XCTAssertFalse(browser.showsSidebarBookmarks)
        XCTAssertTrue(sidebar.bookmarksPane.isHidden)
        XCTAssertNil(sidebar.scroll.layer?.animation(forKey: SidebarRollMotion.key), "The tabs are back")
        XCTAssertEqual(sidebar.frame.width, width, accuracy: 0.5)
        XCTAssertFalse(sidebar.cleanUpButton.showsReturn)
        XCTAssertEqual(sidebar.cleanUpButton.hoverHint?.text, SidebarSortButton.sortText)
    }

    func testTheHoldShortcutShowsBookmarksUntilItsModifiersAreLetGo() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        browser.setRiseSetting("bookmarkPlacement", "sidebar")
        let window = try XCTUnwrap(browser.window)
        func key(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: "b", charactersIgnoringModifiers: "b", isARepeat: repeating, keyCode: 11)!
        }
        func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        }
        XCTAssertTrue(browser.handleBookmarksHoldEvent(key(.keyDown, [.control, .option])))
        XCTAssertTrue(browser.showsSidebarBookmarks); XCTAssertTrue(browser.sidebarBookmarks.isHeld)
        XCTAssertTrue(browser.sidebar.bookmarksPane.controlClickOpens)
        XCTAssertTrue(browser.handleBookmarksHoldEvent(key(.keyDown, [.control, .option], repeating: true)))
        XCTAssertTrue(browser.handleBookmarksHoldEvent(key(.keyUp, [.control, .option])))
        XCTAssertTrue(browser.showsSidebarBookmarks, "Letting go of B alone keeps them while ⌃⌥ are held")
        XCTAssertFalse(browser.handleBookmarksHoldEvent(flags([.control, .option, .command])))
        XCTAssertTrue(browser.showsSidebarBookmarks, "⌘ joining, for a ⌘-click, keeps them")
        XCTAssertFalse(browser.handleBookmarksHoldEvent(flags([.control])))
        XCTAssertFalse(browser.showsSidebarBookmarks)
        XCTAssertFalse(browser.sidebarBookmarks.isHeld)
        browser.setRiseSetting("bookmarkPlacement", "bar")
        XCTAssertFalse(browser.handleBookmarksHoldEvent(key(.keyDown, [.control, .option])), "Only for bookmarks in the sidebar")
        XCTAssertFalse(browser.showsSidebarBookmarks)
    }

    func testABookmarkOpensBesideTheCurrentTabOrAtTheTopWithCommand() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let bookmark = browser.bookmarks.add(url: URL(string: "https://example.com/kept")!, title: "Kept", icon: nil, darkIcon: nil)
        let a = page(browser, "https://a.example/", "A"), b = page(browser, "https://b.example/", "B")
        _ = page(browser, "https://c.example/", "C")
        browser.select(a.id)
        browser.openBookmark(bookmark.id, atTop: false)
        XCTAssertEqual(browser.selectedTab?.url, bookmark.url)
        XCTAssertEqual(browser.tabs.map(\.url?.host), ["c.example", "b.example", "example.com", "a.example"], "Right above the tab it was opened from")
        browser.select(b.id)
        browser.openBookmark(bookmark.id, atTop: true)
        XCTAssertEqual(browser.tabs.first?.url, bookmark.url, "With ⌘, at the top")
        let empty = browser.addTab()
        let count = browser.tabs.count
        browser.openBookmark(bookmark.id, atTop: false)
        XCTAssertEqual(browser.tabs.count, count, "An empty new tab takes it itself")
        XCTAssertEqual(empty.url, bookmark.url)
    }

    func testBookmarksReorderAndTheMenuListsThem() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.bookmarks.add(url: URL(string: "https://one.example/")!, title: "One", icon: nil, darkIcon: nil)
        _ = browser.bookmarks.add(url: URL(string: "https://two.example/")!, title: "Two", icon: nil, darkIcon: nil)
        browser.bookmarks.move(first.id, to: 1)
        XCTAssertEqual(browser.bookmarks.items.map(\.title), ["Two", "One"])
        XCTAssertEqual(browser.bookmarksBar.items.map(\.title), ["Two", "One"])
        XCTAssertEqual(browser.sidebar.bookmarksPane.rows.map(\.titleField.stringValue), ["Two", "One"])
        browser.bookmarks.rename(first.id, to: "Uno")
        XCTAssertEqual(browser.bookmarksBar.items.last?.title, "Uno")
        browser.bookmarks.remove(first.id)
        XCTAssertEqual(browser.bookmarksBar.items.map(\.title), ["Two"])
    }
}
