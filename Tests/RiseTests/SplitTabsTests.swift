import XCTest
import AppKit
import RiseCore
@testable import Rise

final class SplitTabsTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testPairStaysGroupedWhenInactiveAndEachHalfRestoresFixedPaneOrder() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let group = try XCTUnwrap(browser.splitGroups.first)
        let row = try XCTUnwrap(browser.sidebar.splitRows[group.id])
        XCTAssertEqual(browser.sidebar.orderedIDs, [left.id, other.id])
        XCTAssertTrue(row.left.superview === row && row.right.superview === row)
        XCTAssertTrue(row.divider.isHidden)
        let leftFrame = left.webView.frame, rightFrame = right.webView.frame
        browser.select(other.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.splitGroups, [group])
        XCTAssertFalse(row.divider.isHidden)
        XCTAssertFalse(row.left.selected); XCTAssertFalse(row.right.selected)
        XCTAssertNil(left.webView.superview); XCTAssertNil(right.webView.superview)
        row.right.performClick(nil); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.selectedID, right.id)
        XCTAssertEqual(browser.splitTab?.id, left.id)
        XCTAssertTrue(row.left.selected && row.right.selected)
        XCTAssertEqual(left.webView.frame, leftFrame); XCTAssertEqual(right.webView.frame, rightFrame)
        XCTAssertTrue(left.webView.superview === browser.pageClip && right.webView.superview === browser.pageClip)
        XCTAssertEqual(browser.sidebar.selectedTabShadow.frame, row.convert(row.bounds, to: browser.sidebar))
        row.left.performClick(nil)
        XCTAssertEqual(browser.selectedID, left.id)
        XCTAssertEqual(left.webView.frame, leftFrame); XCTAssertEqual(right.webView.frame, rightFrame)
    }
    @MainActor func testClickingRightPageFocusesItWithoutReplacingEitherWebView() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        let leftFrame = left.webView.frame, rightFrame = right.webView.frame
        let point = right.webView.convert(NSPoint(x: 100, y: 100), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        browser.window?.sendEvent(event)
        XCTAssertEqual(browser.selectedID, right.id)
        XCTAssertEqual(left.webView.frame, leftFrame); XCTAssertEqual(right.webView.frame, rightFrame)
        XCTAssertTrue(left.webView.superview === browser.pageClip && right.webView.superview === browser.pageClip)
        XCTAssertEqual(browser.activeSplitGroup?.rightID, right.id)
    }
    @MainActor func testClosingOrSeparatingPairLeavesUsableStandaloneTabs() {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        browser.closeTab(right.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.selectedID, left.id)
        XCTAssertTrue(browser.splitGroups.isEmpty); XCTAssertTrue(browser.sidebar.splitRows.isEmpty)
        XCTAssertEqual(left.webView.frame, browser.pageClip.bounds)
        XCTAssertFalse(browser.sidebar.rows[left.id]!.isSplitMember)
        browser.showSplit(other); browser.select(other.id)
        browser.separateSplit(containing: left.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertTrue(browser.splitGroups.isEmpty)
        XCTAssertEqual(browser.selectedID, other.id)
        XCTAssertEqual(other.webView.frame, browser.pageClip.bounds)
        XCTAssertTrue(browser.sidebar.rows[left.id]?.superview === browser.sidebar.rowsHost)
        XCTAssertTrue(browser.sidebar.rows[other.id]?.superview === browser.sidebar.rowsHost)
    }
    @MainActor func testMultiplePairsRestoreAndRegroupWithoutDuplicateMembership() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(), c = browser.addTab(), d = browser.addTab(), other = browser.addTab()
        browser.select(a.id); browser.showSplit(b)
        browser.select(c.id); browser.showSplit(d)
        browser.select(other.id); browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.saveWork?.cancel(); restored.tabs.forEach { $0.webView.stopLoading() }; restored.window?.orderOut(nil) }
        XCTAssertEqual(restored.splitGroups, browser.splitGroups)
        XCTAssertEqual(restored.sidebar.splitRows.count, 2)
        XCTAssertNil(restored.activeSplitGroup)
        restored.select(d.id)
        XCTAssertEqual(restored.visibleTabIDs, [c.id, d.id])
        browser.select(a.id); browser.showSplit(c); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.splitGroups.count, 1)
        XCTAssertEqual(browser.visibleTabIDs, [a.id, c.id])
        XCTAssertEqual(browser.sidebar.orderedIDs.count, 4)
        XCTAssertFalse(browser.sidebar.rows[b.id]!.isSplitMember)
        XCTAssertFalse(browser.sidebar.rows[d.id]!.isSplitMember)
    }
}
