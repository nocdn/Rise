import XCTest
@testable import Rise

final class ContextMenuVideoSourceTests: XCTestCase {
    func testChoosesBestCompleteVideoInsteadOfPlaylist() {
        let variants: [[String: Any]] = [
            ["src": "https://video.twimg.com/master.m3u8", "type": "application/x-mpegURL", "bitrate": 999999],
            ["src": "https://video.twimg.com/low.mp4", "type": "video/mp4", "bitrate": 256000],
            ["src": "https://video.twimg.com/high.mp4?tag=29", "type": "video/mp4", "bitrate": 832000]
        ]
        XCTAssertEqual(ContextMenuVideoSource.preferredVariant(variants)?.absoluteString, "https://video.twimg.com/high.mp4?tag=29")
    }

    func testRejectsUntrustedOrNonFileVariants() {
        for address in ["file:///tmp/video.mp4", "https://video.twimg.com.evil.test/video.mp4", "https://evil.test/video.mp4",
                        "http://video.twimg.com/video.mp4", "https://user:pass@video.twimg.com/video.mp4",
                        "https://video.twimg.com:444/video.mp4", "https://video.twimg.com/master.m3u8", "blob:https://x.com/video"] {
            XCTAssertNil(ContextMenuVideoSource.preferredVariant([["src": address, "type": "video/mp4", "bitrate": 1000]]), address)
        }
        XCTAssertNil(ContextMenuVideoSource.preferredVariant([["src": "https://video.twimg.com/video.mp4", "type": "text/html"]]))
        XCTAssertNil(ContextMenuVideoSource.preferredVariant([]))
    }

    func testMissingOrInvalidBitratesDoNotOutrankRealQuality() {
        let variants: [[String: Any]] = [
            ["src": "https://video.twimg.com/unknown.mp4", "type": "video/mp4"],
            ["src": "https://video.twimg.com/infinite.mp4", "type": "video/mp4", "bitrate": Double.infinity],
            ["src": "https://video.twimg.com/good.mp4", "type": "video/mp4", "bitrate": 256000]
        ]
        XCTAssertEqual(ContextMenuVideoSource.preferredVariant(variants)?.lastPathComponent, "good.mp4")
    }
}
