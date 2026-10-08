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
