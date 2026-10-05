import XCTest
import AppKit
import WebKit
import Network
@testable import Rise

/// A real, throttled HTTP attachment with range support exercises WebKit's
/// resume data and actual bytes on disk, rather than mocking the pause button.
private final class SlowDownloadServer {
    let listener: NWListener
    let size = 4 * 1024 * 1024
    private let queue = DispatchQueue(label: "Rise.DownloadControlsTests")
    private let lock = NSLock()
    private var offsets: [Int] = []
    var ranges: [Int] { lock.lock(); defer { lock.unlock() }; return offsets }
    var url: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/file.bin") } }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue); self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, _, _ in
            guard let self else { connection.cancel(); return }
            var buffer = data; if let chunk { buffer.append(chunk) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") else { self.receive(connection, data: buffer); return }
            let range = text.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("range: bytes=") }
            let offset = range.flatMap { Int($0.dropFirst("range: bytes=".count).split(separator: "-").first ?? "0") } ?? 0
            self.lock.lock(); self.offsets.append(offset); self.lock.unlock()
            let status = offset == 0 ? "200 OK" : "206 Partial Content"
            let contentRange = offset == 0 ? "" : "Content-Range: bytes \(offset)-\(self.size-1)/\(self.size)\r\n"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=test-file.bin\r\nContent-Length: \(self.size-offset)\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\nETag: \"rise-test-v1\"\r\nLast-Modified: Mon, 05 Oct 2026 10:00:00 GMT\r\n\(contentRange)Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                if error == nil { self?.send(connection, offset: offset) } else { connection.cancel() }
            })
        }
    }
    private func send(_ connection: NWConnection, offset: Int) {
        guard offset < size else { connection.cancel(); return }
        let count = min(16384, size-offset)
        connection.send(content: Data(repeating: 0x5a, count: count), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now()+0.02) { [weak self] in self?.send(connection, offset: offset+count) }
        })
    }
}

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
    @MainActor private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor private func begin(_ server: SlowDownloadServer, browser: BrowserController) async throws -> DownloadList.Item {
        try await waitUntil("HTTP server listening") { server.url != nil }
        let tab = browser.selectedTab ?? browser.addTab()
        tab.webView.loadHTMLString("<title>Download fixture</title><p>Download source</p>", baseURL: server.url!)
        try await waitUntil("Source document committed") { tab.webView.title == "Download fixture" && !tab.webView.isLoading }
        let download = await tab.webView.startDownload(using: URLRequest(url: server.url!))
        browser.registerDownload(download)
        try await waitUntil("An unfinished file must appear in the list") { !browser.downloads.visible.isEmpty }
        return try XCTUnwrap(browser.downloads.visible.first)
    }
    @MainActor func testActualDownloadPauseResumeCompletionAndPopoverUpdates() async throws {
        _ = NSApplication.shared
        let server = try SlowDownloadServer(); defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: folder) }
        let item = try await begin(server, browser: browser)
        let controller = DownloadsController(list: browser.downloads); _ = controller.view
        browser.downloads.onChange = { [weak controller] in controller?.reload() }
        try await waitUntil("Byte counts and transfer speed update") { item.receivedBytes > 0 && item.bytesPerSecond > 0 }
        let row = try XCTUnwrap(controller.rows.first)
        row.isHighlighted = false
        XCTAssertFalse(row.progressRing.isHidden); XCTAssertTrue(row.pauseButton.isHidden)
        XCTAssertTrue(row.previewButton.isHidden); XCTAssertTrue(row.removeButton.isHidden)
        row.isHighlighted = true
        XCTAssertFalse(row.pauseButton.isHidden); XCTAssertFalse(row.removeButton.isHidden)
        row.isHighlighted = false
        XCTAssertFalse(row.canPreview)
        browser.downloads.togglePause(item.record.id)
        let ringFill = try XCTUnwrap(row.progressRing.layer?.sublayers?.last as? CAShapeLayer)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(ringFill.animation(forKey: "pauseColor")?.duration, 0.16)
        }
        try await waitUntil("Pause has captured resume data") { item.state == .paused }
        let bytes = item.receivedBytes
        XCTAssertGreaterThan(bytes, 0); XCTAssertLessThan(bytes, Int64(server.size))
        XCTAssertEqual(item.bytesPerSecond, 0)
        XCTAssertEqual(row.pauseButton.toolTip, "Resume Download")
        XCTAssertFalse(row.pauseButton.isHidden); XCTAssertFalse(row.removeButton.isHidden, "Paused controls remain visible without a hover")
        row.progressRing.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(ringFill.strokeColor, NSColor.secondaryLabelColor.cgColor)
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(item.receivedBytes, bytes, "Paused transfers must stop receiving")
        XCTAssertEqual(browser.downloads.visible.first?.record.id, item.record.id)
        browser.downloads.togglePause(item.record.id)
        try await waitUntil("Resumed download hides controls away from hover") { item.state == .downloading }
        XCTAssertTrue(row.pauseButton.isHidden); XCTAssertTrue(row.removeButton.isHidden)
        row.progressRing.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(ringFill.strokeColor, NSColor.systemBlue.cgColor)
        }
        try await waitUntil("Resume finishes the same list entry") { item.isFinished }
        XCTAssertEqual(browser.downloads.items.count, 1)
        XCTAssertTrue(server.ranges.contains { $0 > 0 }, "WebKit resumes using HTTP Range")
        let data = try Data(contentsOf: item.record.url)
        XCTAssertEqual(data.count, server.size); XCTAssertTrue(data.allSatisfy { $0 == 0x5a })
        XCTAssertEqual(item.receivedBytes, Int64(server.size)); XCTAssertEqual(item.totalBytes, Int64(server.size))
        XCTAssertTrue(controller.rows.first === row, "Progress and completion preserve the row")
        XCTAssertTrue(row.progressRing.isHidden); XCTAssertTrue(row.pauseButton.isHidden)
        XCTAssertTrue(DownloadList(storeURL: folder.appendingPathComponent("downloads.json")).visible.first?.isFinished == true)
    }
    @MainActor func testCancellingDuringPauseRemovesOnlyTheActiveDownload() async throws {
        _ = NSApplication.shared
        let server = try SlowDownloadServer(); defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: folder) }
        let item = try await begin(server, browser: browser)
        try await waitUntil("Download receives bytes") { item.receivedBytes > 0 }
        browser.downloads.togglePause(item.record.id); browser.downloads.cancel(item.record.id)
        try await waitUntil("Cancellation removes the row even while pausing") { browser.downloads.visible.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.record.path))
        XCTAssertTrue(browser.downloads.pendingDestinations.isEmpty)
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
        XCTAssertEqual(row.menu(for: event)?.items.map(\.title), ["Reveal in Finder", "Delete from disk", "Smart Rename"])
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
