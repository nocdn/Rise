import XCTest
import UIKit
@testable import RiseiOS

final class BrowserRecoveryTests: XCTestCase {
    @MainActor func testRestoredPageFailureRetryRelaunchAndTabCards() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = BrowserViewController(startURL: nil); window.makeKeyAndVisible()
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseRecoveryTests-\(UUID())")
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: folder) }
        let checks = try await BrowserRecoveryAudit.exercise(in: window, folder: folder)
        XCTAssertGreaterThan(checks.count, 15)
        XCTAssertTrue(checks.values.allSatisfy { $0 })
    }
}
