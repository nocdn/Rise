import XCTest
import AppKit
@testable import Rise

final class PageAppearanceTests: XCTestCase {
    @MainActor func testMeasuredPageMarginsStayConsistentAcrossResizeThemesAndSidebarToggle() {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil) }
        for size in [NSSize(width: 800, height: 600), NSSize(width: 1496, height: 944)] {
            browser.window?.setContentSize(size)
            for theme in RiseTheme.allCases {
                browser.theme = theme; browser.update()
                let bounds = browser.root.bounds, page = browser.pageShadow.frame
                XCTAssertEqual(page.minY-bounds.minY, 6)
                XCTAssertEqual(bounds.maxY-page.maxY, 6)
                XCTAssertEqual(bounds.maxX-page.maxX, 6)
                XCTAssertEqual(page.minX, browser.sidebarWidth)
                XCTAssertEqual(browser.pageClip.frame, browser.pageShadow.bounds)
                browser.toggleSidebar()
                XCTAssertEqual(browser.pageShadow.frame, bounds.insetBy(dx: 6, dy: 6))
                browser.toggleSidebar()
                XCTAssertEqual(browser.pageShadow.frame, page)
            }
        }
    }
    @MainActor func testContinuousContourIsSharedByShadowClipAndBothSwipeDirections() throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil) }
        let tab = browser.addTab()
        XCTAssertEqual(browser.pageShadow.layer?.cornerCurve, .continuous)
        XCTAssertEqual(browser.pageClip.layer?.cornerCurve, .continuous)
        XCTAssertEqual(browser.pageClip.layer?.cornerRadius, 9.5)
        XCTAssertTrue(browser.pageClip.layer?.masksToBounds == true)
        let resting = try XCTUnwrap(browser.pageShadow.layer?.shadowPath)
        XCTAssertEqual(curveCount(resting), 12, "A smoothed corner uses three cubic segments, rather than one circular arc")
    }
    private func curveCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { if $0.pointee.type == .addCurveToPoint { count += 1 } }
        return count
    }
}
