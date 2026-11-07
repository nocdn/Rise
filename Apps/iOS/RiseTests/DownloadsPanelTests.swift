#if DEBUG
import XCTest
import UIKit
@testable import RiseiOS

final class DownloadsPanelTests: XCTestCase {
    @MainActor func testAFinishedDownloadCanBeDraggedOut() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseDownloadsDrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Report.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)

        let finished = DownloadsPanel.Row(item: MobileDownloads.Item(url: file, state: .finished))
        let interaction = try XCTUnwrap(finished.interactions.compactMap { $0 as? UIDragInteraction }.first)
        XCTAssertTrue(interaction.isEnabled, "UIKit leaves dragging off on iPhone unless asked")
        let dragged = try XCTUnwrap(finished.makeDragItem())
        XCTAssertEqual(dragged.itemProvider.suggestedName, "Report.pdf")
        XCTAssertTrue(dragged.itemProvider.hasItemConformingToTypeIdentifier("com.adobe.pdf"), "Carries the file as what it is")
        XCTAssertNotNil(dragged.previewProvider, "With the file's thumbnail for its picture")

        XCTAssertNil(DownloadsPanel.Row(item: MobileDownloads.Item(url: file, state: .downloading)).makeDragItem(), "Not until it's finished")
        XCTAssertNil(DownloadsPanel.Row(item: MobileDownloads.Item(url: file, state: .failed)).makeDragItem())
        let missing = folder.appendingPathComponent("Gone.pdf")
        XCTAssertNil(DownloadsPanel.Row(item: MobileDownloads.Item(url: missing, state: .finished)).makeDragItem(), "Nor once its file has gone")
        finished.setSelecting(true, animated: false)
        XCTAssertNil(finished.makeDragItem(), "Multi Select's taps tick instead")
        finished.setSelecting(false, animated: false)
        XCTAssertNotNil(finished.makeDragItem())
    }

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
