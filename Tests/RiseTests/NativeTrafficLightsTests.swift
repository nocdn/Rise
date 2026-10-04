import XCTest
import AppKit
@testable import Rise

final class NativeTrafficLightsTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testNativeButtonsRetainTheirHierarchyActionsAndUnmodifiedAppearanceAcrossThemes() {
        let browser = browser(); defer { clean(browser) }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { browser.window!.standardWindowButton($0)! }
        let parents = buttons.map(\.superview), actions = buttons.map(\.action), targets = buttons.map(\.target), frames = buttons.map(\.frame)
        for theme in RiseTheme.allCases {
            browser.theme = theme; browser.update()
            for (i, button) in buttons.enumerated() {
                XCTAssertTrue(button.isEnabled); XCTAssertTrue(button.contentFilters.isEmpty)
                XCTAssertTrue(button.superview === parents[i]); XCTAssertEqual(button.action, actions[i])
                XCTAssertTrue(button.target === targets[i]); XCTAssertEqual(button.frame, frames[i])
            }
        }
    }
    @MainActor func testSidebarToggleKeepsNativeButtonsEnabledAndRestoresTheirSpacing() {
        let browser = browser(); defer { clean(browser) }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { browser.window!.standardWindowButton($0)! }
        let frames = buttons.map(\.frame)
        browser.toggleSidebar()
        XCTAssertTrue(buttons.allSatisfy { $0.isHidden && $0.isEnabled && $0.contentFilters.isEmpty })
        browser.toggleSidebar()
        XCTAssertTrue(buttons.allSatisfy { !$0.isHidden && $0.isEnabled && $0.contentFilters.isEmpty })
        XCTAssertEqual(buttons.map(\.frame), frames)
    }
    @MainActor func testNativeCloseButtonStillWorksWithoutHover() {
        let browser = browser(); defer { clean(browser) }
        let window = browser.window!
        window.setFrameAutosaveName(""); window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        browser.layoutChrome()
        let close = window.standardWindowButton(.closeButton)!
        XCTAssertTrue(close.contentFilters.isEmpty)
        let closed = expectation(forNotification: NSWindow.willCloseNotification, object: window)
        close.performClick(nil)
        wait(for: [closed], timeout: 2)
        XCTAssertFalse(window.isVisible)
    }
}
