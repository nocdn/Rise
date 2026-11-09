import XCTest
import UIKit
@testable import RiseiOS

final class SummariseTests: XCTestCase {
    func testReadsTheSummarysParagraphs() throws {
        let reply = """
        **An essay** on templating.

        ```
        Escaping is on by default.
        """
        let summary = try PageSummary.decode(reply)
        XCTAssertEqual(summary.paragraphs, ["An essay on templating.", "Escaping is on by default."])
        XCTAssertThrowsError(try PageSummary.decode("  \n\n "))
    }

    /// The playground's springs: the reveal's and the close's, both critically damped.
    func testSpringsMatchThePlayground() {
        XCTAssertEqual(SummariseMotion.reveal(0), 0)
        XCTAssertEqual(SummariseMotion.reveal(0.1), 0.4004, accuracy: 1e-3)
        XCTAssertEqual(SummariseMotion.close(2), 1, accuracy: 1e-6)
    }

    /// The ChatGPT send's springs, as fitted to the recording; both are overdamped, and the
    /// sideways one leaves at its full measured speed.
    func testSendSpringsMatchTheRecording() {
        XCTAssertEqual(SendMotion.across(0.05), 0.7575, accuracy: 1e-3)
        XCTAssertEqual(SendMotion.up(0.15), 0.7605, accuracy: 1e-3)
        XCTAssertEqual(SendMotion.across(1e-6)/1e-6, 112, accuracy: 0.1)
    }

    /// A sent question leaves the field where its text was and lands in its bubble at the top of
    /// the screen, rising on the measured upward spring as the summary scrolls.
    func testSendFlightLiftsOffTheFieldIntoTheBubble() {
        let flight = SendFlight(from: CGPoint(x: 24, y: 640), to: CGPoint(x: 210, y: 642), scrollFrom: 300, scrollTo: 570)
        XCTAssertEqual(flight.onScreen(at: 0), CGPoint(x: 24, y: 340))
        XCTAssertEqual(flight.surface(at: SendMotion.surfaceDelay), 0)
        let mid = 0.15, end = flight.onScreen(at: flight.duration)
        XCTAssertEqual(flight.onScreen(at: mid).y, 340+(72-340)*SendMotion.up(mid), accuracy: 1e-9)
        XCTAssertEqual(end.x, 210, accuracy: SendMotion.settled)
        XCTAssertEqual(end.y, 72, accuracy: SendMotion.settled)
        XCTAssertEqual(flight.surface(at: flight.duration), 1)
        XCTAssertLessThan(flight.duration, SendMotion.longest)
    }

    /// Size alone is not enough: stopping the uncropped height at release changes the speed of
    /// both visible edges, even when the page's centre and width keep their momentum.
    @MainActor func testTabSwipeReleaseKeepsBothEdgesMoving() {
        let from = TabSwitcherView.Shape(x: 210, y: 380, scale: 0.75, height: 720, crop: 0.35, radius: 24)
        let target = TabSwitcherView.Shape(x: 105, y: 230, scale: 0.45, height: 560, crop: 1, radius: 18)
        let velocity = TabSwitcherView.Shape(x: -100, y: -800, scale: -1.2, height: -900, crop: 3, radius: -20)
        let flight = TabSwitcherView.Flight(from: from, to: target, t0: 0, velocity: velocity,
                                            scale: SummariseMotion.releaseScale, place: SummariseMotion.releaseMove,
                                            shape: SummariseMotion.placeCrop)
        let dt = 0.000001, next = flight.at(dt)
        let heightSpeed = velocity.height*from.scale+from.height*velocity.scale
        let top = from.y-from.height*from.scale/2, bottom = from.y+from.height*from.scale/2
        XCTAssertEqual((next.y-next.height*next.scale/2-top)/dt, velocity.y-heightSpeed/2, accuracy: 0.1)
        XCTAssertEqual((next.y+next.height*next.scale/2-bottom)/dt, velocity.y+heightSpeed/2, accuracy: 0.1)
        XCTAssertEqual((next.scale-from.scale)/dt, velocity.scale, accuracy: 0.001)
        XCTAssertEqual((next.crop-from.crop)/dt, velocity.crop, accuracy: 0.001)
        XCTAssertEqual((next.radius-from.radius)/dt, velocity.radius, accuracy: 0.001)
        XCTAssertEqual(flight.at(2).height, target.height, accuracy: 0.001)
    }

    /// Turning a landing page around carries its cropping speed too; its edges don't stop when
    /// its target changes, and it eventually restores the whole page.
    @MainActor func testTabFlightTurnaroundKeepsItsShapeVelocity() {
        let from = TabSwitcherView.Shape(x: 210, y: 380, scale: 0.75, height: 720, crop: 0.35, radius: 24)
        let card = TabSwitcherView.Shape(x: 105, y: 230, scale: 0.45, height: 560, crop: 1, radius: 18)
        let landing = TabSwitcherView.Flight(from: from, to: card, t0: 0, velocity: nil,
                                             scale: SummariseMotion.releaseScale, place: SummariseMotion.releaseMove,
                                             shape: SummariseMotion.placeCrop)
        let t = 0.08, dt = 0.000001, caught = landing.at(t)
        let speed = TabSwitcherView.Shape.velocity(from: landing.at(t-dt), to: caught, over: dt)
        let page = TabSwitcherView.Shape(x: 196.5, y: 426, scale: 1, height: 852, crop: 0, radius: 28.8)
        let returning = TabSwitcherView.Flight(from: caught, to: page, t0: t, velocity: speed,
                                               scale: SummariseMotion.cancel, place: SummariseMotion.cancel,
                                               shape: SummariseMotion.cancel)
        let next = returning.at(dt)
        XCTAssertEqual((next.height-caught.height)/dt, speed.height, accuracy: 0.1)
        XCTAssertEqual((next.crop-caught.crop)/dt, speed.crop, accuracy: 0.001)
        XCTAssertEqual((next.radius-caught.radius)/dt, speed.radius, accuracy: 0.01)
        let end = returning.at(2)
        XCTAssertEqual(end.scale, page.scale, accuracy: 0.001)
        XCTAssertEqual(end.height, page.height, accuracy: 0.001)
        XCTAssertEqual(end.crop, page.crop, accuracy: 0.001)
    }

    /// A final touch and release in the same event must not jump to a pose that hasn't reached
    /// the screen: the first keyframe starts from the visible page, with the visible strip crop.
    @MainActor func testFastTabSwipeStartsFromTheVisiblePage() async throws {
        let controller = BrowserViewController(startURL: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { controller.tabSwitcher.hide(); window.isHidden = true }

        controller.beginTabSwipe()
        controller.updateTabSwipe(CGPoint(x: 0, y: -50))
        try await Task.sleep(for: .milliseconds(80))
        let card = try XCTUnwrap(controller.tabSwitcher.moving)
        let shown = try XCTUnwrap(card.layer.presentation())
        let bounds = shown.bounds, position = shown.position
        let page = try XCTUnwrap(card.image.layer.presentation()).position
        // This new pose has not had an opportunity to display.
        controller.updateTabSwipe(CGPoint(x: 0, y: -110))
        controller.endTabSwipe(velocity: CGPoint(x: 0, y: -2400))
        let sizing = try XCTUnwrap(card.layer.animation(forKey: "flight.bounds") as? CAKeyframeAnimation)
        let placing = try XCTUnwrap(card.layer.animation(forKey: "flight.position") as? CAKeyframeAnimation)
        let cropping = try XCTUnwrap(card.image.layer.animation(forKey: "flight.position") as? CAKeyframeAnimation)
        let firstBounds = try XCTUnwrap(sizing.values?.first as? NSValue).cgRectValue
        let firstPosition = try XCTUnwrap(placing.values?.first as? NSValue).cgPointValue
        let firstPage = try XCTUnwrap(cropping.values?.first as? NSValue).cgPointValue
        XCTAssertEqual(firstBounds.width, bounds.width, accuracy: 0.01)
        XCTAssertEqual(firstBounds.height, bounds.height, accuracy: 0.01)
        XCTAssertEqual(firstPosition.x, position.x, accuracy: 0.01)
        XCTAssertEqual(firstPosition.y, position.y, accuracy: 0.01)
        XCTAssertEqual(firstPage.y, page.y, accuracy: 0.01)
    }

    /// The playground's pinch replay: the bar is gone while the card loads, the summary is
    /// revealed, and tapping the card grows it back into the page with the bar back in place.
    @MainActor func testPinchReplay() async throws {
        let controller = BrowserViewController(startURL: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let folder = ProcessInfo.processInfo.environment["RISE_SUMMARISE_FRAMES"].map { URL(fileURLWithPath: $0) }
        let result = await SummariseReplay.run(in: controller, savingFramesTo: folder)
        XCTAssertGreaterThan(result.barWhileLoading, controller.bottomBar.bounds.height)
        XCTAssertTrue(result.revealed)
        XCTAssertGreaterThan(result.summaryHeight, 200)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(controller.bottomBar.transform, .identity)
        XCTAssertTrue(controller.bottomBar.isUserInteractionEnabled)
    }

    /// Reusing the hosting controller must still request and lay out the next page's text,
    /// and must not keep the old scene, replica or display link alive.
    @MainActor func testSuccessiveSummariesUseFreshTextAndReleaseTheirScenes() async throws {
        let controller = BrowserViewController(startURL: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { controller.summarise?.finish(); window.isHidden = true }

        controller.webView.loadHTMLString("<html><body><p>A page to summarise.</p></body></html>",
                                          baseURL: URL(string: "https://rise.test/"))
        for _ in 0..<100 where controller.webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }

        let short = PageSummary(paragraphs: ["First page."])
        let long = PageSummary(paragraphs: [String(repeating: "A different page with much more to summarise. ", count: 40)])
        var heights: [CGFloat] = []
        weak var previous: SummariseView?
        for summary in [short, long] {
            controller.startSummarise(.pinch)
            var current: SummariseView? = try XCTUnwrap(controller.summarise)
            current?.manualTime = 0
            current?.makeSummary = { _ in summary }
            current?.startFromMenu()
            for _ in 0..<100 where current?.summaryHeight == 0 { try await Task.sleep(for: .milliseconds(10)) }
            heights.append(try XCTUnwrap(current).summaryHeight)
            current?.advance(to: 2.5)
            current?.close()
            current?.advance(to: 4)
            previous = current
            current = nil
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(controller.summarise)
            XCTAssertNil(previous)
            XCTAssertEqual(controller.bottomBar.transform, .identity)
            XCTAssertTrue(controller.bottomBar.isUserInteractionEnabled)
        }
        XCTAssertGreaterThan(heights[0], 50)
        XCTAssertGreaterThan(heights[1], heights[0]+300)
    }

    @MainActor func testRegrabbingAClosingSummaryKeepsItsTextAndRestoresThePage() async throws {
        let controller = BrowserViewController(startURL: nil)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { controller.summarise?.finish(); window.isHidden = true }
        let result = await SummariseReplay.run(in: controller, savingFramesTo: nil, regrab: true)
        XCTAssertTrue(result.revealed)
        XCTAssertGreaterThan(result.summaryHeight, 200)
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.pageMoved, 0, accuracy: 0.1)
        XCTAssertEqual(controller.bottomBar.transform, .identity)
        XCTAssertTrue(controller.bottomBar.isUserInteractionEnabled)
    }
}
