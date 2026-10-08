import XCTest
import AppKit
import Network
@testable import Rise

/// Serves a page and records each request's headers.
private final class HeaderRecordingServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.HeaderRecordingServer")
    private let lock = NSLock()
    private var recorded: [String] = []
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global()); self?.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    var url: URL? { listener.port.flatMap { URL(string: "http://[::1]:\($0.rawValue)/") } }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data; if let chunk { data.append(chunk) }
            let request = String(decoding: data, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, data: data) }; return
            }
            self.lock.lock(); self.recorded.append(request.lowercased()); let first = self.recorded.count == 1; self.lock.unlock()
            let content = "<!doctype html><title>Hard reload</title><p>Page</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: max-age=3600\r\nContent-Length: \(content.utf8.count)\r\nConnection: close\r\n\r\n\(content)"
            // Later loads answer slowly, so a test can watch them in progress.
            self.queue.asyncAfter(deadline: .now()+(first ? 0 : 0.5)) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

final class HardReloadTests: XCTestCase {
    @MainActor func testCommandShiftRReloadsTheSelectedTabWithoutTheCache() async throws {
        _ = NSApplication.shared
        let server = try HeaderRecordingServer(); defer { server.stop() }
        try await waitUntil("HTTP fixture listening") { server.url != nil }
        let suite = "Rise.HardReloadTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
        }
        let tab = browser.addTab()
        tab.load(server.url!)
        try await waitUntil("Page loads") { server.requests.count == 1 && !tab.isLoading }
        browser.hardReload()
        try await waitUntil("Hard reload requests the page again") { server.requests.count == 2 }
        // The tab's progress stays red for the whole load, then returns to the accent.
        XCTAssertTrue(tab.isLoading); XCTAssertTrue(tab.isHardReloading)
        try await waitUntil("Hard reload finishes") { !tab.isLoading }
        try await waitUntil("Finishing clears the hard reload") { !tab.isHardReloading }
        // WebKit marks a reload from origin with no-cache, not just max-age=0 revalidation.
        let hard = server.requests[1]
        XCTAssertTrue(hard.contains("cache-control: no-cache") || hard.contains("pragma: no-cache"), hard)
    }
    @MainActor private func waitUntil(_ message: String, timeout: TimeInterval = 15, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), message)
    }
}
