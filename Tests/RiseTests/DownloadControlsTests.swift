import XCTest
import AppKit
@testable import Rise

// Real downloads, paused and resumed, are checked on Chromium: Tests/Live/ChromiumMediaChecks.swift.
final class DownloadControlsTests: XCTestCase {
    @MainActor func testCommandBackspaceTrashesSelectedFinishedFileWhileBackspaceOnlyClearsList() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Rise-download-shortcut-\(UUID().uuidString).txt")
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent(file.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: trash) }
        let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
        let controller = DownloadsController(list: list); _ = controller.view
        list.onChange = { [weak controller] in controller?.reload() }
        func key(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                            context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        }
        try Data("Keep with Backspace; trash with Command-Backspace".utf8).write(to: file)
        var id = list.begin(file, progress: nil); list.finish(id); controller.focus(id)
        XCTAssertTrue(controller.handle(key()))
        XCTAssertTrue(list.visible.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        id = list.begin(file, progress: nil); list.finish(id); controller.focus(id)
        XCTAssertTrue(controller.view.performKeyEquivalent(with: key(.command)))
        XCTAssertTrue(list.visible.isEmpty); XCTAssertTrue(controller.rows.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path), "Command-Backspace must use recoverable trash deletion")
        let partial = folder.appendingPathComponent("unfinished.bin")
        try Data("partial".utf8).write(to: partial)
        id = list.begin(partial, progress: Progress(totalUnitCount: 100)); controller.focus(id)
        XCTAssertTrue(controller.view.performKeyEquivalent(with: key(.command)))
        XCTAssertEqual(list.visible.first?.record.id, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "Command-Backspace must not delete an in-progress file")
    }
    @MainActor func testContextMenusAndDeleteFromDiskRespectLiveAndFinishedStates() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
        let file = folder.appendingPathComponent("document.pdf")
        try Data("test".utf8).write(to: file)
        let id = list.begin(file, progress: Progress(totalUnitCount: 100))
        let row = DownloadRow(item: list.items[0])
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        XCTAssertEqual(row.menu(for: event)?.items.map(\.title), ["Reveal in Finder", "Smart Rename"])
        XCTAssertNil(try list.deleteFromDisk(id)); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        list.finish(id); row.update()
        let finished = try XCTUnwrap(row.menu(for: event)?.items)
        XCTAssertEqual(finished.prefix(3).map(\.title), ["Reveal in Finder", "Delete from disk", "Smart Rename"])
        XCTAssertEqual(finished.count, 4); XCTAssertTrue(finished.last?.title.hasPrefix("Share") == true, "Share comes last: \(finished.last?.title ?? "")")
        var revealed: URL?
        row.reveal = { revealed = $0 }
        let menu = try XCTUnwrap(row.menu(for: event)); menu.performActionForItem(at: 0)
        XCTAssertEqual(revealed, file)
        menu.performActionForItem(at: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Smart Rename is deliberately inert")
        let trashed = try list.deleteFromDisk(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertTrue(list.visible.isEmpty)
        if let trashed { XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path)); try? FileManager.default.removeItem(at: trashed) }
    }
}
