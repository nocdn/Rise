import AppKit
import WebKit
import XCTest
@testable import Rise

@MainActor final class FullscreenSidebarTests: XCTestCase {
    private func makeBrowser() -> BrowserController {
        let preferences = UserDefaults(suiteName: "FullscreenSidebarTests.\(UUID().uuidString)")!
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        browser.pageFullscreen.setSimulated(true, in: [])
        browser.setCollapsesSidebarInSimulatedFullscreen(true)
        return browser
    }
    private func clean(_ browser: BrowserController) {
        browser.tabs.forEach { $0.webView.stopLoading() }
        browser.window?.close(); browser.saveWork?.cancel()
        browser.preferences.removeObject(forKey: PageFullscreen.simulatedKey)
        browser.preferences.removeObject(forKey: BrowserController.fullscreenSidebarKey)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }

    func testOverflowSettingIsCheckableOnlyInSimulatedModeAndPersists() throws {
        let browser = makeBrowser(); defer { clean(browser) }
        let title = "Collapse Sidebar in Simulated Full Screen"
        var item = try XCTUnwrap(browser.makeMoreSiteMenu().items.first { $0.title == title })
        XCTAssertEqual(item.state, .on)
        (item.target as? MenuAction)?.invoke()
        XCTAssertFalse(browser.collapsesSidebarInSimulatedFullscreen)
        item = try XCTUnwrap(browser.makeMoreSiteMenu().items.first { $0.title == title })
        XCTAssertEqual(item.state, .off)
        (item.target as? MenuAction)?.invoke()
        XCTAssertTrue(browser.preferences.bool(forKey: BrowserController.fullscreenSidebarKey))
        browser.toggleSimulatedFullscreen()
        XCTAssertNil(browser.makeMoreSiteMenu().items.first { $0.title == title })
        browser.toggleSimulatedFullscreen()
        XCTAssertEqual(browser.makeMoreSiteMenu().items.first { $0.title == title }?.state, .on)
        let restored = BrowserController(sessionURL: browser.sessionURL, restore: false, preferences: browser.preferences)
        XCTAssertTrue(restored.collapsesSidebarInSimulatedFullscreen)
        restored.window?.close(); restored.saveWork?.cancel()
    }

    func testOpenSidebarCollapsesAndRestoresItsWidthAndPageLayout() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.sidebarWidth = 320; browser.layoutChrome()
        let page = browser.pageShadow.frame
        browser.pageFullscreen.setActive(true, in: tab.webView)
        XCTAssertFalse(browser.sidebarVisible)
        XCTAssertTrue(browser.sidebar.isHidden)
        XCTAssertEqual(browser.pageShadow.frame.minX, PageAppearance.inset)
        XCTAssertGreaterThan(browser.pageShadow.frame.width, page.width)
        browser.pageFullscreen.setActive(true, in: tab.webView)
        browser.update()
        browser.pageFullscreen.setActive(false, in: tab.webView)
        XCTAssertTrue(browser.sidebarVisible, "Repeated updates must not overwrite the original sidebar state")
        XCTAssertEqual(browser.sidebarWidth, 320)
        XCTAssertEqual(browser.pageShadow.frame, page)
    }

    func testCollapsedAndFloatingSidebarsStayCollapsedAfterExit() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.toggleSidebar()
        for floating in [false, true] {
            if floating { browser.revealFloatingSidebar() }
            browser.pageFullscreen.setActive(true, in: tab.webView)
            XCTAssertFalse(browser.sidebarVisible)
            XCTAssertFalse(browser.isSidebarFloating)
            browser.pageFullscreen.setActive(false, in: tab.webView)
            XCTAssertFalse(browser.sidebarVisible)
            XCTAssertTrue(browser.sidebar.isHidden)
        }
    }

    func testManualSidebarChoiceDuringFullscreenTakesPrecedence() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.pageFullscreen.setActive(true, in: tab.webView)
        browser.toggleSidebar()
        browser.update()
        XCTAssertTrue(browser.sidebarVisible, "The user can reopen the sidebar during fullscreen")
        browser.toggleSidebar()
        browser.pageFullscreen.setActive(false, in: tab.webView)
        XCTAssertFalse(browser.sidebarVisible, "An explicit collapse must not be undone on exit")
    }

    func testSettingAndModeChangesRestoreImmediately() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.setCollapsesSidebarInSimulatedFullscreen(false)
        browser.pageFullscreen.setActive(true, in: tab.webView)
        XCTAssertTrue(browser.sidebarVisible)
        browser.setCollapsesSidebarInSimulatedFullscreen(true)
        XCTAssertFalse(browser.sidebarVisible)
        browser.setCollapsesSidebarInSimulatedFullscreen(false)
        XCTAssertTrue(browser.sidebarVisible)
        browser.setCollapsesSidebarInSimulatedFullscreen(true)
        XCTAssertFalse(browser.sidebarVisible)
        browser.toggleSimulatedFullscreen()
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertFalse(browser.pageFullscreen.isActive(in: tab.webView))
        browser.pageFullscreen.setActive(true, in: tab.webView)
        XCTAssertTrue(browser.sidebarVisible, "Native fullscreen must not collapse the sidebar")
    }

    func testBackgroundTabsCannotHideTheSidebarAndSwitchingAwayRestoresIt() {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab()
        browser.pageFullscreen.setActive(true, in: first.webView)
        XCTAssertTrue(browser.sidebarVisible)
        browser.select(first.id)
        XCTAssertFalse(browser.sidebarVisible)
        browser.select(second.id)
        XCTAssertTrue(browser.sidebarVisible)
        browser.select(first.id)
        XCTAssertFalse(browser.sidebarVisible)
        browser.closeTab(first.id)
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertFalse(browser.pageFullscreen.isActive(in: first.webView))
    }

    func testSplitPagesKeepSidebarCollapsedUntilBothLeaveFullscreen() {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab()
        browser.showSplit(first)
        browser.pageFullscreen.setActive(true, in: first.webView)
        browser.pageFullscreen.setActive(true, in: second.webView)
        browser.pageFullscreen.setActive(false, in: first.webView)
        XCTAssertFalse(browser.sidebarVisible)
        browser.pageFullscreen.setActive(false, in: second.webView)
        XCTAssertTrue(browser.sidebarVisible)
    }

    func testNavigationAndWebProcessTerminationClearFullscreenState() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        browser.pageFullscreen.setActive(true, in: tab.webView)
        browser.webView(tab.webView, didCommit: nil)
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertFalse(browser.pageFullscreen.isActive(in: tab.webView))
        browser.pageFullscreen.setActive(true, in: tab.webView)
        browser.webViewWebContentProcessDidTerminate(tab.webView)
        XCTAssertTrue(browser.sidebarVisible)
        XCTAssertFalse(browser.pageFullscreen.isActive(in: tab.webView))
    }
}
