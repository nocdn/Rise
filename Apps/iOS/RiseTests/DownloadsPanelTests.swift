#if DEBUG
import XCTest
import UIKit
@testable import RiseiOS

final class DownloadsPanelTests: XCTestCase {
    @MainActor func testSelectionTransitionsAndBothSheetDetents() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let browser = BrowserViewController(startURL: nil)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        browser.view.layoutIfNeeded()
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseDownloadsPanelTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: folder) }
        _ = try await DownloadsPanelAudit.exercise(browser,folder: folder)
    }
}
#endif
