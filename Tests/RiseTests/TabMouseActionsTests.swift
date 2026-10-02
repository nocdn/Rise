import XCTest
import AppKit
@testable import Rise

final class TabMouseActionsTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func event(_ type: NSEvent.EventType, in view: NSView) -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        // The AppKit factory defaults to button zero even for "other mouse".
        if type == .otherMouseDown || type == .otherMouseUp {
            let cg = event.cgEvent!
            cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            return NSEvent(cgEvent: cg)!
        }
        return event
    }
    @MainActor func testMiddleClickOnFaviconClosesInactiveTabWithoutSelectingIt() throws {
        let browser = browser(); defer { clean(browser) }
        let target = browser.addTab(), selected = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(browser.sidebar.rows[target.id]?.icon)
        let down = event(.otherMouseDown, in: icon), up = event(.otherMouseUp, in: icon)
        XCTAssertEqual(down.buttonNumber, 2)
        browser.window?.sendEvent(down)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.selectedID, selected.id)
        browser.window?.sendEvent(up)
        XCTAssertEqual(browser.tabs.map(\.id), [selected.id])
        XCTAssertEqual(browser.selectedID, selected.id)
        XCTAssertEqual(browser.closedTabs.last?.id, target.id)
    }
    @MainActor func testMiddleClickOnSplitTitleClosesOnlyThatHalf() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(browser.sidebar.rows[right.id]?.titleField)
        let down = event(.otherMouseDown, in: title), up = event(.otherMouseUp, in: title)
        browser.window?.sendEvent(down); browser.window?.sendEvent(up)
        XCTAssertEqual(browser.tabs.map(\.id), [left.id])
        XCTAssertEqual(browser.selectedID, left.id)
        XCTAssertTrue(browser.splitGroups.isEmpty)
        XCTAssertEqual(left.webView.frame, browser.pageClip.bounds)
    }
    @MainActor func testReleasingElsewhereOrWithoutPressDoesNotCloseTabs() throws {
        let browser = browser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(browser.sidebar.rows[first.id])
        XCTAssertFalse(browser.handleMiddleTabClick(event(.otherMouseUp, in: row.titleField)))
        XCTAssertTrue(browser.handleMiddleTabClick(event(.otherMouseDown, in: row.titleField)))
        XCTAssertTrue(browser.handleMiddleTabClick(event(.otherMouseUp, in: browser.sidebar.rows[second.id]!.titleField)))
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertNil(browser.pendingMiddleTabID)
        XCTAssertFalse(browser.handleMiddleTabClick(event(.otherMouseDown, in: second.webView)))
        XCTAssertFalse(browser.handleMiddleTabClick(event(.rightMouseDown, in: row.titleField)))
    }
}
