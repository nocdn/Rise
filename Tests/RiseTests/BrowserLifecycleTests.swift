import XCTest
import AppKit
import WebKit
import RiseCore
@testable import Rise

final class BrowserLifecycleTests: XCTestCase {
    @MainActor func testPeekModifierUpdatesExistingHoverAndHidingClearsIt() throws {
        let browser = makeBrowser(); defer { browser.hideLinkStatus(); clean(browser) }
        let tab = browser.addTab(), target = URL(string: "https://example.com/target")!
        browser.showHoveredLink(target, in: tab.page.view)
        let web = tab.page.view
        let window = try XCTUnwrap(browser.window as? BrowserWindow)
        func flags(_ value: NSEvent.ModifierFlags) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: value, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
            window.sendEvent(event)
        }
        try flags(.shift)
        XCTAssertTrue(browser.linkStatus.showsPeekHint)
        XCTAssertEqual(browser.linkStatus.url, target)
        try flags([])
        XCTAssertFalse(browser.linkStatus.showsPeekHint)
        try flags(.option)
        XCTAssertTrue(browser.linkStatus.showsPeekHint, "The existing Option Peek shortcut gets the same hint")
        try flags([])
        browser.showHoveredLink(nil, in: web)
        XCTAssertTrue(browser.linkStatus.isHidden)
        browser.showHoveredLink(target, in: web)
        browser.hideLinkStatus()
        XCTAssertTrue(browser.linkStatus.isHidden)
        browser.peekStandbyWork?.cancel()
    }
    @MainActor func makeBrowser() -> BrowserController {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        return BrowserController(sessionURL: url, restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel()
        browser.tabs.forEach { $0.page.stopLoading() }
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
    @MainActor func testReopeningStaysOnTheCurrentTabUnlessSetToSwitch() {
        _ = NSApplication.shared
        let suite = "Rise.BrowserLifecycleTests.\(UUID().uuidString)"
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        defer { clean(browser); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let kept = browser.addTab(), closed = browser.addTab()
        browser.closeTab(closed.id); browser.select(kept.id)
        browser.reopenTab()
        XCTAssertEqual(browser.tabs.first?.id, closed.id, "Back at the top")
        XCTAssertEqual(browser.selectedID, kept.id, "Behind the current tab by default")
        browser.closeTab(closed.id); browser.setShowsReopenedTabs(true)
        browser.reopenTab()
        XCTAssertEqual(browser.selectedID, closed.id, "Shown when set in rise://settings")
    }
    @MainActor func testClosingSelectedSplitKeepsRemainingTabUsable() {
        let browser = makeBrowser(); defer { clean(browser) }
        let first = browser.addTab(); let second = browser.addTab()
        browser.select(first.id); browser.showSplit(second)
        XCTAssertNotNil(browser.splitTab)
        browser.closeTab(first.id)
        XCTAssertNil(browser.splitTab)
        XCTAssertEqual(browser.selectedTab?.id, second.id)
        XCTAssertTrue(second.page.view.superview === browser.pageClip)
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
        XCTAssertTrue(restored.selectedTab?.page.view.superview === restored.pageClip)
        XCTAssertEqual(restored.theme, .rose)
        XCTAssertEqual(restored.sidebarWidth, 260)
    }
    @MainActor func testAutomaticThemeFollowsMacOSAndIsRestored() {
        let browser = makeBrowser(); defer { clean(browser); NSApp.appearance = nil }
        browser.chooseTheme(nil)
        XCTAssertTrue(browser.automaticTheme)
        XCTAssertNil(NSApp.appearance, "Automatic leaves the appearance to macOS")
        let system = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? RiseTheme.dark : .neutral
        XCTAssertEqual(browser.theme, system)
        browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { clean(restored) }
        XCTAssertTrue(restored.automaticTheme)
        XCTAssertEqual(restored.theme, system)
        restored.chooseTheme(.rose)
        XCTAssertFalse(restored.automaticTheme)
        XCTAssertEqual(NSApp.appearance?.name, .aqua, "A chosen theme sets the appearance again")
    }
    @MainActor func testPlainLightThemeUsesKerosWashAndChosenTabOnlyInLight() throws {
        let suite = "plain-light-\(UUID().uuidString)", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: preferences)
        defer { RiseTheme.plain = false; clean(browser); preferences.removePersistentDomain(forName: suite) }
        let first = browser.addTab(), second = browser.addTab()
        browser.chooseTheme(.neutral); browser.select(first.id)
        browser.setRiseSetting("plain", true)
        XCTAssertEqual(browser.theme.background, RiseTheme.plainBackground); XCTAssertNil(browser.theme.backgroundGradient)
        XCTAssertFalse(browser.plainMaterial.isHidden); XCTAssertEqual(browser.plainMaterial.blendingMode, .behindWindow)
        let row = try XCTUnwrap(browser.sidebar.rows[first.id]), other = try XCTUnwrap(browser.sidebar.rows[second.id])
        XCTAssertTrue(row.plainBackground.isChosen); XCTAssertFalse(other.plainBackground.isChosen)
        XCTAssertNil(browser.sidebar.selectedTabShadow.shadow, "Kero's ring and shadow in place of Rise's card")
        browser.sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(browser.sidebar.address.isHidden); XCTAssertEqual(browser.sidebar.newTab.frame.minY, SidebarView.addresslessTop, "New Tab takes its place")
        browser.select(second.id)
        XCTAssertTrue(other.plainBackground.isChosen); XCTAssertFalse(row.plainBackground.isChosen)
        browser.chooseTheme(.dark)
        XCTAssertEqual(browser.theme.background, RiseTheme.plainDarkBackground, "Dark is Plain too, in Kero's near-black")
        XCTAssertFalse(browser.plainMaterial.isHidden); XCTAssertTrue(other.plainBackground.isChosen); XCTAssertTrue(other.plainBackground.dark)
        XCTAssertTrue(browser.sidebar.address.isHidden)
        XCTAssertFalse(browser.pageEdge.isHidden, "Kero's lit edge round the page"); XCTAssertEqual(browser.pageShadow.keroShadows, .dark)
        XCTAssertTrue(browser.pageClip.subviews.last === browser.pageEdge, "Over the page")
        browser.chooseTheme(.neutral)
        XCTAssertTrue(browser.pageEdge.isHidden, "Dark's alone"); XCTAssertEqual(browser.pageShadow.keroShadows, .light, "Kero's soft pair for Light's edge")
        XCTAssertNil(browser.pageShadow.shadow)
        browser.chooseTheme(.rise)
        XCTAssertEqual(browser.pageShadow.keroShadows, .none); XCTAssertNotNil(browser.pageShadow.shadow, "Rise's own shadow back")
        XCTAssertTrue(browser.plainMaterial.isHidden); XCTAssertTrue(other.plainBackground.isHidden, "Only Light and Dark are Plain")
        XCTAssertNotNil(browser.sidebar.selectedTabShadow.shadow); XCTAssertFalse(browser.sidebar.address.isHidden)
    }
    @MainActor func testPlainThemePutsDiasBarOverThePageWithTheNavigationButtons() throws {
        let suite = "plain-bar-\(UUID().uuidString)", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: preferences)
        defer { RiseTheme.plain = false; clean(browser); preferences.removePersistentDomain(forName: suite) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://www.apnews.com/article/oregon"); tab.rename("Oregon")
        browser.chooseTheme(.neutral); browser.select(tab.id); browser.setPlainTheme(true)
        let bar = browser.navBar
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(browser.toolbarButtons.allSatisfy { $0.superview === bar }, "Rise's titlebar buttons move into it")
        XCTAssertEqual((browser.toolbarButtons[1] as? HistoryArrowButton)?.chevron, true, "As Dia's chevrons")
        XCTAssertEqual(tab.page.view.frame.minY, PlainNavBar.Metrics.height, "The page starts under it")
        XCTAssertEqual(bar.text.stringValue, "apnews.com / Oregon")
        let tuck = PlainNavBar.Metrics.height
        XCTAssertEqual(browser.selectedFindBar.tuckedInset, tuck); XCTAssertEqual(browser.infoPlaque.tuckedInset, tuck)
        let height = FindBar.rowHeight, bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertLessThanOrEqual(FindBar.panelOrigin(in: bounds, width: 300, height: height, slide: 0, topInset: tuck, tuckedInset: tuck).y+height, tuck,
                                 "Panels start under the bar, not above the window")
        XCTAssertEqual(FindBar.panelOrigin(in: bounds, width: 300, height: height, slide: 1, topInset: tuck, tuckedInset: tuck),
                       FindBar.panelOrigin(in: bounds, width: 300, height: height, slide: 1, topInset: tuck), "And land where they always did")
        bar.setHovered(true)
        XCTAssertEqual(bar.text.stringValue, "apnews.com/article/oregon", "Hovered, the whole address"); XCTAssertTrue(bar.settingsButton.allowsInteraction)
        bar.setColor(.black, animated: false)
        XCTAssertEqual(bar.ink.strong, NSColor.white.withAlphaComponent(0.8), "Light on a dark page")
        browser.setPlainTheme(false)
        XCTAssertTrue(bar.isHidden); XCTAssertTrue(browser.toolbarButtons.allSatisfy { $0.superview === browser.toolbarHost })
        XCTAssertEqual((browser.toolbarButtons[1] as? HistoryArrowButton)?.chevron, false)
    }
    @MainActor func testPlainBarLineFollowsALoadForwardOnlyAndGoesWhenItsDone() {
        let bar = PlainNavBar(copy: {}, settings: {}, zoom: {}); bar.frame = NSRect(x: 0, y: 0, width: 800, height: PlainNavBar.Metrics.height)
        XCTAssertNil(bar.progress)
        bar.setLoading(true, progress: 0.3); XCTAssertEqual(bar.progress ?? 0, 0.3, accuracy: 0.001)
        bar.setLoading(true, progress: 0.2); XCTAssertEqual(bar.progress ?? 0, 0.3, accuracy: 0.001, "Never back")
        bar.setLoading(true, progress: 0.6, hard: true)
        XCTAssertEqual(bar.progress ?? 0, 0.6, accuracy: 0.001); XCTAssertEqual(bar.progressStyle.color, TabLoadingBackground.hardReloadColor)
        bar.setLoading(false, progress: 0); XCTAssertNil(bar.progress, "Done, it goes")
        bar.resetLoading(true, progress: 0.45); XCTAssertEqual(bar.progress ?? 0, 0.45, accuracy: 0.001, "Another tab's load, where it's got")
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
    @MainActor func testUnmodifiedLinksKeepNavigatingAndCommandLinksOpenBackgroundTabs() {
        let browser = makeBrowser(); defer { clean(browser) }
        let source = browser.addTab(), top = browser.addTab()
        browser.select(source.id)
        let target = URL(string: "about:blank")!
        XCTAssertFalse(browser.openModifiedLink(target, modifiers: []))
        XCTAssertNil(browser.peekTab)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(browser.openModifiedLink(target, modifiers: .command))
        XCTAssertEqual(browser.tabs.count, 3)
        XCTAssertEqual(browser.selectedID, source.id, "The current tab stays in front")
        XCTAssertEqual(browser.tabs.map(\.id).filter { $0 != browser.tabs[1].id }, [top.id, source.id])
        XCTAssertEqual(browser.tabs[2].id, source.id, "The new tab sits right above the one it came from")
        XCTAssertNotNil(browser.sidebar.rows[browser.tabs[1].id], "The new tab shows in the list")
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
        XCTAssertEqual(browser.pageShadow.frame, browser.root.bounds.insetBy(dx: PageAppearance.inset, dy: PageAppearance.inset))
        XCTAssertEqual(tab.page.view.frame, browser.pageClip.bounds)
        XCTAssertEqual(browser.selectedID, tab.id)
        XCTAssertTrue(browser.pageShadow.layer?.animationKeys()?.isEmpty ?? true)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(kind)!.isHidden)
        }
        // The invisible titlebar must not swallow clicks near the page's top.
        let frameView = browser.root.superview!
        let point = browser.root.convert(NSPoint(x: 300, y: 18), to: frameView)
        let hit = frameView.hitTest(point)
        XCTAssertTrue(hit === tab.page.view || hit?.isDescendant(of: tab.page.view) == true)
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
