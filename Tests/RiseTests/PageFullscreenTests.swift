import AppKit
import XCTest
@testable import Rise

@MainActor final class PageFullscreenTests: XCTestCase {
    // The script itself, in a page, is checked on Chromium: Tests/Live/ChromiumMediaChecks.swift.
    func testPlaqueSplitsMessagesAtTheWordsTheyShare() {
        XCTAssertEqual(InfoPlaque.split("Native full screen enabled", "Simulated full screen enabled").rest, "full screen enabled")
        XCTAssertEqual(InfoPlaque.split("Native full screen enabled", "Simulated full screen enabled").new, "Simulated")
        XCTAssertEqual(InfoPlaque.split("Saved", "Copied").rest, "", "Nothing shared swaps the whole message")
        XCTAssertEqual(InfoPlaque.split("Link copied", "copied").new, "copied", "At least one word always swaps")
    }

    func testShortcutTogglesTheSettingAndShowsThePlaque() throws {
        let suite = "PageFullscreenTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("rise-fullscreen-\(UUID().uuidString)/session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        browser.toggleSimulatedFullscreen()
        XCTAssertTrue(browser.pageFullscreen.isSimulated)
        XCTAssertTrue(browser.infoPlaque.isPresented)
        XCTAssertEqual(browser.infoPlaque.text, "Simulated full screen enabled")
        let narrow = browser.infoPlaque.panelWidth
        browser.toggleSimulatedFullscreen()
        XCTAssertEqual(browser.infoPlaque.text, "Native full screen enabled")
        XCTAssertNotEqual(browser.infoPlaque.panelWidth, narrow, "The plaque fits its text")
        XCTAssertEqual(browser.infoPlaque.lead, "Native", "Toggling while it shows swaps only the word that changed")
        XCTAssertEqual(browser.infoPlaque.rest, "full screen enabled")
        browser.toggleSimulatedFullscreen()
        XCTAssertEqual(browser.infoPlaque.lead, "Simulated")
        XCTAssertEqual(browser.infoPlaque.text, "Simulated full screen enabled")
        browser.toggleSimulatedFullscreen()
        let item = browser.makeMoreSiteMenu().items.first { $0.title == "Simulated Full Screen" }
        XCTAssertEqual(item?.state, .off)
        browser.window?.close()
    }
}
