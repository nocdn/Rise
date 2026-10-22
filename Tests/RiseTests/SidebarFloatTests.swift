import XCTest
import AppKit
@testable import Rise

@MainActor final class SidebarFloatTests: XCTestCase {
    private func collapsedBrowser() -> BrowserController {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false)
        browser.toggleSidebar()
        XCTAssertFalse(browser.sidebarVisible)
        XCTAssertTrue(browser.sidebar.isHidden)
        return browser
    }
    private func sidebarIsOverPage(_ browser: BrowserController) -> Bool {
        let views = browser.root.subviews
        return views.firstIndex(of: browser.sidebar)! > views.firstIndex(of: browser.pageShadow)!
    }

    private func titlebarControls(_ browser: BrowserController) -> [NSRect] {
        let close = browser.window!.standardWindowButton(.closeButton)!
        return [close.convert(close.bounds, to: nil)]
    }

    func testTheEdgeSlidesTheSidebarOutOverThePageWithoutMovingIt() {
        let docked = titlebarControls(BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false))
        let browser = collapsedBrowser()
        let page = browser.pageShadow.frame
        XCTAssertFalse(browser.sidebarFloat.edge.isHidden, "A collapsed sidebar watches the window's edge")

        browser.revealFloatingSidebar()
        XCTAssertTrue(browser.isSidebarFloating)
        XCTAssertFalse(browser.sidebar.isHidden)
        XCTAssertTrue(browser.sidebarFloat.edge.isHidden)
        XCTAssertEqual(browser.pageShadow.frame, page, "The page stays put under a floating sidebar")
        let inset = SidebarFloatAppearance.inset
        XCTAssertEqual(browser.sidebar.frame, NSRect(x: inset, y: inset, width: SidebarWidth.ideal, height: browser.root.bounds.height-2*inset))
        XCTAssertEqual(browser.sidebar.cornerRadius, SidebarFloatAppearance.radius)
        XCTAssertTrue(sidebarIsOverPage(browser), "A floating sidebar takes the clicks over the page")
        XCTAssertTrue(browser.grip.isHidden)
        // Window coordinates run upward, so the sidebar's drop by the inset is a negative y.
        XCTAssertEqual(titlebarControls(browser), docked.map { $0.offsetBy(dx: inset, dy: -inset) },
                       "The traffic lights ride with the sidebar")
        XCTAssertTrue(browser.window!.standardWindowButton(.closeButton)!.isEnabled)

        browser.tuckFloatingSidebar()
        XCTAssertFalse(browser.isSidebarFloating)
        XCTAssertTrue(browser.sidebar.isHidden)
        XCTAssertFalse(browser.sidebarFloat.edge.isHidden)
        XCTAssertEqual(browser.pageShadow.frame, page)
        browser.window?.close()
    }

    func testTogglingAFloatingSidebarDocksIt() {
        let browser = collapsedBrowser()
        browser.revealFloatingSidebar()
        browser.toggleSidebar()
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertFalse(browser.isSidebarFloating)
        XCTAssertEqual(browser.sidebar.frame, NSRect(x: 0, y: 0, width: browser.sidebarWidth, height: browser.root.bounds.height))
        XCTAssertEqual(browser.sidebar.cornerRadius, 0)
        XCTAssertEqual(browser.sidebar.layer?.shadowOpacity, 0)
        XCTAssertEqual(browser.pageShadow.frame.minX, browser.sidebarWidth, "The page makes room beside the docked sidebar")
        XCTAssertFalse(sidebarIsOverPage(browser))
        XCTAssertFalse(browser.grip.isHidden)
        XCTAssertEqual(titlebarControls(browser), titlebarControls(BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false)),
                       "Docked, the titlebar controls are back in AppKit's own places")

        browser.toggleSidebar()
        XCTAssertTrue(browser.sidebar.isHidden, "Collapsing in a hidden window lands at once")
        XCTAssertFalse(browser.sidebarFloat.isVisible)
        XCTAssertEqual(browser.pageShadow.frame.minX, PageAppearance.inset)
        browser.window?.close()
    }

    func testItFloatsAtTheIdealWidthAndDocksAtItsOwn() {
        let browser = collapsedBrowser()
        browser.sidebarWidth = 320
        browser.revealFloatingSidebar()
        XCTAssertEqual(browser.sidebar.frame.width, SidebarWidth.ideal, "Floating, it's the width resizing snaps to")
        browser.toggleSidebar()
        XCTAssertEqual(browser.sidebar.frame.width, 320, "Docked, it's the width it was given")
        XCTAssertEqual(browser.pageShadow.frame.minX, 320)
        browser.window?.close()
    }

    func testTheEdgeDoesNothingWhileTheSidebarIsDocked() {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false)
        XCTAssertTrue(browser.sidebarFloat.edge.isHidden)
        browser.revealFloatingSidebar()
        XCTAssertFalse(browser.isSidebarFloating)
        XCTAssertEqual(browser.sidebar.frame.minX, 0)
        browser.window?.close()
    }
}
