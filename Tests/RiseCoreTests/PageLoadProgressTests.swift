import XCTest
@testable import RiseCore

final class PageLoadProgressTests: XCTestCase {
    func testSpringIsIndependentOfFrameRate() {
        let whole = PageLoadProgress.step(front: 0.1, target: 0.7, speed: 0.6, dt: 1.0/60)
        let half = PageLoadProgress.step(front: 0.1, target: 0.7, speed: 0.6, dt: 1.0/120)
        let twice = PageLoadProgress.step(front: half.front, target: 0.7, speed: half.speed, dt: 1.0/120)
        XCTAssertEqual(whole.front, twice.front, accuracy: 1e-12)
        XCTAssertEqual(whole.speed, twice.speed, accuracy: 1e-12)
    }
    func testIncreasingProgressKeepsMomentumWithoutOvershooting() {
        var front = 0.0, speed = 0.0
        for target in [0.2, 0.4, 0.7, 1.12] {
            for _ in 0..<120 {
                let step = PageLoadProgress.step(front: front, target: target, speed: speed, dt: 1.0/120)
                XCTAssertGreaterThanOrEqual(step.front, front)
                XCTAssertLessThanOrEqual(step.front, target)
                front = step.front; speed = step.speed
            }
        }
        XCTAssertGreaterThan(front, 1, "A finished load carries past the edge before fading")
    }
    func testPathKeepsTheTailThinAndTheFrontWithinItsProgress() {
        let path = PageLoadProgress.path(front: 210, centre: 12)
        XCTAssertEqual(path.boundingBox.minX, 0)
        XCTAssertEqual(path.boundingBox.maxX, 210, accuracy: 1e-9)
        XCTAssertEqual(path.boundingBox.midY, 12, accuracy: 1e-9)
        XCTAssertEqual(path.boundingBox.height, PageLoadProgress.Style().frontThickness, accuracy: 1e-9)
        XCTAssertTrue(path.contains(CGPoint(x: 208, y: 12.4)))
        XCTAssertFalse(path.contains(CGPoint(x: 20, y: 12.4)))
    }
}
