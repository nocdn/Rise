import XCTest
import AppKit
import WebKit
@testable import Rise

final class HistorySwipeTests: XCTestCase {
    func testMirroredThresholdOnlySwipesClickOnceAndCommitOnlyWhenArmedOnRelease() {
        for sign in [1.0, -1.0] {
            var swipe = HistorySwipeState(); swipe.begin()
            var clicks = 0
            for dx in [2.0, 4, 40, -6, 80, 100, -500, 500] {
                if swipe.move(dx: sign * dx, dy: 0, canBack: true, canForward: true) { clicks += 1 }
            }
            XCTAssertEqual(clicks, 1)
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
            XCTAssertFalse(swipe.move(dx: sign * 110, dy: 0, canBack: true, canForward: true),
                "Rearming within the same gesture must not produce another haptic")
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
    @MainActor private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor private func event(_ phase: NSEvent.Phase, fingerX: Int32 = 0,
                                  momentum: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                         wheel1: 0, wheel2: -fingerX, wheel3: 0)!
        // Quartz phase flags omit AppKit's stationary bit.
        let raw: Int64 = phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: raw)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }
    @MainActor func testRealWebKitHistoryNavigatesOnReleaseAndIgnoresMomentumAndCancellation() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), restore: false)
        let tab = browser.addTab(); let web = tab.webView
        defer {
            browser.historySwipe.cancel(); browser.saveWork?.cancel(); web.stopLoading()
            browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: directory)
        }
        for name in ["one", "two", "three"] {
            let url = directory.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
            web.loadFileURL(url, allowingReadAccessTo: directory)
            try await waitUntil("Loaded \(name)") { web.title == name && !web.isLoading }
        }
        XCTAssertTrue(web.canGoBack)
        XCTAssertFalse(web.allowsBackForwardNavigationGestures)
        var clicks = 0, pulls = [Double](), releases = [Bool]()
        let router = HistorySwipeController(window: browser.window as! BrowserWindow, pageAt: { _ in web },
            feedback: { _, pull, _, release in if let release { releases.append(release) } else { pulls.append(pull) } })
        router.thresholdClick = { clicks += 1 }
        XCTAssertTrue(router.handle(event(.began, fingerX: 10)))
        // Give the real isolated DOM probe time to resolve, then reach 120 pt.
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(router.handle(event(.changed, fingerX: 110)))
        XCTAssertEqual(clicks, 1); XCTAssertEqual(web.title, "three")
        XCTAssertEqual(pulls.last, 1)
        XCTAssertTrue(router.handle(event(.changed, fingerX: 100)))
        XCTAssertEqual(clicks, 1)
        XCTAssertTrue(router.handle(event(.ended)))
        try await waitUntil("Released back swipe navigates") { web.title == "two" && !web.isLoading }
        XCTAssertEqual(releases, [true])
        XCTAssertTrue(router.handle(event([], fingerX: 250, momentum: 1)))
        XCTAssertTrue(router.handle(event([], fingerX: 250, momentum: 3)))
        XCTAssertEqual(clicks, 1); XCTAssertEqual(web.title, "two")
        XCTAssertTrue(router.handle(event(.began, fingerX: -120)))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(clicks, 2); XCTAssertEqual(web.title, "two")
        XCTAssertTrue(router.handle(event(.cancelled)))
        XCTAssertEqual(releases.last, false); XCTAssertEqual(web.title, "two")
        XCTAssertTrue(router.handle(event(.began, fingerX: -140)))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(router.gesture.isArmed)
        XCTAssertTrue(router.handle(event(.changed, fingerX: 21)))
        XCTAssertFalse(router.gesture.isArmed)
        XCTAssertTrue(router.handle(event(.ended)))
        XCTAssertEqual(releases.last, false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(web.title, "two", "A reversed swipe must not navigate on release")
        XCTAssertTrue(router.handle(event(.began, fingerX: -120)))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(router.handle(event(.ended)))
        try await waitUntil("Released forward swipe navigates") { web.title == "three" && !web.isLoading }
        XCTAssertEqual(clicks, 4)
        router.cancel()
    }
    @MainActor func testDOMProbePreservesHorizontalContainersShadowDOMIframesAndZoom() async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString("""
        <!doctype html><style>body{margin:0} .scroll{width:200px;height:100px;overflow-x:auto}
        .wide{width:1000px;height:40px}</style>
        <div class=scroll><div class=wide>Carousel</div></div>
        <div id=shadow></div><iframe style='width:200px;height:100px' srcdoc='page'></iframe>
        <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML=
        '<div style="width:200px;height:100px;overflow:auto"><div style="width:1000px">Shadow scroll</div></div>'</script>
        """, baseURL: nil)
        try await waitUntil("Fixture ready") { !web.isLoading }
        for (point, allowed) in [(NSPoint(x: 40, y: 30), false), (.init(x: 40, y: 130), false),
                                 (.init(x: 40, y: 240), false), (.init(x: 400, y: 400), true)] {
            let result = try await web.callAsyncJavaScript(HistorySwipeController.scrollProbe,
                arguments: ["x": point.x, "y": point.y, "width": 800, "height": 600],
                in: nil, contentWorld: HistorySwipeController.world)
            XCTAssertEqual(result as? Bool, allowed)
        }
        web.pageZoom = 1.5
        let result = try await web.callAsyncJavaScript(HistorySwipeController.scrollProbe,
            arguments: ["x": 40, "y": 30, "width": 800, "height": 600],
            in: nil, contentWorld: HistorySwipeController.world)
        XCTAssertEqual(result as? Bool, false)
        web.stopLoading()
    }
    @MainActor func testArrowheadShortensAndReversedReleaseStillSpringsWithoutCommitting() async throws {
        _ = NSApplication.shared
        let arrow = HistoryArrowButton(direction: .back, title: "Back", action: {})
        arrow.frame = NSRect(x: 0, y: 0, width: 28, height: 30)
        arrow.drag(pull: 0, armed: false)
        let shape = try XCTUnwrap(arrow.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let restingHeight = try XCTUnwrap(shape.path).boundingBox.height
        arrow.drag(pull: 1, armed: true)
        XCTAssertEqual(try XCTUnwrap(shape.path).boundingBox.height, restingHeight * 0.75, accuracy: 0.001)
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
