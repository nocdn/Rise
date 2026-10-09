import XCTest
import AppKit
import WebKit
@testable import Rise

final class PeekInteractionTests: XCTestCase {
    func testPeekResistanceIsContinuousAndNeverHardStopsAfterThreshold() {
        func progress(_ travel: Double) -> Double {
            var swipe = HistorySwipeState(); swipe.begin()
            _ = swipe.move(dx: travel, dy: 0, canBack: true, canForward: true)
            return BrowserController.peekVisualProgress(for: swipe.arrowPull)
        }
        XCTAssertEqual(progress(60), 0.5)
        XCTAssertEqual(progress(120), 1)
        XCTAssertGreaterThan(progress(180), 1.24, "The first extra pull should remain responsive instead of quickly stiffening")
        XCTAssertLessThan(abs(progress(120.001)-progress(119.999)), 0.0001)
        let near = progress(140), further = progress(260), far = progress(1000), beyond = progress(2000)
        XCTAssertGreaterThan(near, 1); XCTAssertGreaterThan(further, near)
        XCTAssertGreaterThan(far, further); XCTAssertGreaterThan(beyond, far, "Long swipes still move; there is no hard cap")
        XCTAssertLessThan(beyond, 1.5)
        XCTAssertLessThan((further-near)/120, (near-1)/20)
        XCTAssertLessThan((beyond-far)/1000, (far-further)/740)
    }

    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        return BrowserController(sessionURL: file, restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.closePeek(); browser.historySwipe.cancel(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.suggestionFavicons.cancel()
        browser.window?.orderOut(nil)
    }
    @MainActor private func event(_ phase: NSEvent.Phase, x: Int32 = 0, momentum: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -x, wheel3: 0)!
        let raw: Int64 = phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: raw)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testCommandWClosesPeekBeforeClosingSelectedTab() throws {
        let browser = browser(); defer { clean(browser) }
        let oldMenu = NSApp.mainMenu; defer { NSApp.mainMenu = oldMenu }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let other = browser.addTab(), source = browser.addTab()
        let tabIDs = browser.tabs.map(\.id), closedTabIDs = browser.closedTabs.map(\.id)
        browser.showPeek(url: URL(string: "about:blank")!, from: source.webView)
        XCTAssertNotNil(browser.peekTab)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))

        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        XCTAssertNil(browser.peekTab)
        XCTAssertNil(browser.peekCard)
        XCTAssertEqual(browser.tabs.map(\.id), tabIDs)
        XCTAssertEqual(browser.closedTabs.map(\.id), closedTabIDs)
        XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertTrue(browser.window?.firstResponder === source.webView)
        XCTAssertFalse((source.webView as? LinkCursorWebView)?.isCovered == true)

        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        XCTAssertFalse(browser.tabs.contains { $0.id == source.id })
        XCTAssertEqual(browser.closedTabs.last?.id, source.id)
        XCTAssertEqual(browser.selectedID, other.id)
    }
    @MainActor func testAPeekLinkInsideThePeekShakesThePillAndHistoryMovesThroughThePeek() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.showWindow(nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["source", "first", "second"].map { folder.appendingPathComponent("\($0).html") }
        for url in urls { try "<title>\(url.lastPathComponent)</title>Page".write(to: url, atomically: true, encoding: .utf8) }
        let source = browser.addTab(url: urls[0])
        try await wait { !source.webView.isLoading && source.webView.title == "source.html" }
        browser.showPeek(url: urls[1], from: source.webView)
        let peek = try XCTUnwrap(browser.peekTab), card = try XCTUnwrap(browser.peekCard)
        try await wait { !peek.webView.isLoading && peek.webView.title == "first.html" && card.alphaValue == 1 }
        XCTAssertTrue((source.webView as? LinkCursorWebView)?.isCovered == true, "The page under the Peek takes no hover")

        // Shift over a link inside the Peek: the pill says it can't open one.
        browser.hoveredWebView = peek.webView
        browser.linkStatus.show(urls[2], theme: browser.theme, peek: true, blocked: true)
        // Pressing the link reports its hover ending first; the pill holds on through the press.
        browser.showHoveredLink(nil, in: peek.webView)
        XCTAssertFalse(browser.linkStatus.isHidden, "No blink between the press and the refusal")
        browser.showPeek(url: urls[2], from: peek.webView)
        XCTAssertFalse(browser.linkStatus.isHidden)
        XCTAssertEqual(browser.linkStatus.accessibilityLabel(), "Cannot open \(urls[2].absoluteString) in Peek")
        XCTAssertTrue(browser.peekTab === peek, "Only one Peek: the open one stays")
        XCTAssertNotNil(browser.linkStatus.layer?.animation(forKey: "shake"), "The pill shakes its \"Cannot open\" instead")
        // Without a click, the held-back hide still happens.
        browser.showHoveredLink(nil, in: peek.webView)
        try await wait { browser.linkStatus.isHidden }
        XCTAssertFalse(browser.peekHasNavigated)

        peek.load(urls[2])
        try await wait { !peek.webView.isLoading && peek.webView.title == "second.html" }
        XCTAssertTrue(browser.peekHasNavigated)
        XCTAssertTrue(browser.toolbarButtons[1].isEnabled, "Back follows the Peek's own pages")
        browser.goBack()
        try await wait { !peek.webView.isLoading && peek.webView.title == "first.html" }
        XCTAssertEqual(source.webView.title, "source.html", "The tab underneath stays where it was")
        XCTAssertTrue(browser.toolbarButtons[2].isEnabled)
        browser.goForward()
        try await wait { !peek.webView.isLoading && peek.webView.title == "second.html" }

        browser.closePeek()
        XCTAssertFalse((source.webView as? LinkCursorWebView)?.isCovered == true)
        XCTAssertFalse(source.webView.trackingAreas.isEmpty, "Hover tracking comes back when the Peek closes")
    }
    @MainActor func testNormalExpandNavigatesSourceAndPreservesItsHistory() async throws {
        let browser = browser(); defer { clean(browser) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("source.html"), targetURL = folder.appendingPathComponent("target.html")
        try "<title>Source</title>Source".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "<title>Target</title>Target".write(to: targetURL, atomically: true, encoding: .utf8)
        let source = browser.addTab(url: sourceURL)
        try await wait { source.webView.title == "Source" && !source.webView.isLoading }
        let count = browser.tabs.count
        browser.showPeek(url: targetURL, from: source.webView)
        let peek = try XCTUnwrap(browser.peekTab)
        try await wait { peek.webView.title == "Target" && !peek.webView.isLoading }
        browser.expandPeek(modifiers: [])
        try await wait { source.webView.title == "Target" && !source.webView.isLoading }
        XCTAssertEqual(browser.tabs.count, count); XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertNil(browser.peekTab); XCTAssertTrue(source.webView.canGoBack)
        source.webView.goBack()
        try await wait { source.webView.title == "Source" && !source.webView.isLoading }
    }
    @MainActor func testCommandExpandInsertsLivePeekImmediatelyAboveItsSource() throws {
        let browser = browser(); defer { clean(browser) }
        let bottom = browser.addTab(), source = browser.addTab(), top = browser.addTab()
        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank")!, from: source.webView)
        let peek = try XCTUnwrap(browser.peekTab), web = peek.webView
        browser.expandPeek(modifiers: .command)
        XCTAssertEqual(browser.tabs.map(\.id), [top.id, peek.id, source.id, bottom.id])
        XCTAssertEqual(browser.selectedID, peek.id); XCTAssertTrue(browser.selectedTab?.webView === web)
        XCTAssertNil(browser.peekCard)
    }
    @MainActor func testNewWindowLinkKeepsNormalNewTabSemanticsWhenExpanded() throws {
        let browser = browser(); defer { clean(browser) }
        let source = browser.addTab(), top = browser.addTab()
        browser.select(source.id)
        XCTAssertTrue(browser.openModifiedLink(URL(string: "about:blank")!, modifiers: .shift,
                                             from: source.webView, opensNewTab: true))
        let peek = try XCTUnwrap(browser.peekTab)
        browser.expandPeek(modifiers: [])
        XCTAssertEqual(browser.tabs.map(\.id), [top.id, peek.id, source.id])
        XCTAssertEqual(browser.selectedID, peek.id)
    }
    @MainActor func testPeekSwipeWorksWithoutPageHistoryAndReversalCancellationAndMomentumAreSafe() async throws {
        let browser = browser(); defer { clean(browser) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString("<title>Peek</title><body style='margin:0'>Peek</body>", baseURL: nil)
        try await wait { web.title == "Peek" && !web.isLoading }
        XCTAssertFalse(web.canGoBack)
        let router = HistorySwipeController(window: browser.window as! BrowserWindow, pageAt: { _ in web }, feedback: { _, _, _, _ in })
        defer { router.cancel() }
        router.isPeekPage = { $0 === web }
        var clicks = 0, cloth = 0, pulls = [Double](), releases = [Bool](), cancellations = 0
        router.thresholdClick = { clicks += 1 }; router.prepareCloth = { _ in cloth += 1 }
        router.dragPeek = { pulls.append($0) }; router.releasePeek = { releases.append($0) }
        router.cancelPeek = { cancellations += 1 }
        XCTAssertTrue(router.handle(event(.began, x: 60)))
        try await wait { router.gesture.consumesScroll }
        XCTAssertEqual(pulls.last, 0.5)
        XCTAssertTrue(router.handle(event(.changed, x: 65))); XCTAssertEqual(clicks, 1)
        XCTAssertTrue(router.handle(event(.changed, x: -20))); XCTAssertFalse(router.gesture.isArmed)
        XCTAssertTrue(router.handle(event(.ended))); XCTAssertEqual(releases, [false])
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        XCTAssertTrue(router.handle(event(.cancelled))); XCTAssertEqual(releases, [false, false])
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        router.cancel(); XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        XCTAssertTrue(router.handle(event(.ended))); XCTAssertEqual(releases, [false, false, true])
        XCTAssertTrue(router.handle(event([], x: 300, momentum: 1)))
        XCTAssertTrue(router.handle(event([], x: 300, momentum: 3)))
        XCTAssertEqual(releases.count, 3); XCTAssertEqual(cloth, 0); XCTAssertEqual(clicks, 4)
        XCTAssertEqual(web.title, "Peek"); XCTAssertFalse(web.canGoBack)
    }
}
