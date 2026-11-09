import UIKit
import XCTest
@testable import RiseiOS

final class PageConnectionTests: XCTestCase {
    @MainActor func testHTTPAddressAndSharedToolbarCueAcrossNavigationAndPrivateTabs() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = BrowserViewController(startURL: nil); window.makeKeyAndVisible()
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { window.isHidden = true; previous?.makeKey(); try? FileManager.default.removeItem(at: folder) }
        try await PageConnectionAudit.exercise(in: window, folder: folder)
    }
}
