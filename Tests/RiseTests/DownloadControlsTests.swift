import XCTest
import AppKit
@testable import Rise

// Real downloads, paused and resumed, are checked on Chromium: Tests/Live/ChromiumMediaChecks.swift.
final class DownloadControlsTests: XCTestCase {
    /// Deleting from disk takes the row at once and moves the file to the Trash behind it.
    @MainActor private func wait(until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done())
    }
    @MainActor func testCommandBackspaceTrashesSelectedFinishedFileWhileBackspaceOnlyClearsList() async throws {
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
        XCTAssertTrue(list.visible.isEmpty); XCTAssertTrue(controller.rows.isEmpty, "The row goes at once")
        try await wait { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path), "Command-Backspace must use recoverable trash deletion")
        let partial = folder.appendingPathComponent("unfinished.bin")
        try Data("partial".utf8).write(to: partial)
        id = list.begin(partial, progress: Progress(totalUnitCount: 100)); controller.focus(id)
        XCTAssertTrue(controller.view.performKeyEquivalent(with: key(.command)))
        XCTAssertEqual(list.visible.first?.record.id, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "Command-Backspace must not delete an in-progress file")
    }
    @MainActor func testShiftTurnsAFinishedRowsXIntoABinThatDeletesTheFile() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Rise-download-shift-\(UUID().uuidString).txt")
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent(file.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: trash) }
        let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
        let controller = DownloadsController(list: list); _ = controller.view
        list.onChange = { [weak controller] in controller?.reload() }
        try Data("bin".utf8).write(to: file)
        let id = list.begin(file, progress: nil); list.finish(id); controller.focus(id)
        func flags(_ modifiers: NSEvent.ModifierFlags) {
            controller.view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!)
        }
        let row = try XCTUnwrap(controller.rows.first), x = row.removeButton.image
        XCTAssertEqual(row.removeButton.hoverHint?.text, "Remove from List")
        XCTAssertEqual(row.previewButton.hoverHint?.text, "Quick Look")
        flags(.shift)
        XCTAssertFalse(row.removeButton.image === x, "Shift shows the bin")
        XCTAssertEqual(row.removeButton.hoverHint?.text, "Delete from disk")
        flags([])
        XCTAssertTrue(row.removeButton.image === x)
        XCTAssertEqual(row.removeButton.hoverHint?.text, "Remove from List")
        flags(.shift); row.removeButton.performClick(nil)
        XCTAssertTrue(controller.rows.isEmpty, "The row goes at once, as the X's does")
        try await wait { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path), "The bin moves the file to the Trash")
    }
    @MainActor func testAFileThatCantGoToTheBinComesBackWithARedMessageFromItsBin() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let locked = folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("kept.txt")
        try Data("kept".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
        let controller = DownloadsController(list: list)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = controller.view; window.orderFront(nil); defer { controller.errorPopover?.close(); window.orderOut(nil) }
        list.onChange = { [weak controller] in controller?.reload() }
        let id = list.begin(file, progress: nil); list.finish(id); controller.focus(id)
        try XCTUnwrap(controller.rows.first).performDeleteFromDisk()
        XCTAssertTrue(controller.rows.isEmpty, "The row goes at once")
        try await wait { controller.errorPopover?.isShown == true }
        let row = try XCTUnwrap(controller.rows.first, "It comes back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(row.removeButton.isHidden, "Its bin stays out for the message")
        let message = try XCTUnwrap(controller.errorPopover?.contentViewController?.view.subviews.first as? NSTextField)
        XCTAssertEqual(message.stringValue, "Couldn’t move it to the Bin. Rise isn’t allowed to move it.")
        XCTAssertEqual(message.textColor, DownloadsController.errorRed)
    }
    @MainActor func testContextMenusAndDeleteFromDiskRespectLiveAndFinishedStates() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = DownloadList(storeURL: folder.appendingPathComponent("downloads.json"))
        let file = folder.appendingPathComponent("Rise-download-menu-\(UUID().uuidString).pdf")
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").appendingPathComponent(file.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: trash) }
        try Data("test".utf8).write(to: file)
        let id = list.begin(file, progress: Progress(totalUnitCount: 100))
        let row = DownloadRow(item: list.items[0])
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        XCTAssertEqual(row.menu(for: event)?.items.map(\.title), ["Reveal in Finder", "Smart Rename"])
        list.deleteFromDisk(id); XCTAssertEqual(list.items.count, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        list.finish(id); row.update()
        let finished = try XCTUnwrap(row.menu(for: event)?.items)
        XCTAssertEqual(finished.prefix(3).map(\.title), ["Reveal in Finder", "Delete from disk", "Smart Rename"])
        // Share, after a divider, so the items without icons aren't indented beside its icon.
        XCTAssertTrue(finished[3].isSeparatorItem)
        XCTAssertTrue(finished[4].title.hasPrefix("Share"), "Share follows them: \(finished[4].title)")
        // AirDrop, right under Share, where the Mac can send the file with it.
        let airDrop = NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: [file]) == true
        XCTAssertEqual(finished.dropFirst(5).map(\.title), airDrop ? ["AirDrop"] : [])
        var revealed: URL?
        row.reveal = { revealed = $0 }
        let menu = try XCTUnwrap(row.menu(for: event)); menu.performActionForItem(at: 0)
        XCTAssertEqual(revealed, file)
        menu.performActionForItem(at: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Smart Rename is deliberately inert")
        list.deleteFromDisk(id)
        XCTAssertTrue(list.visible.isEmpty)
        try await wait { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
    }
}
