import XCTest
import AppKit
@testable import Rise

final class TabSwitchingTests: XCTestCase {
    @MainActor private func makeBrowser() -> BrowserController {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        return BrowserController(sessionURL: session, restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.cancelTabSwitch(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.page.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func key(_ browser: BrowserController, code: UInt16 = 48, modifiers: NSEvent.ModifierFlags = .control) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: browser.window!.windowNumber, context: nil,
                         characters: code == 53 ? "\u{1b}" : "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)!
    }
    @MainActor private func releaseControl(_ browser: BrowserController) {
        let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: browser.window!.windowNumber, context: nil,
                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        browser.window!.sendEvent(event)
    }
    @MainActor func testQuickControlTabUsesMRUWithoutShowingUIOrLateFlash() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab(), third = browser.addTab()
        browser.select(first.id) // MRU: first, third, second.
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: key(browser)))
        XCTAssertEqual(browser.tabSwitchCandidate, third.id)
        XCTAssertEqual(browser.selectedID, first.id)
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        releaseControl(browser)
        XCTAssertEqual(browser.selectedID, third.id)
        XCTAssertFalse(browser.isSwitchingTabs)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: key(browser)))
        releaseControl(browser)
        XCTAssertEqual(browser.selectedID, first.id)
        XCTAssertEqual(browser.tabs.map(\.id), [third.id, second.id, first.id])
        // A second Tab before it shows asks for the switcher, which shows at once.
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: key(browser)))
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        XCTAssertTrue(browser.window!.performKeyEquivalent(with: key(browser)))
        XCTAssertFalse(browser.tabSwitcher.isHidden, "Pressed twice, it shows without waiting")
    }
    @MainActor func testHeldControlShowsCardsAndShiftCyclesFrozenOrderBeforeCommit() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab(), third = browser.addTab()
        browser.select(first.id)
        browser.window!.sendEvent(key(browser))
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        try await Task.sleep(for: .milliseconds(170))
        XCTAssertFalse(browser.tabSwitcher.isHidden)
        XCTAssertEqual(browser.tabSwitcher.cards.map(\.tabID), [first.id, third.id, second.id])
        XCTAssertEqual(browser.selectedID, first.id)
        browser.window!.sendEvent(key(browser))
        XCTAssertEqual(browser.tabSwitchCandidate, second.id)
        browser.window!.sendEvent(key(browser, modifiers: [.control, .shift]))
        XCTAssertEqual(browser.tabSwitchCandidate, third.id)
        releaseControl(browser)
        XCTAssertEqual(browser.selectedID, third.id)
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        XCTAssertTrue(browser.tabSwitchBackdrop.isHidden)
    }
    @MainActor func testEscapeAndDeactivationCancelWithoutSelectingCandidate() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        browser.addTab(); let source = browser.addTab()
        browser.advanceTabSwitch(1)
        try await Task.sleep(for: .milliseconds(160))
        browser.window!.sendEvent(key(browser, code: 53, modifiers: []))
        releaseControl(browser)
        XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        browser.advanceTabSwitch(1)
        browser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(browser.isSwitchingTabs)
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        XCTAssertEqual(browser.selectedID, source.id)
    }
    @MainActor func testClosedTabsCannotBeCommittedAndSingleTabNeverShowsSwitcher() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab()
        browser.advanceTabSwitch(1)
        XCTAssertFalse(browser.isSwitchingTabs)
        browser.addTab()
        browser.advanceTabSwitch(1)
        XCTAssertEqual(browser.tabSwitchCandidate, first.id)
        browser.closeTab(first.id)
        releaseControl(browser)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.tabSwitcher.isHidden)
        XCTAssertFalse(browser.isSwitchingTabs)
    }
    @MainActor func testTheSwitcherShowsAtMostItsLimitInRowsOfFiveAllInSightAndThePointerPicks() async throws {
        _ = NSApplication.shared
        let suite = "Rise.TabSwitchingTests.\(UUID().uuidString)"
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        defer { clean(browser); UserDefaults.standard.removePersistentDomain(forName: suite) }
        for _ in 0..<13 { browser.addTab() }
        browser.toggleSidebar()
        func open() async throws {
            browser.advanceTabSwitch(1)
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertFalse(browser.tabSwitcher.isHidden)
        }
        try await open()
        XCTAssertEqual(browser.tabSwitcher.cards.count, 5, "Five unless set otherwise")
        XCTAssertEqual(Set(browser.tabSwitcher.cards.map(\.frame.minY)).count, 1, "In one row")
        browser.cancelTabSwitch()

        browser.setTabSwitcherLimit(12)
        browser.window?.setContentSize(NSSize(width: 900, height: 600))
        try await open()
        let cards = browser.tabSwitcher.cards, switcher = browser.tabSwitcher
        XCTAssertEqual(cards.count, 12)
        XCTAssertEqual(Dictionary(grouping: cards, by: \.frame.minY).values.map(\.count).sorted(), [2, 5, 5], "Five to a row")
        XCTAssertTrue(cards.allSatisfy { switcher.bounds.contains($0.convert($0.bounds, to: switcher)) }, "No card out of sight")
        XCTAssertTrue(browser.root.bounds.contains(switcher.frame))
        XCTAssertEqual(switcher.layer?.cornerRadius, 27)
        XCTAssertEqual(cards[0].layer?.cornerRadius, 15, "Concentric with the switcher's corners, inside its padding")

        let hovered = cards[7]
        browser.pickTabSwitchCard(hovered.tabID)
        XCTAssertEqual(browser.tabSwitchCandidate, hovered.tabID, "The pointer picks a card as Tab does")
        hovered.performClick(nil)
        XCTAssertEqual(browser.selectedID, hovered.tabID)
        XCTAssertFalse(browser.sidebarVisible)
        XCTAssertTrue(browser.tabSwitcher.isHidden)

        browser.setTabSwitcherLimit(40)
        XCTAssertEqual(browser.tabSwitcherLimit, 15, "At most 15")
        browser.setTabSwitcherLimit(1)
        XCTAssertEqual(browser.tabSwitcherLimit, 2, "At least 2")
    }
}
