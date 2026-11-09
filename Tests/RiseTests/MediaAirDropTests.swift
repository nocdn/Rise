import XCTest
import AppKit
@testable import Rise

final class MediaAirDropTests: XCTestCase {
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testEachFileKeepsItsNameInAFolderOfItsOwn() throws {
        let folder = try temporary()
        let first = MediaAirDrop.newFile(named: "photo.jpg", in: folder), second = MediaAirDrop.newFile(named: "photo.jpg", in: folder)
        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertEqual(MediaAirDrop.newFile(named: "../../escape.png", in: folder).deletingLastPathComponent().deletingLastPathComponent(), first.deletingLastPathComponent().deletingLastPathComponent(), "A name can't leave its folder")
        XCTAssertEqual(MediaAirDrop.newFile(named: "", in: folder).lastPathComponent, "download")
    }

    func testLeftoversStayUntilTheyreOld() throws {
        let folder = try temporary()
        let file = MediaAirDrop.newFile(named: "clip.mp4", in: folder)
        try Data("video".utf8).write(to: file)
        MediaAirDrop.clearLeftovers(olderThan: 3600, in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "It may still be sending")
        MediaAirDrop.clearLeftovers(olderThan: 3600, now: Date().addingTimeInterval(7200), in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testADownloadThatNeverBeginsFailsAndCancellingEndsItOnce() async throws {
        var outcomes: [MediaAirDrop.Outcome] = []
        let late = MediaAirDrop(timeout: 0.01) { outcomes.append($0) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(outcomes, [.failed])
        late.cancel()
        XCTAssertEqual(outcomes, [.failed], "It's already over")

        outcomes = []
        let cancelled = MediaAirDrop(timeout: 60) { outcomes.append($0) }
        cancelled.cancel(); cancelled.cancel()
        XCTAssertEqual(outcomes, [.cancelled])
    }

    @MainActor func testTheMenuItemHasAirDropsIconShowing() {
        let item = AirDropMenuItem.item(title: "AirDrop Image") {}
        XCTAssertEqual(item.title, "AirDrop Image")
        XCTAssertTrue(item.image === AirDropMenuItem.icon)
        #if compiler(>=6.4)
        if #available(macOS 27, *) { XCTAssertEqual(item.preferredImageVisibility, .visible) }
        #endif
    }
}
