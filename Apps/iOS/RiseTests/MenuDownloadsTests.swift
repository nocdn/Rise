#if DEBUG
import XCTest
import UIKit
@testable import RiseiOS

final class MenuDownloadsTests: XCTestCase {
    @MainActor func testCombinedDownloadProgressAndSwitcherHistoryMenu() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let browser = InteractionAudit.makeBrowser()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        browser.view.layoutIfNeeded()
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseMenuDownloadsTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: folder) }
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(450))
        _ = try await MenuDownloadsAudit.exercise(browser, folder: folder)
    }
}
#endif
