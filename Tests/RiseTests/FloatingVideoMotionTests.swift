import XCTest
import CoreGraphics
@testable import Rise

final class FloatingVideoMotionTests: XCTestCase {
    let screen = CGRect(x: -1440, y: 25, width: 1440, height: 875)
    let size = CGSize(width: 360, height: 202.5)

    func testFlicksSettleInEveryCornerWithoutEverDismissing() {
        for fps in [30.0, 60, 120] {
            for x: CGFloat in [-80, 80] {
                for y: CGFloat in [-80, 80] {
                    let start = CGRect(x: -900, y: 350, width: size.width, height: size.height)
                    var motion = FloatingVideoMotion(frame: start, visibleFrame: screen)
                    motion.begin(at: 0)
                    for step in 1...6 {
                        motion.drag(by: CGVector(dx: x, dy: y), at: Double(step)/120)
                        motion.step(elapsed: 1.0/120)
                    }
                    motion.end(at: 0.05)
                    for _ in 0..<Int(fps*5) { motion.step(elapsed: 1/fps) }
                    let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
                    XCTAssertEqual(motion.phase, .idle)
                    XCTAssertEqual(motion.frame.minX, x > 0 ? limits.maxX : limits.minX)
                    XCTAssertEqual(motion.frame.minY, y > 0 ? limits.maxY : limits.minY)
                    XCTAssertTrue(screen.contains(motion.frame))
                }
            }
        }
    }

    func testOffscreenThrowRubberBandsAndReturnsFullyOnScreen() {
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
        for delta: CGFloat in [-100_000, 100_000] {
            var motion = FloatingVideoMotion(frame: CGRect(origin: limits.origin, size: size), visibleFrame: screen)
            motion.begin(at: 0); motion.drag(by: CGVector(dx: delta, dy: delta), at: 0.01)
            for _ in 0..<60 { motion.step(elapsed: 1.0/120) }
            XCTAssertGreaterThanOrEqual(motion.frame.minX, limits.minX-34)
            XCTAssertLessThanOrEqual(motion.frame.minX, limits.maxX+34)
            motion.end(at: 0.015)
            for _ in 0..<600 { motion.step(elapsed: 1.0/120) }
            XCTAssertEqual(motion.phase, .idle)
            XCTAssertTrue(screen.contains(motion.frame))
        }
    }

    func testSlowDragsStayAtTheirPlacementAcrossFrameRatesAndCanBeFlickedAgain() {
        for fps in [30.0, 60, 120] {
            let start = CGRect(x: -900, y: 350, width: size.width, height: size.height)
            var motion = FloatingVideoMotion(frame: start, visibleFrame: screen)
            motion.begin(at: 0)
            for step in 1...Int(fps) {
                motion.drag(by: CGVector(dx: 120/fps, dy: 60/fps), at: Double(step)/fps)
                motion.step(elapsed: 1/fps)
            }
            motion.end(at: 1)
            for _ in 0..<Int(fps*3) { motion.step(elapsed: 1/fps) }
            XCTAssertEqual(motion.phase, .idle)
            XCTAssertEqual(motion.frame.minX, start.minX+120, accuracy: 0.01)
            XCTAssertEqual(motion.frame.minY, start.minY+60, accuracy: 0.01)
            let placed = motion.frame
            motion.begin(at: 5)
            XCTAssertEqual(motion.frame, placed)
            motion.drag(by: CGVector(dx: -100, dy: 100), at: 5.01)
            motion.end(at: 5.01)
            for _ in 0..<Int(fps*3) { motion.step(elapsed: 1/fps) }
            let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
            XCTAssertEqual(motion.frame.origin, CGPoint(x: limits.minX, y: limits.maxY))
        }
    }

    func testPausingAfterAFastMovePlacesTheWindowInsteadOfFlickingIt() {
        let start = CGRect(x: -900, y: 350, width: size.width, height: size.height)
        var motion = FloatingVideoMotion(frame: start, visibleFrame: screen)
        motion.begin(at: 0)
        motion.drag(by: CGVector(dx: 130, dy: 80), at: 0.01)
        for _ in 0..<60 { motion.step(elapsed: 1.0/120) }
        motion.end(at: 0.51)
        for _ in 0..<360 { motion.step(elapsed: 1.0/120) }
        XCTAssertEqual(motion.phase, .idle)
        XCTAssertEqual(motion.frame.origin, CGPoint(x: start.minX+130, y: start.minY+80))
    }

    func testCancelledDragOnlyBringsAnOffscreenWindowBackToTheEdge() {
        let start = CGRect(x: -900, y: 350, width: size.width, height: size.height)
        var motion = FloatingVideoMotion(frame: start, visibleFrame: screen)
        motion.begin(at: 0); motion.drag(by: CGVector(dx: -100_000, dy: 0), at: 0.01)
        for _ in 0..<60 { motion.step(elapsed: 1.0/120) }
        motion.end(at: 0.51, cancelled: true)
        for _ in 0..<360 { motion.step(elapsed: 1.0/120) }
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
        XCTAssertEqual(motion.frame.minX, limits.minX)
        XCTAssertEqual(motion.frame.minY, start.minY, "Clamping to the screen must not pull a placement into a corner")
    }

    func testGrabbingDuringSettleKeepsCurrentPositionAndIdleReleaseDropsMomentum() {
        var motion = FloatingVideoMotion(frame: CGRect(x: -900, y: 350, width: size.width, height: size.height), visibleFrame: screen)
        motion.begin(at: 0); motion.drag(by: CGVector(dx: 130, dy: 80), at: 0.01)
        motion.step(elapsed: 1.0/120); motion.end(at: 0.01); motion.step(elapsed: 1.0/120)
        let current = motion.frame
        motion.begin(at: 0.02)
        XCTAssertEqual(motion.frame, current)
        XCTAssertEqual(motion.velocity, .zero)
        motion.drag(by: CGVector(dx: -10, dy: -10), at: 0.03)
        motion.end(at: 2)
        XCTAssertLessThan(hypot(motion.velocity.dx, motion.velocity.dy), 0.001)
        for _ in 0..<600 { motion.step(elapsed: 1.0/120, reduceMotion: true) }
        XCTAssertEqual(motion.phase, .idle)
        XCTAssertTrue(screen.contains(motion.frame))
    }

    func testYouTubeScopeDoesNotMatchOtherSitesOrFeedVideos() {
        for address in ["https://www.youtube.com/watch?v=123", "https://m.youtube.com/shorts/123", "https://youtube.com/live/123", "https://www.youtube.com/embed/123"] {
            XCTAssertTrue(YouTubeVideoPage.containsVideo(URL(string: address)))
        }
        for address in ["https://youtube.com/", "https://youtube.com/watch", "https://youtube.com/watch?v=", "https://youtube.com/shorts/", "http://youtube.com/watch?v=123", "https://youtube.com.evil.test/watch?v=123", "https://notyoutube.com/watch?v=123", "https://vimeo.com/123"] {
            XCTAssertFalse(YouTubeVideoPage.containsVideo(URL(string: address)))
        }
    }
}

final class FloatingLiftTests: XCTestCase {
    func testLiftsWithALightBounceAndIsBackBeforeAFlickLands() {
        var lift = FloatingLift()
        lift.lift(true)
        var peak: CGFloat = 1, time = 0.0
        while !lift.isResting { lift.step(elapsed: 1.0/120); time += 1.0/120; peak = max(peak, lift.value) }
        XCTAssertEqual(lift.value, FloatingLift.scale)
        XCTAssertGreaterThan(peak, FloatingLift.scale, "It overshoots a little")
        XCTAssertLessThan(peak, FloatingLift.scale+0.003, "But only a little")
        XCTAssertLessThan(time, 0.8)

        // Released into a flick: back to its size before the window settles in its corner.
        lift.lift(false)
        var motion = FloatingVideoMotion(frame: CGRect(x: 400, y: 300, width: 360, height: 240),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        motion.begin(at: 0)
        for frame in 1...6 { motion.drag(by: CGVector(dx: 30, dy: 20), at: Double(frame)/120) }
        motion.end(at: 6.0/120)
        var landed = false
        while motion.phase != .idle {
            motion.step(elapsed: 1.0/120); lift.step(elapsed: 1.0/120)
            if hypot(motion.velocity.dx, motion.velocity.dy) < 60 && motion.phase == .settling { landed = true }
            if landed { XCTAssertEqual(lift.value, 1, accuracy: 0.002); break }
        }
        XCTAssertTrue(landed)
    }
}
