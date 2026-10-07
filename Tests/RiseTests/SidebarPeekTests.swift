import XCTest
import AppKit
@testable import Rise

@MainActor final class SidebarPeekTests: XCTestCase {
    func testResizingSnapsToTheIdealWidth() {
        XCTAssertEqual(SidebarWidth.resized(to: SidebarWidth.ideal+SidebarWidth.snap-1), SidebarWidth.ideal)
        XCTAssertEqual(SidebarWidth.resized(to: SidebarWidth.ideal-SidebarWidth.snap+1), SidebarWidth.ideal)
        XCTAssertEqual(SidebarWidth.resized(to: SidebarWidth.ideal+20), SidebarWidth.ideal+20)
        XCTAssertEqual(SidebarWidth.resized(to: 1000), SidebarWidth.range.upperBound)
    }
    func testHoldingThePeekKeysOpensACollapsedSidebarWideAndTogglingKeepsItOpen() {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false)
        browser.toggleSidebar()
        XCTAssertFalse(browser.sidebarVisible)

        browser.sidebarPeekModifiersChanged(SidebarWidth.peekKeys)
        XCTAssertTrue(browser.sidebarVisible, "A collapsed sidebar opens as soon as the keys go down")
        XCTAssertEqual(browser.sidebar.frame.width, SidebarWidth.wide)
        browser.sidebarPeekModifiersChanged([])
        XCTAssertFalse(browser.sidebarVisible)
        XCTAssertEqual(browser.displayedSidebarWidth, browser.sidebarWidth)

        browser.sidebarPeekModifiersChanged(SidebarWidth.peekKeys)
        browser.toggleSidebar()
        XCTAssertTrue(browser.sidebarVisible, "Toggling during a peek keeps the sidebar open")
        browser.sidebarPeekModifiersChanged([])
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertEqual(browser.displayedSidebarWidth, browser.sidebarWidth, "Letting go narrows it back to its own width")
        browser.window?.close()
    }
}
