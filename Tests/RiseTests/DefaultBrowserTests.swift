import XCTest
@testable import Rise

final class DefaultBrowserTests: XCTestCase {
    /// Never asks for `set`, which would show macOS's own prompt.
    @MainActor func testTheBannerShowsUntilDismissedForGood() {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Rise.DefaultBrowserTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        defer {
            browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder)
        }
        func ask(_ action: String) -> Bool? {
            var shown: Bool?
            browser.handleDefaultBrowserRequest(["action": action]) { answer, _ in shown = (answer as? [String: Bool])?["shown"] }
            return shown
        }
        XCTAssertFalse(BrowserController.isDefaultBrowser, "The test runner isn't anyone's browser")
        XCTAssertEqual(ask("state"), true)
        XCTAssertEqual(ask("dismiss"), false)
        XCTAssertEqual(ask("state"), false)
        let again = BrowserController(sessionURL: folder.appendingPathComponent("again.json"), restore: false, preferences: preferences)
        defer { again.saveWork?.cancel(); again.window?.orderOut(nil) }
        XCTAssertFalse(again.showsDefaultBrowserBanner, "Dismissing lasts")
    }
}
