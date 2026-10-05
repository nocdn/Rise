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
        XCTAssertLessThan(abs(progress(120.001)-progress(119.999)), 0.0001)
        let near = progress(140), further = progress(260), far = progress(1000), beyond = progress(2000)
        XCTAssertGreaterThan(near, 1); XCTAssertGreaterThan(further, near)
        XCTAssertGreaterThan(far, further); XCTAssertGreaterThan(beyond, far, "Long swipes still move; there is no hard cap")
        XCTAssertLessThan(beyond, 1.15)
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
