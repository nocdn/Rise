import XCTest
import AppKit
@testable import Rise

final class BrowserMenuTests: XCTestCase {
    @MainActor private func makeBrowser() -> BrowserController {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.cancelTabSwitch(); browser.hidePalette(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func digit(_ number: Int, in browser: BrowserController, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                               windowNumber: browser.window!.windowNumber, context: nil, characters: String(number),
                               charactersIgnoringModifiers: String(number), isARepeat: false, keyCode: codes[number-1])!
    }
    @MainActor private func menu(_ title: String) -> NSMenu { NSApp.mainMenu!.items.first { $0.title == title }!.submenu! }
    @MainActor private func entry(_ action: Selector, in title: String) -> NSMenuItem {
        menu(title).items.first { $0.action == action }!
    }

    @MainActor func testCommandDigitsChooseFirstNineTabsWhileEditingAndAfterReordering() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        for _ in 0..<11 { browser.addTab() }
        let order = browser.tabs.map(\.id)
        for number in 1...9 {
            browser.focusAddress()
            XCTAssertNotNil(browser.palette.input.currentEditor())
            XCTAssertTrue(browser.window!.performKeyEquivalent(with: digit(number, in: browser)))
            XCTAssertEqual(browser.selectedID, order[number-1])
            XCTAssertFalse(browser.palette.isPresented)
        }
        XCTAssertNotEqual(browser.selectedID, order.last, "⌘9 means ninth, not last")
        browser.reorderTabs(Array(order.reversed()), animated: false)
        browser.window!.sendEvent(digit(1, in: browser))
        XCTAssertEqual(browser.selectedID, order.last)
        browser.advanceTabSwitch(1)
        browser.window!.sendEvent(digit(2, in: browser))
        XCTAssertFalse(browser.isSwitchingTabs)
        XCTAssertEqual(browser.selectedID, browser.tabs[1].id)
    }

    @MainActor func testAbsentNumberDoesNothingAndModifiedDigitsAreLeftAlone() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        XCTAssertTrue(browser.handleTabSwitchEvent(digit(9, in: browser)))
        XCTAssertEqual(browser.selectedID, tab.id)
        for modifiers: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(browser.handleTabSwitchEvent(digit(1, in: browser, modifiers: modifiers)))
        }
    }

    @MainActor func testNumberedMenuItemsFollowSelectionRenamesReordersAndClosedTabs() {
        let browser = makeBrowser(); defer { clean(browser) }
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        for _ in 0..<10 { browser.addTab() }
        let numbered = menu("Tabs").items.filter { $0.action == #selector(BrowserController.selectNumberedTab(_:)) }
        XCTAssertEqual(numbered.count, 9)
        browser.tabs[8].title = "Ninth page"
        menu("Tabs").update()
        XCTAssertEqual(numbered[8].title, "9. Ninth page")
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: digit(9, in: browser)))
        XCTAssertEqual(browser.selectedID, browser.tabs[8].id)
        menu("Tabs").update(); XCTAssertEqual(numbered[8].state, .on)
        let reordered = Array(browser.tabs.map(\.id).reversed())
        browser.reorderTabs(reordered, animated: false)
        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: digit(1, in: browser)))
        XCTAssertEqual(browser.selectedID, reordered[0])
        for tab in Array(browser.tabs.dropFirst(2)) { browser.closeTab(tab.id) }
        menu("Tabs").update()
        XCTAssertTrue(numbered[1].isEnabled); XCTAssertFalse(numbered[2].isEnabled)
        XCTAssertFalse(numbered[8].isEnabled); XCTAssertEqual(numbered[8].state, .off)
    }

    @MainActor func testMenuAvailabilityTracksNavigationPinningAndEmptyBrowser() {
        let browser = makeBrowser(); defer { clean(browser) }
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let first = browser.addTab()
        first.open(URL(string: "https://example.invalid/first")!, title: "First")
        let back = entry(#selector(BrowserController.goBack), in: "History")
        XCTAssertFalse(browser.validateMenuItem(back))
        first.page.load(URL(string: "https://example.invalid/second")!)
        XCTAssertTrue(browser.validateMenuItem(back))
        browser.goBack()
        XCTAssertTrue(browser.validateMenuItem(entry(#selector(BrowserController.goForward), in: "History")))
        let pin = entry(#selector(BrowserController.pinCurrentTab), in: "Tabs")
        browser.pinCurrentTab(); XCTAssertTrue(browser.validateMenuItem(pin)); XCTAssertEqual(pin.title, "Unpin Tab")
        browser.closeCurrentTab()
        for (action, title) in [(#selector(BrowserController.closeCurrentTab), "File"),
                                (#selector(BrowserController.shareCurrentPage), "File"),
                                (#selector(BrowserController.reload), "View"),
                                (#selector(BrowserController.zoomIn), "View"),
                                (#selector(BrowserController.showFind), "Edit")] {
            XCTAssertFalse(browser.validateMenuItem(entry(action, in: title)))
        }
        XCTAssertTrue(browser.validateMenuItem(entry(#selector(BrowserController.reopenTab), in: "File")))
        browser.reopenTab(); XCTAssertEqual(browser.selectedID, first.id)
    }

    @MainActor func testBulkCloseKeepsPinnedTabsAndVisibleSplitAndCanReopenAnyClosedTab() {
        let browser = makeBrowser(); defer { clean(browser) }
        let old = NSApp.mainMenu; defer { NSApp.mainMenu = old }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let bottom = browser.addTab(), pinned = browser.addTab(), current = browser.addTab(), partner = browser.addTab()
        pinned.pinned = true; browser.select(current.id); browser.showSplit(partner)
        XCTAssertEqual(browser.closableTabsBelow.map(\.id), [bottom.id])
        browser.closeTabsBelow()
        XCTAssertEqual(Set(browser.tabs.map(\.id)), Set([current.id, pinned.id, partner.id]))
        let extra = browser.addTab(); browser.select(current.id)
        browser.closeOtherTabs()
        XCTAssertFalse(browser.tabs.contains { $0.id == extra.id })
        XCTAssertEqual(browser.splitTab?.id, partner.id)
        XCTAssertEqual(browser.selectedID, current.id)
        let recent = menu("History").items.first { $0.submenu?.identifier?.rawValue == "recentlyClosedTabs" }!.submenu!
        delegate.menuNeedsUpdate(recent)
        XCTAssertEqual(recent.items.count, 2)
        recent.performActionForItem(at: 1)
        XCTAssertEqual(browser.selectedID, bottom.id)
        XCTAssertEqual(browser.closedTabs.map(\.id), [extra.id])
        delegate.menuNeedsUpdate(recent); recent.performActionForItem(at: 0)
        delegate.menuNeedsUpdate(recent)
        XCTAssertFalse(recent.items[0].isEnabled)
        XCTAssertEqual(recent.items[0].title, "No Recently Closed Tabs")
    }
}
