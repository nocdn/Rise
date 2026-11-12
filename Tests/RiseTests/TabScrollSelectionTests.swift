import XCTest
import AppKit
@testable import Rise

final class TabScrollSelectionTests: XCTestCase {
    @MainActor private func browser(count: Int = 4) -> BrowserController {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false,
                                        preferences: UserDefaults(suiteName: "Rise.TabScrollTests.\(folder.lastPathComponent)")!)
        browser.window?.setContentSize(NSSize(width: 900, height: 500))
        browser.showWindow(nil)
        for _ in 0..<count { browser.addTab(background: true) }
        browser.select(browser.tabs[0].id)
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.cancelTabScroll(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
        UserDefaults.standard.removePersistentDomain(forName: "Rise.TabScrollTests.\(browser.sessionURL.deletingLastPathComponent().lastPathComponent)")
    }
    /// Each event comes `after` the last: by default as long as one at the acceleration's neutral
    /// speed takes, so it moves one for one.
    private var clock = ProcessInfo.processInfo.systemUptime
    private func scroll(_ y: Int32, x: Int32 = 0, precise: Bool = false, modifiers: CGEventFlags = .maskAlternate,
                        momentum: Int64 = 0, phase: Int64 = 0, after: TimeInterval? = nil) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                         wheel1: y, wheel2: x, wheel3: 0)!
        clock += after ?? Double(abs(y))/Double(TabScrollAcceleration.neutralSpeed)
        cg.timestamp = CGEventTimestamp(clock*1e9)
        cg.flags = modifiers
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return NSEvent(cgEvent: cg)!
    }
    @MainActor private func key(_ browser: BrowserController, type: NSEvent.EventType = .flagsChanged,
                               code: UInt16 = 58, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: browser.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code)!
    }
    @MainActor private func assertArrow(_ browser: BrowserController, at id: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(browser.sidebar.anchor(for: id), file: file, line: line), arrow = browser.tabScroll.arrow
        XCTAssertTrue(arrow.superview === browser.root, file: file, line: line)
        XCTAssertGreaterThan(arrow.frame.minX, browser.sidebar.convert(browser.sidebar.bounds, to: browser.root).maxX, file: file, line: line)
        XCTAssertEqual(arrow.frame.midY, row.convert(row.bounds, to: browser.root).midY, accuracy: 0.01, file: file, line: line)
        XCTAssertNil(arrow.hitTest(.zero), "The floating arrow cannot steal page clicks", file: file, line: line)
    }

    @MainActor func testWheelHighlightsInSidebarOrderAndReleaseSelectsOnlyOnce() async throws {
        let browser = browser(); defer { clean(browser) }
        let tabs = browser.tabs, window = try XCTUnwrap(browser.window)
        browser.select(tabs[1].id)
        let recent = browser.recentTabIDs
        var pageScrolls = 0
        (window as? BrowserWindow)?.historyScrollEvent = { _ in pageScrolls += 1; return true }
        window.sendEvent(scroll(-1))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[0].id, "The highlight moves opposite to ordinary scrolling")
        window.sendEvent(scroll(1)); window.sendEvent(scroll(1))
        XCTAssertEqual(browser.selectedID, tabs[1].id, "No page switching while scrolling")
        XCTAssertEqual(browser.recentTabIDs, recent, "No visits recorded for intermediate tabs")
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[2].id)
        XCTAssertEqual(browser.sidebar.rows[tabs[2].id]?.scrollFocus, true)
        try assertArrow(browser, at: tabs[2].id)
        let other = try XCTUnwrap(browser.sidebar.rows[tabs[0].id])
        other.pointerEnters()
        browser.tabHoverChanged(tabs[0].id, hovering: true)
        XCTAssertFalse(other.isHovered, "Only the scroll candidate lights up, not the row under the pointer")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(browser.tabHoverCards.shownID)
        XCTAssertEqual(pageScrolls, 0, "The page and history swipe never get these wheel events")
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[2].id)
        XCTAssertFalse(browser.isScrollingTabs)
        XCTAssertNil(browser.tabScroll.arrow.superview)
        XCTAssertNil(other.scrollFocus)
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[2].id)
        window.sendEvent(scroll(-1, modifiers: []))
        XCTAssertEqual(pageScrolls, 1, "Ordinary scrolling is unchanged")
    }

    @MainActor func testTrackpadAccumulatesIgnoresMomentumAndEscapeOrDeactivationCancels() throws {
        let browser = browser(); defer { clean(browser) }
        let tabs = browser.tabs, window = try XCTUnwrap(browser.window)
        var pageScrolls = 0
        (window as? BrowserWindow)?.historyScrollEvent = { _ in pageScrolls += 1; return true }
        window.sendEvent(scroll(18, precise: true))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[0].id)
        window.sendEvent(scroll(18, precise: true))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[1].id)
        window.sendEvent(scroll(36, precise: true, momentum: 1))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[2].id, "A flick's momentum carries on through the tabs")
        window.sendEvent(key(browser, type: .keyDown, code: 53, modifiers: .option))
        window.sendEvent(key(browser, type: .keyUp, code: 53, modifiers: .option))
        window.sendEvent(scroll(36, precise: true))
        XCTAssertFalse(browser.isScrollingTabs, "Escape cannot restart the choice until Option is released")
        XCTAssertNil(browser.tabScroll.arrow.superview)
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[0].id)

        window.sendEvent(scroll(36, precise: true))
        browser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[0].id)
        XCTAssertNil(browser.sidebar.scrollFocusID)

        window.sendEvent(scroll(36, precise: true, phase: 1)); window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[1].id)
        window.sendEvent(scroll(-20, precise: true, modifiers: [], phase: 2))
        window.sendEvent(scroll(0, precise: true, modifiers: [], phase: 4))
        window.sendEvent(scroll(-500, precise: true, modifiers: [], momentum: 1))
        XCTAssertEqual(pageScrolls, 0, "Neither the fingers still scrolling nor their momentum can scroll the newly chosen page")
        window.sendEvent(scroll(-1, modifiers: []))
        XCTAssertEqual(pageScrolls, 1)
    }

    @MainActor func testSlowMovementStepsThroughFewerTabsThanQuickMovementOverTheSameDistance() throws {
        func tabsMoved(after: TimeInterval) throws -> Int {
            let browser = browser(count: 30); defer { clean(browser) }
            let window = try XCTUnwrap(browser.window)
            // 360 points of finger travel, in 10 point steps.
            window.sendEvent(scroll(10, precise: true, phase: 1, after: after))
            for _ in 1..<36 { window.sendEvent(scroll(10, precise: true, phase: 2, after: after)) }
            return try XCTUnwrap(browser.sidebar.scrollTabIDs.firstIndex(of: try XCTUnwrap(browser.sidebar.scrollFocusID)))
        }
        let slow = try tabsMoved(after: 0.05), even = try tabsMoved(after: 0.01), quick = try tabsMoved(after: 1.0/240)
        XCTAssertEqual(even, 10, "At the neutral speed, one tab every 36 points")
        XCTAssertLessThanOrEqual(slow, 4, "Slowly, much less far")
        XCTAssertGreaterThanOrEqual(quick, 15, "Quickly, much further")
    }

    @MainActor func testLettingGoMidFlickSwitchesWhereTheGlideComesToRest() async throws {
        let browser = browser(count: 6); defer { clean(browser) }
        let tabs = browser.tabs, window = try XCTUnwrap(browser.window)
        var pageScrolls = 0
        (window as? BrowserWindow)?.historyScrollEvent = { _ in pageScrolls += 1; return true }
        window.sendEvent(scroll(36, precise: true, phase: 1))
        window.sendEvent(scroll(0, precise: true, phase: 4))
        window.sendEvent(scroll(36, precise: true, momentum: 1))
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[0].id, "Still gliding: no switch yet")
        window.sendEvent(scroll(36, precise: true, modifiers: [], momentum: 2))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[3].id)
        window.sendEvent(scroll(0, precise: true, modifiers: [], momentum: 3))
        XCTAssertEqual(browser.selectedID, tabs[3].id, "Switches where it came to rest")
        XCTAssertEqual(pageScrolls, 0)

        // Lifted just before letting go, momentum that never comes doesn't hold the switch up.
        window.sendEvent(scroll(36, precise: true, phase: 1))
        window.sendEvent(scroll(0, precise: true, phase: 4))
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[3].id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(browser.selectedID, tabs[4].id)
        XCTAssertFalse(browser.isScrollingTabs)
    }

    @MainActor func testPinnedTabsAreLeftOutSplitHalvesAreInAndHiddenSidebarRevealsTheCandidate() throws {
        let browser = browser(count: 30); defer { clean(browser) }
        let tabs = browser.tabs, window = try XCTUnwrap(browser.window)
        browser.pinTab(tabs[0].id)
        // From a pinned tab, the choice starts at the list's first tab.
        browser.select(tabs[0].id)
        window.sendEvent(scroll(-1))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[1].id)
        XCTAssertNotEqual(browser.sidebar.pinnedView.tiles[tabs[0].id]?.scrollFocus, true)
        browser.cancelTabScroll(); window.sendEvent(key(browser))

        browser.select(tabs[1].id); browser.showSplit(tabs[2]); browser.select(tabs[1].id)
        XCTAssertEqual(Array(browser.sidebar.scrollTabIDs.prefix(2)), [tabs[1].id, tabs[2].id], "Pinned tabs aren't in the list")
        window.sendEvent(scroll(-1))
        XCTAssertEqual(browser.sidebar.scrollFocusID, tabs[1].id, "It stops at the list's top, not the pinned tabs")
        try assertArrow(browser, at: tabs[1].id)
        window.sendEvent(scroll(1))
        XCTAssertEqual(browser.sidebar.rows[tabs[2].id]?.scrollFocus, true, "The split's right half can be picked")
        try assertArrow(browser, at: tabs[2].id)
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs[2].id)

        browser.toggleSidebar()
        window.sendEvent(scroll(2000, precise: true))
        XCTAssertTrue(browser.isSidebarFloating)
        XCTAssertTrue(browser.holdsFloatingSidebar)
        try assertArrow(browser, at: tabs.last!.id)
        let row = try XCTUnwrap(browser.sidebar.displayedRow(for: tabs.last!.id))
        XCTAssertTrue(browser.sidebar.scroll.contentView.bounds.contains(row.frame), "The distant candidate stays in view")
        XCTAssertNil(browser.sidebar.chosenPill.direction, "The current-tab pill cannot cover the candidate")
        window.sendEvent(key(browser))
        XCTAssertEqual(browser.selectedID, tabs.last!.id)
        XCTAssertFalse(browser.sidebarVisible, "A collapsed sidebar is not permanently opened")
    }

    @MainActor func testScrollingKeepsTwoRowsBeyondTheHighlightUntilTheListsEnds() throws {
        let browser = browser(count: 30); defer { clean(browser) }
        let tabs = browser.tabs, window = try XCTUnwrap(browser.window), sidebar: SidebarView = browser.sidebar
        let clip = sidebar.scroll.contentView
        window.sendEvent(scroll(12*36, precise: true))
        XCTAssertTrue(clip.bounds.contains(try XCTUnwrap(sidebar.displayedRow(for: tabs[14].id)).frame), "Two rows remain below the highlight")
        let lowerY = browser.tabScroll.arrow.frame.midY
        window.sendEvent(scroll(36, precise: true))
        XCTAssertEqual(browser.tabScroll.arrow.frame.midY, lowerY, accuracy: 0.01, "The list moves, keeping the arrow at the third row from the bottom")
        try assertArrow(browser, at: tabs[13].id)

        for _ in 0..<7 { window.sendEvent(scroll(-36, precise: true)) }
        let upperY = browser.tabScroll.arrow.frame.midY
        window.sendEvent(scroll(-36, precise: true))
        XCTAssertEqual(browser.tabScroll.arrow.frame.midY, upperY, accuracy: 0.01, "The same breathing room at the top")
        XCTAssertTrue(clip.bounds.contains(try XCTUnwrap(sidebar.displayedRow(for: tabs[3].id)).frame))
        try assertArrow(browser, at: tabs[5].id)

        window.sendEvent(scroll(-2000, precise: true))
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.01)
        try assertArrow(browser, at: tabs[0].id)
        window.sendEvent(scroll(2000, precise: true))
        XCTAssertEqual(clip.bounds.maxY, sidebar.rowsHost.bounds.height, accuracy: 0.01)
        try assertArrow(browser, at: tabs.last!.id)
        XCTAssertEqual(browser.selectedID, tabs[0].id, "Still no page switching until release")
    }

    @MainActor func testModifierSettingAndClosingCandidateLeaveNoStaleSelection() throws {
        let browser = browser(); defer { clean(browser) }
        let window = try XCTUnwrap(browser.window), source = browser.selectedID
        XCTAssertFalse(browser.handleTabScrollEvent(scroll(0, x: -30, precise: true)), "Horizontal gestures stay with the page")
        XCTAssertFalse(browser.handleTabScrollEvent(scroll(-1, modifiers: [.maskAlternate, .maskShift])))
        browser.setRiseSetting("tabScrollModifier", "off")
        XCTAssertFalse(browser.handleTabScrollEvent(scroll(-1)))
        browser.setRiseSetting("tabScrollModifier", "control")
        XCTAssertEqual(browser.riseSettingRows("tabs").first { $0["key"] as? String == "tabScrollModifier" }?["value"] as? String, "control")
        XCTAssertFalse(browser.handleTabScrollEvent(scroll(-1)))
        window.sendEvent(scroll(1, modifiers: .maskControl))
        let candidate = try XCTUnwrap(browser.tabScroll.candidate)
        browser.closeTab(candidate)
        window.sendEvent(key(browser, code: 59))
        XCTAssertEqual(browser.selectedID, source)
        XCTAssertNil(browser.sidebar.scrollFocusID)
    }
}
