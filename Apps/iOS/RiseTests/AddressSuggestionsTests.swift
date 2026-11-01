import XCTest
import UIKit
@testable import RiseiOS

final class AddressSuggestionsTests: XCTestCase {
    @MainActor func testBlankPanelUpdatesHabitsDeduplicatesSitesAndKeepsThemAfterRelaunch() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseBlankPanel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = MobileAddressSuggestions(directory: folder)
        let old = URL(string: "https://old.example/")!, account = URL(string: "https://work.example/account")!
        let now = Date()
        for _ in 0..<100 { source.history.record(old, title: "Old habit", at: now.addingTimeInterval(-45*86400)) }
        for _ in 0..<8 { source.history.record(account, title: "Current account", at: now) }
        source.history.record(URL(string: "https://www.work.example/other")!, title: "Same site", at: now)
        let panel = SearchPanel(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        panel.source = source; panel.allowsRemoteSuggestions = false; panel.begin()
        defer { panel.end() }
        XCTAssertEqual(panel.candidates.first?.url, account)
        XCTAssertEqual(panel.resultRows.count, 2)
        XCTAssertEqual(panel.suggestions, ["Current account", "Old habit"])
        let newer = URL(string: "https://newer.example/")!
        for _ in 0..<12 { source.history.record(newer, title: "A new routine") }
        panel.refresh()
        XCTAssertEqual(panel.candidates.first?.url, newer)
        source.save(); panel.end()
        panel.source = MobileAddressSuggestions(directory: folder); panel.begin()
        XCTAssertEqual(panel.candidates.first?.url, newer)
        XCTAssertEqual(panel.resultRows.count, 3)
    }

    @MainActor func testAddressChoicesLearnOnOpenTabSwitchAndReturnButNotInPrivateOrSearches() throws {
        let checks = try AddressSuggestionsAudit.selectionLearningChecks()
        XCTAssertGreaterThanOrEqual(checks.count, 8)
        for (name, passed) in checks { XCTAssertTrue(passed, name) }
    }
    @MainActor func testNativeInputFaviconsLearningAndSiteSearch() async throws {
        let browser = AddressSuggestionsAudit.makeBrowser()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = browser; window.makeKeyAndVisible()
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseAddressTests-\(UUID())")
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: folder) }
        let checks = try await AddressSuggestionsAudit.exercise(browser, folder: folder)
        XCTAssertGreaterThan(checks.count, 25)
        XCTAssertTrue(checks.values.allSatisfy { $0 })
    }
}
