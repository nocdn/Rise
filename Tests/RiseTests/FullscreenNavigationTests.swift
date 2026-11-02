import AppKit
import XCTest
@testable import Rise

@MainActor final class FullscreenNavigationTests: XCTestCase {
    private func makeBrowser() -> BrowserController {
        let suite = "FullscreenNavigationTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)/session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName("")
        browser.pageFullscreen.setSimulated(true, in: [])
        browser.setSidebarVisible(false)
        return browser
    }
    private func clean(_ browser: BrowserController) {
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.close(); browser.saveWork?.cancel()
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
        browser.preferences.removeObject(forKey: BrowserController.fullscreenNavigationKey)
    }
    private func pointer(_ browser: BrowserController, y: CGFloat = 100, x: CGFloat? = nil) -> NSPoint {
        browser.pageClip.convert(NSPoint(x: x ?? browser.pageClip.bounds.midX, y: y), to: nil)
    }

    func testSettingDefaultsOnAppearsWithSimulatedFullscreenAndPersists() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let title = "Auto-hide URL Bar in Simulated Full Screen"
        XCTAssertTrue(browser.autoHidesFullscreenNavigation)
        let item = try XCTUnwrap(browser.makeMoreSiteMenu().items.first { $0.title == title })
        XCTAssertEqual(item.state, .on)
        (item.target as? MenuAction)?.invoke()
        XCTAssertFalse(browser.autoHidesFullscreenNavigation)
        let row = try XCTUnwrap(browser.riseSettingRows("system").first { $0["key"] as? String == "autoHideFullscreenNavigation" })
        XCTAssertEqual(row["value"] as? Bool, false)
        let restored = BrowserController(sessionURL: browser.sessionURL, restore: false, preferences: browser.preferences)
        XCTAssertFalse(restored.autoHidesFullscreenNavigation)
        restored.window?.close(); restored.saveWork?.cancel()
        browser.setRiseSetting("autoHideFullscreenNavigation", true)
        XCTAssertTrue(browser.autoHidesFullscreenNavigation)
        browser.pageFullscreen.setSimulated(false, in: [])
        XCTAssertNil(browser.makeMoreSiteMenu().items.first { $0.title == title })
    }

    func testHoverSlidesTheBarWithoutResizingTheVideoAndHiddenControlsDoNotTakeClicks() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height)
        browser.pageFullscreen.setActive(true, in: tab.page.view)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        let fullscreen = tab.page.view.frame
        XCTAssertEqual(fullscreen.minY, 0)
        XCTAssertEqual(fullscreen.height, browser.pageClip.bounds.height)
        XCTAssertTrue(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(browser.navBar.alphaValue, 1, "The bar slides at full opacity")
        XCTAssertEqual(browser.navBar.frame.maxY, 0)
        XCTAssertNil(browser.navBar.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertFalse(browser.fullscreenNavigationHover.isHidden)
        XCTAssertNil(browser.fullscreenNavigationHover.hitTest(.zero))
        browser.refreshFullscreenNavigation(pointer: pointer(browser, y: 20))
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(browser.navBar.alphaValue, 1)
        XCTAssertEqual(browser.navBar.frame.minY, 0)
        XCTAssertNotNil(browser.navBar.hitTest(NSPoint(x: 20, y: 20)))
        XCTAssertEqual(tab.page.view.frame, fullscreen)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertTrue(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(tab.page.view.frame, fullscreen)
        browser.refreshFullscreenNavigation(pointer: pointer(browser, y: -4))
        XCTAssertFalse(browser.navBar.isFullscreenHidden, "The narrow margin at the window's top also reveals the bar")
        browser.pageFullscreen.setActive(false, in: tab.page.view)
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(browser.navBar.alphaValue, 1)
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height)
        XCTAssertTrue(browser.fullscreenNavigationHover.isHidden)
    }

    func testDockedAndFloatingSidebarsAlwaysRevealTheBar() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.pageFullscreen.setActive(true, in: tab.page.view)
        browser.setSidebarVisible(true)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
        browser.setSidebarVisible(false)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertTrue(browser.navBar.isFullscreenHidden)
        browser.revealFloatingSidebar()
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
        browser.tuckFloatingSidebar()
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertTrue(browser.navBar.isFullscreenHidden)
    }

    func testNavigationStartsClosingWhileTheSidebarIsStillOnscreen() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.setCollapsesSidebarInSimulatedFullscreen(true)
        browser.setSidebarVisible(true)
        browser.showWindow(nil)
        browser.pageFullscreen.setActive(true, in: tab.page.view)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertFalse(browser.sidebarVisible)
        XCTAssertTrue(browser.navBar.isFullscreenHidden, "The navigation starts closing before the sidebar finishes")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(browser.sidebarFloat.isVisible, "The sidebar is still in its closing animation")
        }
    }

    func testDisablingTheSettingRestoresTheBarAndReservedSpaceImmediately() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.pageFullscreen.setActive(true, in: tab.page.view)
        browser.setAutoHidesFullscreenNavigation(false)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height)
        browser.setAutoHidesFullscreenNavigation(true)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertTrue(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(tab.page.view.frame.minY, 0)
        browser.pageFullscreen.setSimulated(false, in: [])
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height)
    }

    func testBackgroundTabsAndSplitPagesRetainTheirOwnNavigation() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab()
        browser.pageFullscreen.setActive(true, in: first.page.view)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertFalse(browser.navBar.isFullscreenHidden, "Background fullscreen does not hide the current tab's bar")
        browser.showSplit(first)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        let full = try XCTUnwrap(browser.pageBarTabs.first { $0.tab === first })
        let regular = try XCTUnwrap(browser.pageBarTabs.first { $0.tab === second })
        XCTAssertTrue(full.bar.isFullscreenHidden)
        XCTAssertFalse(regular.bar.isFullscreenHidden)
        XCTAssertEqual(first.page.view.frame.minY, 0)
        XCTAssertEqual(second.page.view.frame.minY, PlainNavBar.Metrics.height)
        browser.separateSplit(containing: first.id)
        browser.select(first.id)
        browser.refreshFullscreenNavigation(pointer: pointer(browser))
        XCTAssertTrue(browser.navBar.isFullscreenHidden)
        browser.select(second.id)
        XCTAssertFalse(browser.navBar.isFullscreenHidden)
    }
}
