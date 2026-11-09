import XCTest
import AppKit
@testable import Rise

@MainActor final class PeekFindTests: XCTestCase {
    private func browser() -> BrowserController {
        _ = NSApplication.shared
        let folder = URL.temporaryDirectory.appendingPathComponent("RisePeekFind-\(UUID())")
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        browser.showWindow(nil)
        addTeardownBlock { @MainActor in
            browser.closePeek(); browser.finishPeekMotion(); browser.finishPeekPromotion()
            for owner in Array(browser.suspendedPeeks.keys) { browser.discardPeek(for: owner) }
            browser.findBars.values.forEach { $0.discard() }
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        return browser
    }

    func testFindUsesPeekCardInsetsAndFocusWithoutChangingBackgroundSearch() throws {
        let browser = browser(), source = browser.addTab()
        browser.showFind()
        let background = browser.findBar
        background.input.stringValue = "Background"
        browser.showPeek(url: URL(string: "about:blank?peek")!, animated: false)
        let peek = try XCTUnwrap(browser.peekTab)
        browser.showFind()
        let bar = browser.findBar, clip = try XCTUnwrap(browser.peekCard?.subviews.first)
        XCTAssertTrue(browser.findTab === peek)
        XCTAssertFalse(bar === background)
        XCTAssertTrue(bar.superview === clip)
        XCTAssertTrue(clip.subviews.last === bar, "Find sits above the live Peek page")
        XCTAssertNil(background.superview)
        XCTAssertTrue(background.isPresented)
        XCTAssertEqual(background.input.stringValue, "Background")
        XCTAssertEqual(bar.frame, clip.bounds)
        XCTAssertEqual(bar.topInset, PlainNavBar.Metrics.height, "It comes down from under the Peek's bar")
        bar.reattached(); bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.panel.frame.minY, PlainNavBar.Metrics.height+FindBar.top, accuracy: 0.01)
        XCTAssertEqual(bar.bounds.maxX-bar.panel.frame.maxX, FindBar.margin, accuracy: 0.01)
        XCTAssertTrue(browser.window?.firstResponder === bar.input.currentEditor())

        let card = try XCTUnwrap(browser.peekCard)
        browser.placeLivePeek(card, web: peek.page.view, at: card.frame.insetBy(dx: 20, dy: 30))
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.frame, clip.bounds, "Find follows live card resizing")
        XCTAssertEqual(bar.bounds.maxX-bar.panel.frame.maxX, FindBar.margin, accuracy: 0.01)
        bar.handleEscape()
        XCTAssertFalse(bar.isPresented)
        XCTAssertTrue(browser.peekTab === peek, "First Escape closes Find, not Peek")
        XCTAssertTrue(browser.window?.firstResponder === peek.page.view)
        XCTAssertTrue(background.isPresented)
        browser.closePeek()
        XCTAssertTrue(browser.findBar === background)
        XCTAssertTrue(background.superview === browser.root)
        XCTAssertTrue(browser.window?.firstResponder === source.page.view)
        XCTAssertNil(browser.findBars[peek.id])
    }

    func testMatchShortcutsAndReopeningUseOnlyPeeksOwnQuery() async throws {
        let browser = browser(); browser.addTab()
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        let background = browser.findBar
        var backgroundCalls = 0, directions: [PageFind.Direction] = []
        background.find = { _, _ in backgroundCalls += 1; return .init(count: 1, index: 0) }
        browser.showPeek(url: URL(string: "about:blank?peek")!, animated: false)
        try await Task.sleep(for: .milliseconds(80))
        browser.showFind()
        let bar = browser.findBar
        bar.find = { query, direction in
            XCTAssertEqual(query, "Peek query")
            directions.append(direction)
            return .init(count: 3, index: 1)
        }
        bar.input.stringValue = "Peek query"
        for (characters, flags) in [("g", NSEvent.ModifierFlags.command), ("G", [.command, .shift])] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: browser.window!.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 5)!
            XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: event))
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(directions.map(\.rawValue), ["next", "previous"])
        XCTAssertEqual(backgroundCalls, 0)
        browser.hideFind(); browser.findNext()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(bar.isPresented)
        XCTAssertEqual(directions.last, .restart)
        XCTAssertEqual(backgroundCalls, 0)
    }

    func testReturningToRetainedPeekRestoresItsFindAndClosingOwnerDiscardsIt() throws {
        let browser = browser(), source = browser.addTab(), other = browser.addTab()
        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank?peek")!, animated: false)
        let peek = try XCTUnwrap(browser.peekTab)
        browser.showFind()
        let bar = browser.findBar
        bar.input.stringValue = "Keep this"
        browser.select(other.id)
        XCTAssertNil(bar.superview)
        XCTAssertTrue(bar.isPresented)
        XCTAssertFalse(browser.findBar === bar)
        browser.select(source.id)
        XCTAssertTrue(browser.peekTab === peek)
        XCTAssertTrue(browser.findBar === bar)
        XCTAssertTrue(bar.superview === browser.peekCard?.subviews.first)
        XCTAssertEqual(bar.input.stringValue, "Keep this")
        browser.select(other.id); browser.closeTab(source.id)
        XCTAssertNil(browser.findBars[peek.id])
        XCTAssertNil(bar.superview)
        XCTAssertFalse(bar.isPresented)
    }

    func testReplacingPeekDiscardsItsBarAndEmptyBarClosesWhenSwitchingAway() throws {
        let browser = browser(), source = browser.addTab(), other = browser.addTab()
        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank?first")!, animated: false)
        let first = try XCTUnwrap(browser.peekTab)
        browser.showFind()
        let oldBar = browser.findBar
        browser.showPeek(url: URL(string: "about:blank?replacement")!, animated: false)
        XCTAssertNil(browser.findBars[first.id]); XCTAssertFalse(oldBar.isPresented)
        XCTAssertNil(oldBar.superview)
        browser.showFind()
        let empty = browser.findBar
        browser.select(other.id); browser.select(source.id)
        XCTAssertTrue(browser.findBar === empty)
        XCTAssertFalse(empty.isPresented)
    }

    func testPromotingPeekNeverLeavesFindInRetiredCard() throws {
        let browser = browser(), source = browser.addTab()
        browser.showPeek(url: URL(string: "about:blank?newtab")!, animated: false)
        let peek = try XCTUnwrap(browser.peekTab)
        browser.showFind()
        let bar = browser.findBar
        bar.input.stringValue = "Keep query"
        browser.promotePeek(peek, modifiers: .command, snapshots: (nil, nil))
        XCTAssertTrue(browser.selectedTab === peek)
        XCTAssertTrue(browser.findBar === bar)
        XCTAssertTrue(bar.superview === browser.root)
        XCTAssertEqual(bar.frame, browser.pageShadow.frame)

        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank?sametab")!, animated: false)
        let secondPeek = try XCTUnwrap(browser.peekTab)
        browser.showFind()
        let secondBar = browser.findBar
        browser.promotePeek(secondPeek, modifiers: [], snapshots: (nil, nil))
        XCTAssertNil(browser.findBars[secondPeek.id])
        XCTAssertNil(secondBar.superview)
        XCTAssertFalse(secondBar.isPresented)
        browser.showFind()
        XCTAssertTrue(browser.findBar.superview === browser.root)
        XCTAssertTrue(browser.findTab === source)
    }

    func testFindMenuRemainsEnabledForPeekOverAnEmptyTab() {
        let browser = browser(); browser.addTab()
        browser.showPeek(url: URL(string: "about:blank?peek")!, animated: false)
        for action in [#selector(BrowserController.showFind), #selector(BrowserController.findNext), #selector(BrowserController.findPrevious)] {
            XCTAssertTrue(browser.validateMenuItem(NSMenuItem(title: "Find", action: action, keyEquivalent: "")))
        }
    }
}
