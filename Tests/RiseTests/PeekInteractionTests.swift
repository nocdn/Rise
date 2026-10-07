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
        browser.closeAllPeeks(); browser.historySwipe.cancel(); browser.saveWork?.cancel()
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
    @MainActor func testASecondPeekStacksOverTheFirstAndClosesOnItsOwn() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.showWindow(nil)
        let source = browser.addTab()
        let scale = { (view: NSView) in view.layer?.transform.m11 ?? 1 }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) < 0.0001 }
        browser.showPeek(url: URL(string: "about:blank#first")!, from: source.webView)
        let first = try XCTUnwrap(browser.peekTab), firstCard = try XCTUnwrap(browser.peekCard)
        try await wait { near(scale(browser.pageShadow), BrowserController.peekPageScale) }
        let covered = { (tab: BrowserTab) in (tab.webView as? LinkCursorWebView)?.isCovered == true }
        XCTAssertTrue(covered(source), "The page under a Peek takes no hover"); XCTAssertFalse(covered(first))
        XCTAssertTrue(source.webView.trackingAreas.isEmpty, "WebKit's hover tracking is set aside under a Peek")
        XCTAssertFalse(first.webView.trackingAreas.isEmpty)

        browser.showPeek(url: URL(string: "about:blank#second")!, from: first.webView)
        let second = try XCTUnwrap(browser.peekTab)
        XCTAssertFalse(second === first)
        XCTAssertTrue(browser.parkedPeek?.tab === first, "The first Peek waits underneath")
        XCTAssertNotNil(firstCard.superview)
        try await wait { near(scale(firstCard), BrowserController.parkedPeekScale) && near(scale(browser.pageShadow), BrowserController.deepPageScale) }
        let secondFrame = try XCTUnwrap(browser.peekCard).frame, firstFrame = firstCard.frame
        XCTAssertGreaterThan(secondFrame.height, firstFrame.height*BrowserController.parkedPeekScale, "A tiny bit taller than the receded first Peek")
        XCTAssertLessThan(secondFrame.height, firstFrame.height)
        XCTAssertLessThan(secondFrame.width, firstFrame.width*BrowserController.parkedPeekScale, "And narrower")
        XCTAssertTrue(covered(source) && covered(first)); XCTAssertFalse(covered(second))
        XCTAssertTrue(browser.peekBackdrop?.superview?.isDescendant(of: firstCard) == true, "The first Peek dims under the second")
        try await wait { browser.peekPageDim?.alphaValue == 1 }
        try await wait { browser.parkedPeek?.controls.allSatisfy(\.isHidden) == true }

        browser.showPeek(url: URL(string: "about:blank#third")!, from: second.webView)
        XCTAssertTrue(browser.parkedPeek?.tab === first, "Two levels at most: a third replaces the second")

        browser.closePeek(animated: true)
        XCTAssertTrue(browser.peekTab === first, "Closing takes off only the top Peek")
        XCTAssertNil(browser.parkedPeek); XCTAssertNil(browser.peekPageDim)
        XCTAssertTrue(near(scale(firstCard), 1))
        XCTAssertTrue(near(scale(browser.pageShadow), BrowserController.peekPageScale))
        XCTAssertTrue(browser.peekControls.allSatisfy { !$0.isHidden })
        XCTAssertFalse(covered(first), "The first Peek takes hover again")

        browser.showPeek(url: URL(string: "about:blank#second")!, from: first.webView)
        browser.closeAllPeeks()
        XCTAssertNil(browser.peekTab); XCTAssertNil(browser.parkedPeek)
        XCTAssertTrue(near(scale(browser.pageShadow), 1))
        XCTAssertFalse(covered(source))
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
