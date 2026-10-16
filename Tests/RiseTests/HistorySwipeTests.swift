import XCTest
import AppKit
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
