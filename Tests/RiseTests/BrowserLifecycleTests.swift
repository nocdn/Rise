import XCTest
import AppKit
import WebKit
import RiseCore
@testable import Rise

final class BrowserLifecycleTests: XCTestCase {
    @MainActor func makeBrowser() -> BrowserController {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        return BrowserController(sessionURL: url, restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel()
        browser.tabs.forEach { $0.webView.stopLoading() }
        browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testCloseLastTabAndReopen() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.title = "Example"
        browser.closeTab(tab.id)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertNil(browser.selectedTab)
        browser.reopenTab()
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.selectedTab?.id, tab.id)
        XCTAssertEqual(browser.selectedTab?.title, "Example")
    }
    @MainActor func testClearPreservesPinnedTabsAndSelection() {
        let browser = makeBrowser(); defer { clean(browser) }
        let pinned = browser.addTab(); pinned.pinned = true
        let second = browser.addTab(); browser.addTab()
        browser.clearTabs()
        XCTAssertEqual(browser.tabs.map(\.id), [pinned.id])
        XCTAssertEqual(browser.selectedTab?.id, pinned.id)
        XCTAssertTrue(browser.closedTabs.contains { $0.id == second.id })
    }
    @MainActor func testClosingSelectedSplitKeepsRemainingTabUsable() {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(); let second = browser.addTab()
        browser.select(first.id); browser.showSplit(second)
        XCTAssertNotNil(browser.splitTab)
        browser.closeTab(first.id)
        XCTAssertNil(browser.splitTab)
        XCTAssertEqual(browser.selectedTab?.id, second.id)
        XCTAssertTrue(second.webView.superview === browser.pageClip)
    }
    @MainActor func testSessionRestoresThemePinnedTabsAndSelection() {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(); first.pinned = true
        let second = browser.addTab(); second.developer = true
        browser.theme = .rose; browser.sidebarWidth = 260; browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { clean(restored) }
        XCTAssertEqual(restored.tabs.map(\.saved), browser.tabs.map(\.saved))
        XCTAssertEqual(restored.selectedID, second.id)
        XCTAssertTrue(restored.selectedTab?.webView.superview === restored.pageClip)
        XCTAssertEqual(restored.theme, .rose)
        XCTAssertEqual(restored.sidebarWidth, 260)
    }
    @MainActor func testSystemTrafficLightsRemainInTitlebarAndAlignWithNavigation() {
        let browser = makeBrowser(); defer { clean(browser) }
        let window = browser.window!
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        browser.toolbarHost.layout()
        let close = window.standardWindowButton(.closeButton)!
        XCTAssertFalse(close.superview === browser.root)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertNotNil(window.toolbar)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let light = window.standardWindowButton(kind)!
            let center = light.convert(light.bounds, to: browser.root).midY
            for button in browser.toolbarButtons {
                XCTAssertEqual(button.convert(button.bounds, to: browser.root).midY, center, accuracy: 0.5)
            }
        }
    }
    @MainActor func testShiftLinkOpensPeekWithoutChangingTheCurrentTab() {
        let browser = makeBrowser(); defer { clean(browser) }
        let source = browser.addTab()
        let target = URL(string: "about:blank")!
        XCTAssertTrue(browser.openModifiedLink(target, modifiers: .shift))
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertEqual(browser.peekTab?.url, target)
        XCTAssertNotNil(browser.peekCard)
        XCTAssertEqual(browser.peekControls.count, 3)
        browser.closePeek()
        XCTAssertNil(browser.peekTab)
        XCTAssertNil(browser.peekCard)
    }
    @MainActor func testUnmodifiedLinksKeepNavigatingAndCommandLinksOpenTabs() {
        let browser = makeBrowser(); defer { clean(browser) }
        browser.addTab()
        let target = URL(string: "about:blank")!
        XCTAssertFalse(browser.openModifiedLink(target, modifiers: []))
        XCTAssertNil(browser.peekTab)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.openModifiedLink(target, modifiers: .command))
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertNil(browser.peekTab)
    }
    @MainActor func testHiddenSidebarFillsWindowAndRestoresNativeChromeImmediately() {
        let browser = makeBrowser(); defer { clean(browser) }
        let tab = browser.addTab()
        let window = browser.window!
        let originalParent = window.standardWindowButton(.closeButton)?.superview
        let openFrame = browser.pageShadow.frame
        browser.toggleSidebar()
        XCTAssertTrue(browser.sidebar.isHidden)
        XCTAssertTrue(browser.toolbarAccessory.isHidden)
        XCTAssertFalse(window.toolbar!.isVisible)
        XCTAssertTrue(browser.toolbarButtons.allSatisfy(\.isHidden))
        XCTAssertEqual(browser.pageShadow.frame, browser.root.bounds.insetBy(dx: 7, dy: 7))
        XCTAssertEqual(tab.webView.frame, browser.pageClip.bounds)
        XCTAssertEqual(browser.selectedID, tab.id)
        XCTAssertTrue(browser.pageShadow.layer?.animationKeys()?.isEmpty ?? true)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(kind)!.isHidden)
        }
        // The invisible titlebar must not swallow clicks near the page's top.
        let frameView = browser.root.superview!
        let point = browser.root.convert(NSPoint(x: 300, y: 18), to: frameView)
        let hit = frameView.hitTest(point)
        XCTAssertTrue(hit === tab.webView || hit?.isDescendant(of: tab.webView) == true)
        browser.toggleSidebar()
        XCTAssertEqual(browser.pageShadow.frame, openFrame)
        XCTAssertFalse(browser.toolbarAccessory.isHidden)
        XCTAssertTrue(window.toolbar!.isVisible)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.superview === originalParent)
        XCTAssertFalse(window.standardWindowButton(.closeButton)!.isHidden)
        XCTAssertEqual(browser.tabs.count, 1)
    }
    @MainActor func testCommandBAndLegacyCommandSToggleSidebarThroughMenu() {
        let browser = makeBrowser(); defer { clean(browser) }
        let previousMenu = NSApp.mainMenu; defer { NSApp.mainMenu = previousMenu }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        for (key, code) in [("b", UInt16(11)), ("s", UInt16(1))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                        windowNumber: browser.window!.windowNumber, context: nil,
                                        characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            let before = browser.sidebarVisible
            XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: event))
            XCTAssertEqual(browser.sidebarVisible, !before)
        }
    }

}
