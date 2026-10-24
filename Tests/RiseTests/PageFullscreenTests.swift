import AppKit
import XCTest
@testable import Rise

@MainActor final class PageFullscreenTests: XCTestCase {
    // The script itself, in a page, is checked on Chromium: Tests/Live/ChromiumMediaChecks.swift.
    func testNativeByDefaultAndTheShortcutSaysWhichInThePageBar() throws {
        let suite = "PageFullscreenTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("rise-fullscreen-\(UUID().uuidString)/session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        let bar = browser.navBar
        XCTAssertFalse(browser.pageFullscreen.isSimulated, "Native until switched")
        browser.toggleSimulatedFullscreen()
        XCTAssertTrue(browser.pageFullscreen.isSimulated)
        let simulated = try XCTUnwrap(bar.notice)
        XCTAssertEqual(simulated.text, "Simulated Full Screen Enabled")
        browser.toggleSimulatedFullscreen()
        let native = try XCTUnwrap(bar.notice)
        XCTAssertEqual(native.text, "Native Full Screen Enabled")
        XCTAssertFalse(native === simulated, "Switching back swaps the whole row")
        XCTAssertEqual(simulated.alphaValue, 0); XCTAssertEqual(native.alphaValue, 1); XCTAssertEqual(bar.text.alphaValue, 0)
        // Copying over it swaps it out the same way.
        browser.addTab().requestedURL = URL(string: "https://example.com"); browser.linkPasteboard = .withUniqueName()
        browser.update(); browser.copyURL()
        XCTAssertTrue(bar.isShowingCopied); XCTAssertEqual(native.alphaValue, 0)
        browser.linkPasteboard.releaseGlobally()
        browser.toggleSimulatedFullscreen()
        let item = browser.makeMoreSiteMenu().items.first { $0.title == "Simulated Full Screen" }
        XCTAssertEqual(item?.state, .on)
        browser.window?.close()
    }
}
