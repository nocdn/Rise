import XCTest
import AppKit
@testable import Rise

final class HistorySwipeTests: XCTestCase {
    func testMirroredThresholdSwipesClickOnEachArmingAndCommitOnlyWhenArmedOnRelease() {
        for sign in [1.0, -1.0] {
            var swipe = HistorySwipeState(); swipe.begin()
            var clicks = 0
            for dx in [2.0, 4, 40, -6, 80, 100, -500, 500] {
                if swipe.move(dx: sign * dx, dy: 0, canBack: true, canForward: true) { clicks += 1 }
            }
            XCTAssertEqual(clicks, 2, "Once on arming, and again on arming after going back under it")
            XCTAssertTrue(swipe.isArmed)
            XCTAssertEqual(swipe.direction, sign > 0 ? .back : .forward)
            XCTAssertEqual(swipe.finish(), sign > 0 ? .back : .forward)
            XCTAssertNil(swipe.finish(), "A release cannot commit twice")
        }
    }
    func testReversingBelowThresholdDisarmsInBothDirectionsAndKeepsTheOriginalOrigin() {
        for sign in [1.0, -1.0] {
            var swipe = HistorySwipeState(); swipe.begin()
            XCTAssertTrue(swipe.move(dx: sign * 150, dy: 0, canBack: true, canForward: true))
            XCTAssertTrue(swipe.isArmed)
            XCTAssertFalse(swipe.move(dx: sign * -31, dy: 0, canBack: true, canForward: true))
            XCTAssertFalse(swipe.isArmed)
            XCTAssertEqual(swipe.distance, 119)
            XCTAssertNil(swipe.finish(), "Reversing below 120 pt cancels navigation")

            swipe.begin()
            _ = swipe.move(dx: sign * 150, dy: 0, canBack: true, canForward: true)
            _ = swipe.move(dx: sign * -200, dy: 0, canBack: true, canForward: true)
            XCTAssertEqual(swipe.distance, 0)
            XCTAssertFalse(swipe.isArmed)
            _ = swipe.move(dx: sign * 60, dy: 0, canBack: true, canForward: true)
            XCTAssertEqual(swipe.distance, 10, "Moving past the origin must not shift the start point")
            XCTAssertTrue(swipe.move(dx: sign * 110, dy: 0, canBack: true, canForward: true),
                "Rearming within the same gesture clicks again, as the circle pops again")
            XCTAssertFalse(swipe.move(dx: sign * 20, dy: 0, canBack: true, canForward: true), "Staying armed doesn't")
            XCTAssertTrue(swipe.isArmed)
            XCTAssertEqual(swipe.finish(), sign > 0 ? .back : .forward)
        }
    }
    func testEarlyReleaseCancellationAxisLockAndUnavailableHistory() {
        var swipe = HistorySwipeState(); swipe.begin()
        XCTAssertFalse(swipe.move(dx: 119, dy: 0, canBack: true, canForward: true))
        XCTAssertNil(swipe.finish())
        swipe.begin(); XCTAssertTrue(swipe.move(dx: 120, dy: 0, canBack: true, canForward: true))
        XCTAssertNil(swipe.finish(cancelled: true))
        swipe.begin(); _ = swipe.move(dx: 1, dy: 20, canBack: true, canForward: true)
        _ = swipe.move(dx: 200, dy: 0, canBack: true, canForward: true)
        XCTAssertFalse(swipe.consumesScroll); XCTAssertNil(swipe.finish())
        swipe.begin(); _ = swipe.move(dx: 200, dy: 0, canBack: false, canForward: true)
        XCTAssertFalse(swipe.consumesScroll); XCTAssertNil(swipe.finish())
        swipe.begin(); _ = swipe.move(dx: -200, dy: 0, canBack: true, canForward: false)
        XCTAssertFalse(swipe.consumesScroll); XCTAssertNil(swipe.finish())
    }
    func testHeldListScrollsAsAPageDoesWithHysteresisAndClampedEnds() {
        var swipe = HistorySwipeState(); swipe.begin()
        _ = swipe.move(dx: 150, dy: 0, canBack: true, canForward: true)
        XCTAssertEqual(swipe.steps, 1, "Without a list a release goes one page")
        _ = swipe.move(dx: 0, dy: 40, canBack: true, canForward: true)
        XCTAssertEqual(swipe.selection, 0, "Moving before the list shows picks nothing")
        swipe.openList(count: 3)
        XCTAssertEqual(swipe.selection, 0, "The list opens on the nearest page")
        // Back's list has the furthest page on top: scrolling the list down brings those rows to the circle.
        _ = swipe.move(dx: 0, dy: 11, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 0)
        _ = swipe.move(dx: 0, dy: 1, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 1, "Under 12 pt moves a row")
        _ = swipe.move(dx: 0, dy: -6, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 1, "Resting on an edge holds the row")
        _ = swipe.move(dx: 0, dy: 500, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 2)
        XCTAssertEqual(swipe.steps, 3)
        _ = swipe.move(dx: 0, dy: -15, canBack: true, canForward: true)
        XCTAssertEqual(swipe.selection, 1, "Travel past the end isn't kept, so turning back answers at once")
        _ = swipe.move(dx: 0, dy: -200, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 0)
        _ = swipe.move(dx: 0, dy: 12, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 1)
        swipe.closeList(); XCTAssertEqual(swipe.steps, 1)
        XCTAssertEqual(swipe.finish(), .back)
        XCTAssertNil(swipe.listBase, "A new gesture starts without a list")

        swipe.begin(); _ = swipe.move(dx: -150, dy: 0, canBack: true, canForward: true)
        swipe.openList(count: 2)
        _ = swipe.move(dx: 0, dy: 30, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 0, "Forward's further pages are below, brought up by scrolling up")
        _ = swipe.move(dx: 0, dy: -12, canBack: true, canForward: true); XCTAssertEqual(swipe.selection, 1)
    }
    func testDemoResistanceAndSpringOvershoot() {
        var swipe = HistorySwipeState(); swipe.begin()
        _ = swipe.move(dx: 60, dy: 0, canBack: true, canForward: true)
        XCTAssertEqual(swipe.arrowPull, 0.5)
        _ = swipe.move(dx: 60, dy: 0, canBack: true, canForward: true)
        XCTAssertEqual(swipe.arrowPull, 1)
        var previous = swipe.arrowPull, increment = Double.infinity
        for _ in 0..<4 {
            _ = swipe.move(dx: 30, dy: 0, canBack: true, canForward: true)
            let next = swipe.arrowPull - previous
            XCTAssertGreaterThan(next, 0); XCTAssertLessThan(next, increment)
            previous = swipe.arrowPull; increment = next
        }
        XCTAssertLessThan(swipe.arrowPull, 1.5)
        XCTAssertEqual(HistoryArrowButton.returnFactor(elapsed: 0, committed: true), 1)
        XCTAssertLessThan(HistoryArrowButton.returnFactor(elapsed: 0.2, committed: true), 0)
        XCTAssertEqual(HistoryArrowButton.returnFactor(elapsed: 0.55, committed: true), 0, accuracy: 0.001)
        XCTAssertEqual(HistoryArrowButton.returnFactor(elapsed: 0.16, committed: false), 0, accuracy: 0.001)
    }
    @MainActor func testArrowheadShortensAndReversedReleaseStillSpringsWithoutCommitting() async throws {
        _ = NSApplication.shared
        let arrow = HistoryArrowButton(direction: .back, title: "Back", action: {})
        arrow.frame = NSRect(x: 0, y: 0, width: 28, height: 30)
        arrow.drag(pull: 0, armed: false)
        let shape = try XCTUnwrap(arrow.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let restingHeight = try XCTUnwrap(shape.path).boundingBox.height
        arrow.drag(pull: 1, armed: true)
        XCTAssertEqual(try XCTUnwrap(shape.path).boundingBox.height, restingHeight * 0.65, accuracy: 0.001, "The head's points are about a third shorter at the threshold")
        arrow.drag(pull: 0.8, armed: false)
        XCTAssertFalse(arrow.armed)
        XCTAssertEqual(shape.strokeColor, arrow.contentTintColor?.cgColor)
        arrow.release(committed: false)
        try await Task.sleep(for: .milliseconds(220))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(arrow.isReturning)
            XCTAssertLessThan(arrow.pull, 0, "Changing your mind still lets the arrow bounce home")
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(arrow.isReturning); XCTAssertEqual(arrow.pull, 0)
    }
    @MainActor func testArrowKeepsItsFrameAndRestoresItsOriginalSymbolAfterSpring() async throws {
        _ = NSApplication.shared
        let arrow = HistoryArrowButton(direction: .back, title: "Back", action: {})
        let frame = NSRect(x: 80, y: 9, width: 28, height: 30); arrow.frame = frame
        let image = arrow.image
        arrow.drag(pull: 1.2, armed: true)
        XCTAssertEqual(arrow.frame, frame); XCTAssertNil(arrow.image)
        arrow.release(committed: true)
        try await Task.sleep(for: .milliseconds(620))
        XCTAssertFalse(arrow.isReturning); XCTAssertEqual(arrow.pull, 0)
        XCTAssertTrue(arrow.image === image); XCTAssertEqual(arrow.frame, frame)
    }
}

/// A swipe held past the threshold shows the pages that way and goes to the one picked.
final class HistorySwipeListTests: XCTestCase {
    /// `x` towards Back, `scroll` the event's vertical scroll (content moving down).
    @MainActor private func event(_ phase: NSEvent.Phase, x: Int32 = 0, scroll: Int32 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: scroll, wheel2: -x, wheel3: 0)!
        let raw: Int64 = phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: raw)
        return NSEvent(cgEvent: cg)!
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testHeldSwipeListsPagesAndReleaseGoesToThePickedOne() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false)
        defer { browser.historySwipe.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil) }
        let page = BlankPage()
        page.scriptAnswer = { $0 == HistorySwipeController.scrollProbe ? true : nil }
        let pages = ["a", "b", "c", "d"].map { URL(string: "https://\($0).example/")! }
        for url in pages { page.load(url) }
        try await wait { page.url == pages[3] }
        let router = HistorySwipeController(window: browser.window as! BrowserWindow, pageAt: { _ in page }, feedback: { _, _, _, _ in })
        defer { router.cancel() }
        var lists: [[String]?] = [], selections: [Int] = [], drags = 0, releases = 0, ticks = 0
        router.listEntries = { page, direction in browser.historyListEntries(for: page, direction) }
        router.indicatorDrag = { _, _, _, _ in drags += 1 }
        router.indicatorList = { lists.append($0?.map(\.title)) }
        router.indicatorSelect = { selections.append($0) }
        router.indicatorRelease = { releases += 1 }
        router.thresholdClick = {}; router.selectionClick = { ticks += 1 }

        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        XCTAssertTrue(lists.isEmpty, "The list waits for the swipe to be held")
        try await wait { !lists.isEmpty }
        XCTAssertEqual(lists, [["c.example", "b.example", "a.example"]], "Nearest first")
        XCTAssertTrue(router.handle(event(.changed, scroll: 12)))
        XCTAssertTrue(router.handle(event(.changed, scroll: 15)))
        XCTAssertEqual(selections, [1, 2]); XCTAssertEqual(ticks, 2)
        XCTAssertTrue(router.handle(event(.ended)))
        XCTAssertEqual(releases, 1)
        try await wait { page.url == pages[0] }
        XCTAssertGreaterThan(drags, 0)

        // Going back under the threshold folds the list; a release there goes nowhere.
        lists = []
        XCTAssertTrue(router.handle(event(.began, x: -130)))
        try await wait { lists.count == 1 }
        XCTAssertEqual(lists.first??.count, 3, "Forward lists the pages ahead")
        XCTAssertTrue(router.handle(event(.changed, x: 100)))
        XCTAssertEqual(lists.count, 2); XCTAssertNil(lists[1] as [String]?)
        XCTAssertTrue(router.handle(event(.ended)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(page.url, pages[0])

        // A page with one page that way shows no list.
        page.goForward(); try await wait { page.url == pages[1] }
        lists = []
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await Task.sleep(for: .milliseconds(Int(HistorySwipeController.listDelay*1000)+200))
        XCTAssertTrue(lists.isEmpty)
        XCTAssertTrue(router.handle(event(.ended)))
        try await wait { page.url == pages[0] }
    }
}
