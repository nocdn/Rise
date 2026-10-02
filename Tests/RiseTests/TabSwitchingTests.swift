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
        browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
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
        XCTAssertEqual(browser.tabs.map(\.id), [first.id, second.id, third.id])
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
    @MainActor func testPreviewUsesAnActualWebKitSnapshot() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        tab.webView.loadHTMLString("<!doctype html><title>Thumbnail</title><style>html,body{margin:0;background:#e06070}</style><p>Preview page</p>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while tab.webView.title != "Thumbnail" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tab.webView.title, "Thumbnail")
        tab.captureThumbnail()
        while tab.thumbnail == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let image = try XCTUnwrap(tab.thumbnail)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let color = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, color.greenComponent + 0.2)
        XCTAssertGreaterThan(image.size.width, 100)
    }
    @MainActor func testManyTabsScrollHighlightedCardIntoViewWithSidebarClosed() async throws {
        let browser = makeBrowser(); defer { clean(browser) }
        for _ in 0..<10 { browser.addTab() }
        browser.toggleSidebar()
        browser.advanceTabSwitch(-1)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(browser.tabSwitcher.isHidden)
        XCTAssertEqual(browser.tabSwitcher.cards.count, 10)
        let selected = try XCTUnwrap(browser.tabSwitcher.cards.first { $0.tabID == browser.tabSwitchCandidate })
        XCTAssertTrue(browser.tabSwitcher.scroll.contentView.bounds.contains(selected.frame))
        let target = selected.tabID
        selected.performClick(nil)
        XCTAssertEqual(browser.selectedID, target)
        XCTAssertFalse(browser.sidebarVisible)
        XCTAssertTrue(browser.tabSwitcher.isHidden)
    }
}
