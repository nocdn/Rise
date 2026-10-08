import XCTest
import CoreGraphics
@testable import Rise

final class FloatingVideoResizeMotionTests: XCTestCase {
    let screen = CGRect(x: -1440, y: 25, width: 1440, height: 875)

    private func resize(corner: CGPoint = .zero, aspect: CGFloat = 16.0/9) -> FloatingVideoResizeMotion {
        let size = CGSize(width: 360, height: 360/aspect)
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
        let origin = CGPoint(x: corner.x == 0 ? limits.minX : limits.maxX, y: corner.y == 0 ? limits.minY : limits.maxY)
        return FloatingVideoResizeMotion(videoFrame: CGRect(origin: origin, size: size), visibleFrame: screen)
    }

    func testPinchKeepsAspectAndTheScreenCornerAnchored() {
        for x: CGFloat in [0, 1] {
            for y: CGFloat in [0, 1] {
                var motion = resize(corner: CGPoint(x: x, y: y))
                let before = motion.videoFrame
                motion.begin(); motion.magnify(by: 0.1); motion.magnify(by: 0.2)
                XCTAssertEqual(motion.width, 468, accuracy: 0.001)
                XCTAssertEqual(motion.videoFrame.width/motion.videoFrame.height, 16.0/9, accuracy: 0.001)
                XCTAssertEqual(x == 0 ? motion.videoFrame.minX : motion.videoFrame.maxX, x == 0 ? before.minX : before.maxX, accuracy: 0.001)
                XCTAssertEqual(y == 0 ? motion.videoFrame.minY : motion.videoFrame.maxY, y == 0 ? before.minY : before.maxY, accuracy: 0.001)
                motion.end(); XCTAssertEqual(motion.phase, .idle)
            }
        }
    }

    func testTheSourceViewportCapsTheSizeSoTheCanvasIsNeverCropped() {
        let frame = CGRect(x: -1432, y: 33, width: 360, height: 202.5)
        // A split page 600pt wide and 300pt tall: height binds first at 16:9.
        var motion = FloatingVideoResizeMotion(videoFrame: frame, visibleFrame: screen, maximumSize: CGSize(width: 600, height: 300))
        XCTAssertEqual(motion.maximumWidth, 300*16/9, accuracy: 0.001)
        motion.begin(); motion.magnify(by: 5); motion.end(reduceMotion: true)
        XCTAssertLessThanOrEqual(motion.videoFrame.width, 600)
        XCTAssertLessThanOrEqual(motion.videoFrame.height, 300.001)
    }

    func testBothSizeLimitsResistAndBounceBackAtEveryRefreshRate() {
        for fps in [30.0, 60, 120] {
            for delta: CGFloat in [-100, 100] {
                var motion = resize()
                motion.begin(); motion.magnify(by: delta)
                let limit = delta < 0 ? motion.minimumWidth : motion.maximumWidth
                XCTAssertGreaterThan(abs(motion.width-limit), 0)
                XCTAssertLessThan(abs(motion.width-limit), 20)
                XCTAssertTrue(screen.contains(motion.videoFrame))
                motion.end(); XCTAssertEqual(motion.phase, .settling)
                let before = motion.width
                motion.step(elapsed: 1/fps)
                XCTAssertLessThan(abs(motion.width-limit), abs(before-limit))
                for _ in 0..<Int(fps*2) { motion.step(elapsed: 1/fps) }
                XCTAssertEqual(motion.phase, .idle)
                XCTAssertEqual(motion.width, limit)
                XCTAssertTrue(screen.contains(motion.videoFrame))
            }
        }
    }

    func testPortraitSizingFitsSmallAndNegativeCoordinateScreens() {
        let available = CGRect(x: -390, y: -780, width: 390, height: 780)
        var motion = FloatingVideoResizeMotion(videoFrame: CGRect(x: -300, y: -600, width: 150, height: 150/(9.0/16)), visibleFrame: available)
        motion.begin(); motion.magnify(by: 100); motion.end(reduceMotion: true)
        XCTAssertEqual(motion.phase, .idle)
        XCTAssertTrue(available.contains(motion.videoFrame))
        XCTAssertEqual(motion.videoFrame.width/motion.videoFrame.height, 9.0/16, accuracy: 0.001)
        motion.begin(); motion.magnify(by: -.infinity)
        XCTAssertTrue(motion.width.isFinite)
    }

    func testPinchingAgainDuringBouncePreservesTheCurrentSize() {
        var motion = resize()
        motion.begin(); motion.magnify(by: 100); motion.end()
        motion.step(elapsed: 1.0/60)
        var next = FloatingVideoResizeMotion(videoFrame: motion.videoFrame, visibleFrame: screen)
        next.begin(); next.magnify(by: 0)
        XCTAssertEqual(next.width, motion.width, accuracy: 0.001)
        next.magnify(by: -0.1)
        XCTAssertLessThan(next.width, motion.width)
    }

    func testMaximizedBrowserUsesOnePaddingForItsFourVisibleEdges() {
        let browser = screen.insetBy(dx: 8, dy: 3)
        let area = FloatingVideoMotion.placementArea(visibleFrame: screen, browserFrame: browser)
        let padding = FloatingVideoWindow.shadowInset
        let size = CGSize(width: 360+padding*2, height: 202.5+padding*2)
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: area, contentInset: padding)
        let leftBottom = CGRect(origin: limits.origin, size: size).insetBy(dx: padding, dy: padding)
        let rightTop = CGRect(x: limits.maxX, y: limits.maxY, width: size.width, height: size.height).insetBy(dx: padding, dy: padding)
        XCTAssertEqual(leftBottom.minX-browser.minX, leftBottom.minY-browser.minY)
        XCTAssertEqual(rightTop.maxX+8, browser.maxX)
        XCTAssertEqual(rightTop.maxY+8, browser.maxY)
        XCTAssertEqual(FloatingVideoMotion.placementArea(visibleFrame: screen, browserFrame: CGRect(x: -900, y: 200, width: 600, height: 400)), screen)
    }

    func testShadowMarginDoesNotIncreaseTheVisibleEdgeGap() {
        let padding = FloatingVideoWindow.shadowInset
        let size = CGSize(width: 360+padding*2, height: 202.5+padding*2)
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen, contentInset: padding)
        for origin in [limits.origin, CGPoint(x: limits.maxX, y: limits.maxY)] {
            let video = CGRect(origin: origin, size: size).insetBy(dx: padding, dy: padding)
            XCTAssertTrue(screen.contains(video))
            XCTAssertEqual(origin == limits.origin ? video.minX-screen.minX : screen.maxX-video.maxX, 8, accuracy: 0.001)
            XCTAssertEqual(origin == limits.origin ? video.minY-screen.minY : screen.maxY-video.maxY, 8, accuracy: 0.001)
        }
    }
}
