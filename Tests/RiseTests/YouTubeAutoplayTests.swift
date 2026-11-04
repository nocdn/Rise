import XCTest
@testable import Rise

final class YouTubeAutoplayTests: XCTestCase {
    @MainActor func testVideosWaitByDefaultAndTheSettingIsKept() throws {
        let suite = "Rise.YouTubeAutoplayTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        func row() -> [String: Any]? { browser.riseSettingRows("tabs").first { $0["key"] as? String == "youTubeAutoplay" } }
        XCTAssertEqual(row()?["label"] as? String, "Autoplay YouTube videos")
        XCTAssertEqual(row()?["value"] as? Bool, false, "Off unless turned on")
        XCTAssertFalse(browser.youTubeAutoplay.isEnabled)

        browser.setRiseSetting("youTubeAutoplay", true)
        XCTAssertEqual(row()?["value"] as? Bool, true)
        XCTAssertTrue(YouTubeAutoplay(preferences: defaults).isEnabled, "Kept for the next launch")
        browser.setRiseSetting("youTubeAutoplay", false)
        XCTAssertFalse(YouTubeAutoplay(preferences: defaults).isEnabled)
    }

    @MainActor func testTheScriptCarriesTheSettingAndHoldsOnlyYouTubesPlayers() {
        let held = YouTubeAutoplay.script(allowed: false), allowed = YouTubeAutoplay.script(allowed: true)
        XCTAssertTrue(held.hasPrefix(YouTubeAutoplay.marker), "Found again when the setting swaps it")
        XCTAssertTrue(held.contains("let allowed = false,") && allowed.contains("let allowed = true,"))
        XCTAssertFalse(held.contains("__RISE_ALLOWED__"))
        XCTAssertTrue(held.contains("'#movie_player, #shorts-player'"), "Hover previews play in #inline-preview-player")
        XCTAssertTrue(held.contains("'NotAllowedError'"), "As Chrome turns down autoplay, so YouTube shows its play button")
    }
}
