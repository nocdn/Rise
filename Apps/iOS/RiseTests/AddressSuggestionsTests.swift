import XCTest
import UIKit
@testable import RiseiOS

final class AddressSuggestionsTests: XCTestCase {
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
