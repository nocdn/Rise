import XCTest
import AppKit
@testable import Rise

/// The downloads list: five rows tall, five and a half with more, and its edges dissolving where
/// more rows lie past them, coming in as it scrolls, as the sidebar's do.
final class DownloadsListHeightTests: XCTestCase {
    @MainActor func testMoreThanFiveShowAHalfRowMoreAndFadeAsTheyScroll() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
        let controller = DownloadsController(list: list); _ = controller.view
        list.onChange = { [weak controller] in controller?.reload() }
        func add(_ count: Int) {
            for _ in 0..<count {
                let file = folder.appendingPathComponent("\(UUID().uuidString).txt")
                FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
                list.finish(list.begin(file, progress: nil))
            }
        }
        let row = DownloadRow.height, inset = DownloadsController.inset
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        add(5)
        XCTAssertEqual(controller.preferredContentSize.height, 5*row+2*inset, "Five fit exactly")
        XCTAssertNil(scroll.layer?.mask, "A list that doesn't scroll doesn't fade")
        add(2)
        XCTAssertEqual(controller.preferredContentSize.height, 5.5*row+2*inset, "More show half a row more")
        let mask = try XCTUnwrap(scroll.layer?.mask as? CAGradientLayer, "At the top, the bottom fades")
        func alphas() -> (top: CGFloat, bottom: CGFloat) {
            let colors = (mask.colors as? [CGColor]) ?? []
            return (colors.first?.alpha ?? -1, colors.last?.alpha ?? -1)
        }
        XCTAssertEqual(alphas().top, 1, accuracy: 0.001, "Nothing above, no fade at the top")
        XCTAssertLessThan(alphas().bottom, 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 10))
        XCTAssertGreaterThan(alphas().top, 0.85, "The top's fade comes in gradually, not at once")
        XCTAssertLessThan(alphas().top, 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 7*row-scroll.contentView.bounds.height))
        XCTAssertEqual(alphas().bottom, 1, accuracy: 0.001, "At the end, no fade at the bottom")
        XCTAssertLessThan(alphas().top, 0.5)
    }
}
