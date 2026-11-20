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

    /// A quick sideways flick, as Snap would dismiss its preview with.
    private func flick(_ motion: inout FloatingVideoMotion, dx: CGFloat, dy: CGFloat = 0, at start: TimeInterval = 0) {
        motion.begin(at: start)
        for step in 1...4 {
            motion.drag(by: CGVector(dx: dx, dy: dy), at: start+Double(step)/120)
            motion.step(elapsed: 1.0/120)
        }
        motion.end(at: start+4.0/120)
    }
    private func settle(_ motion: inout FloatingVideoMotion, seconds: Double = 4) {
        for _ in 0..<Int(seconds*120) { motion.step(elapsed: 1.0/120) }
    }

    func testFlickingOffEitherSideTucksAllButATenthAwayAtItsHeight() {
        for dx: CGFloat in [-30, 30] {
            // Snap's rule: the flick's projection has to cross the side, so from near it.
            let start = CGRect(x: dx < 0 ? -1300 : -500, y: 350, width: size.width, height: size.height)
            var motion = FloatingVideoMotion(frame: start, visibleFrame: screen)
            flick(&motion, dx: dx)
            XCTAssertEqual(motion.tucked, dx < 0 ? .left : .right)
            settle(&motion)
            XCTAssertEqual(motion.phase, .idle)
            let onScreen = motion.frame.intersection(screen).width
            XCTAssertEqual(onScreen, size.width*0.1, accuracy: 0.5)
            XCTAssertEqual(motion.frame.minY, start.minY, accuracy: 1)
            XCTAssertEqual(FloatingVideoMotion.tuckProgress(content: motion.frame, visibleFrame: screen), 1, accuracy: 0.001)
        }
    }

    func testASideAnotherDisplayCarriesOnFromNeverTucks() {
        var motion = FloatingVideoMotion(frame: CGRect(x: -1300, y: 350, width: size.width, height: size.height),
                                         visibleFrame: screen, tuckable: [.right])
        flick(&motion, dx: -30)
        XCTAssertNil(motion.tucked)
        settle(&motion)
        XCTAssertTrue(screen.contains(motion.frame))
    }

    func testFlicksOffTheTopOrBottomStillGoToACorner() {
        for dy: CGFloat in [-30, 30] {
            var motion = FloatingVideoMotion(frame: CGRect(x: -900, y: 350, width: size.width, height: size.height), visibleFrame: screen)
            flick(&motion, dx: -6, dy: dy)
            XCTAssertNil(motion.tucked)
            settle(&motion)
            XCTAssertTrue(screen.contains(motion.frame))
        }
    }

    func testATuckedWindowComesBackToTheSideItLeftAndCanBeStoppedOnItsWay() {
        let start = CGRect(x: -900, y: 350, width: size.width, height: size.height)
        var motion = FloatingVideoMotion(frame: start, visibleFrame: screen)
        flick(&motion, dx: -30)
        settle(&motion)
        motion.untuck()
        XCTAssertNil(motion.tucked)
        settle(&motion)
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
        XCTAssertEqual(motion.frame.origin, CGPoint(x: limits.minX, y: motion.frame.minY))
        XCTAssertEqual(FloatingVideoMotion.tuckProgress(content: motion.frame, visibleFrame: screen), 0)

        // Brought back while still on its way out, it turns round.
        flick(&motion, dx: -30, at: 10)
        for _ in 0..<6 { motion.step(elapsed: 1.0/120) }
        motion.untuck()
        settle(&motion)
        XCTAssertEqual(motion.frame.minX, limits.minX)
    }

    func testDraggingATuckedWindowOutBringsItBackAndANudgeLeavesItTucked() {
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
        let tuckedX = FloatingVideoMotion.tuckedX(.left, width: size.width, visibleFrame: screen)
        for (distance, staysTucked) in [(CGFloat(40), true), (CGFloat(260), false)] {
            var motion = FloatingVideoMotion(frame: CGRect(x: tuckedX, y: 350, width: size.width, height: size.height),
                                             visibleFrame: screen, tucked: .left)
            motion.begin(at: 0)
            for step in 1...60 { motion.drag(by: CGVector(dx: distance/60, dy: 0), at: Double(step)/60); motion.step(elapsed: 1.0/60) }
            motion.end(at: 1.5)
            settle(&motion)
            XCTAssertEqual(motion.tucked, staysTucked ? .left : nil)
            XCTAssertEqual(motion.frame.minX, staysTucked ? tuckedX : max(limits.minX, tuckedX+distance), accuracy: 0.5)
        }
        // Flicked back the way it came, it stays; flicked out, it's back on the screen.
        for (dx, staysTucked) in [(CGFloat(-12), true), (CGFloat(12), false)] {
            var motion = FloatingVideoMotion(frame: CGRect(x: tuckedX, y: 350, width: size.width, height: size.height),
                                             visibleFrame: screen, tucked: .left)
            flick(&motion, dx: dx)
            settle(&motion)
            XCTAssertEqual(motion.tucked, staysTucked ? .left : nil)
            if !staysTucked { XCTAssertTrue(screen.contains(motion.frame)) }
        }
    }

    /// Flicked off the left side from `start`, and settled there tucked.
    private func tucked(from start: CGPoint) -> FloatingVideoMotion {
        var motion = FloatingVideoMotion(frame: CGRect(origin: start, size: size), visibleFrame: screen)
        flick(&motion, dx: -40)
        XCTAssertEqual(motion.tucked, .left, "Thrown hard enough to tuck")
        settle(&motion)
        return motion
    }

    func testATuckedWindowComesBackToWhereItWasBeforeByClickOrFlick() {
        let start = CGPoint(x: -1100, y: 400)
        // Clicked: back to its place, not merely onto the screen at the side.
        var clicked = tucked(from: start)
        clicked.untuck(); settle(&clicked)
        XCTAssertEqual(clicked.frame.origin.x, start.x, accuracy: 0.5)
        XCTAssertEqual(clicked.frame.origin.y, start.y, accuracy: 0.5)

        // Flicked out with two fingers: the same place, not a corner.
        var flicked = tucked(from: start)
        flick(&flicked, dx: 40, at: 10)
        XCTAssertNil(flicked.tucked)
        settle(&flicked)
        XCTAssertEqual(flicked.frame.origin.x, start.x, accuracy: 0.5)
        XCTAssertEqual(flicked.frame.origin.y, start.y, accuracy: 0.5)

        // Moved up while tucked, it comes back as far up.
        var moved = tucked(from: start)
        moved.begin(at: 10)
        for step in 1...60 { moved.drag(by: CGVector(dx: 0, dy: 2), at: 10+Double(step)/60); moved.step(elapsed: 1.0/60) }
        moved.end(at: 12)
        settle(&moved)
        XCTAssertEqual(moved.tucked, .left)
        moved.untuck(); settle(&moved)
        XCTAssertEqual(moved.frame.origin.x, start.x, accuracy: 0.5)
        XCTAssertEqual(moved.frame.origin.y, start.y+120, accuracy: 0.5)
    }

    func testFlicksUpAndDownKeepATuckedWindowTucked() {
        let start = CGPoint(x: -1100, y: 400)
        let tuckedX = FloatingVideoMotion.tuckedX(.left, width: size.width, visibleFrame: screen)
        // Straight up, and up with a little way out, as moving it out of the way does.
        for (dx, dy) in [(CGFloat(0), CGFloat(30)), (12, 30), (-8, -30)] {
            var motion = tucked(from: start)
            flick(&motion, dx: dx, dy: dy, at: 10)
            XCTAssertEqual(motion.tucked, .left, "A flick of \(dx), \(dy) leaves it tucked")
            settle(&motion)
            XCTAssertEqual(motion.frame.minX, tuckedX, accuracy: 0.5)
            XCTAssertGreaterThan(abs(motion.frame.minY-start.y), 4*abs(dy), "Thrown on up or down by the flick")
            let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: screen)
            XCTAssertTrue((limits.minY...limits.maxY).contains(motion.frame.minY))
        }
        // Out, mostly sideways: it's back.
        var out = tucked(from: start)
        flick(&out, dx: 30, dy: 12, at: 10)
        XCTAssertNil(out.tucked)
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

final class FloatingEdgeResizeTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let video = CGRect(x: 300, y: 300, width: 360, height: 202.5)
    private func resize(_ handle: FloatingVideoEdgeResize.Handle, from video: CGRect? = nil, by delta: CGVector) -> CGRect {
        let video = video ?? self.video
        let pointer = CGPoint(x: handle.x < 0 ? video.minX : handle.x > 0 ? video.maxX : video.midX,
                              y: handle.y < 0 ? video.minY : handle.y > 0 ? video.maxY : video.midY)
        let edge = FloatingVideoEdgeResize(handle: handle, videoFrame: video, pointer: pointer, visibleFrame: screen, minimumWidth: 180, maximumWidth: 760)
        return edge.videoFrame(pointer: CGPoint(x: pointer.x+delta.dx, y: pointer.y+delta.dy))
    }

    func testTheEdgesAndCornersTakeThePointerAndTheMiddleDoesNot() {
        typealias Handle = FloatingVideoEdgeResize.Handle
        let cases: [(CGPoint, Handle?)] = [
            (CGPoint(x: video.maxX+2, y: video.midY), Handle(x: 1, y: 0)),
            (CGPoint(x: video.minX+2, y: video.midY), Handle(x: -1, y: 0)),
            (CGPoint(x: video.midX, y: video.maxY-1), Handle(x: 0, y: 1)),
            (CGPoint(x: video.midX, y: video.minY-3), Handle(x: 0, y: -1)),
            (CGPoint(x: video.maxX-1, y: video.maxY-1), Handle(x: 1, y: 1)),
            // Along an edge near a corner, it's the corner.
            (CGPoint(x: video.minX+12, y: video.maxY-2), Handle(x: -1, y: 1)),
            (CGPoint(x: video.maxX-2, y: video.minY+12), Handle(x: 1, y: -1)),
            // Inside, as the close button is, or well outside: none.
            (CGPoint(x: video.minX+12, y: video.maxY-12), nil),
            (CGPoint(x: video.midX, y: video.midY), nil),
            (CGPoint(x: video.maxX+8, y: video.midY), nil),
        ]
        for (point, handle) in cases { XCTAssertEqual(FloatingVideoEdgeResize.handle(at: point, in: video), handle, "\(point)") }
    }

    func testAnEdgeResizesAboutTheOppositeOneKeepingItsShape() {
        let wider = resize(.init(x: 1, y: 0), by: CGVector(dx: 90, dy: 40))
        XCTAssertEqual(wider.width, 450, accuracy: 0.01)
        XCTAssertEqual(wider.width/wider.height, video.width/video.height, accuracy: 0.0001)
        XCTAssertEqual(wider.minX, video.minX, accuracy: 0.01, "The left side stays")
        XCTAssertEqual(wider.midY, video.midY, accuracy: 0.01, "Its middle stays the other way")

        let shorter = resize(.init(x: 0, y: 1), by: CGVector(dx: 0, dy: -50))
        XCTAssertEqual(shorter.height, video.height-50, accuracy: 0.01)
        XCTAssertEqual(shorter.minY, video.minY, accuracy: 0.01, "The bottom stays")
        XCTAssertEqual(shorter.midX, video.midX, accuracy: 0.01)

        // A corner: the opposite one stays, and the drag along its diagonal sets the size.
        let corner = resize(.init(x: -1, y: -1), by: CGVector(dx: -64, dy: -36))
        XCTAssertEqual(corner.maxX, video.maxX, accuracy: 0.01)
        XCTAssertEqual(corner.maxY, video.maxY, accuracy: 0.01)
        XCTAssertEqual(corner.width, video.width+64, accuracy: 0.5)
        XCTAssertEqual(corner.width/corner.height, video.width/video.height, accuracy: 0.0001)
    }

    func testItStaysWithinItsLimitsAndTheScreen() {
        XCTAssertEqual(resize(.init(x: 1, y: 0), by: CGVector(dx: 5000, dy: 0)).width, 760, accuracy: 0.01)
        XCTAssertEqual(resize(.init(x: -1, y: 0), by: CGVector(dx: 5000, dy: 0)).width, 180, accuracy: 0.01)
        // Against the right side, pulling the right edge can't take it off the screen.
        let atRight = CGRect(x: screen.maxX-8-360, y: 300, width: 360, height: 202.5)
        let pulled = resize(.init(x: 1, y: 0), from: atRight, by: CGVector(dx: 200, dy: 0))
        XCTAssertEqual(pulled, atRight)
        // Against the bottom, its left edge pulled keeps it on the bottom.
        let atBottom = CGRect(x: 300, y: 8, width: 360, height: 202.5)
        let grown = resize(.init(x: -1, y: 0), from: atBottom, by: CGVector(dx: -100, dy: 0))
        XCTAssertEqual(grown.minY, 8, accuracy: 0.01)
        XCTAssertEqual(grown.maxX, atBottom.maxX, accuracy: 0.01)
        XCTAssertTrue(screen.contains(grown))
    }
}
