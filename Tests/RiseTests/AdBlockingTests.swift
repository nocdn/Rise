import XCTest
import AppKit
import WebKit
import Network
@testable import Rise

private final class BlockingHTTPServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.BlockingHTTPServer")
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global()); self?.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    var url: URL? { listener.port.flatMap { URL(string: "http://[::1]:\($0.rawValue)/") } }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data; if let chunk { data.append(chunk) }
            let request = String(decoding: data, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, data: data) }; return
            }
            let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
            self.lock.lock(); self.counts[path, default: 0] += 1; self.lock.unlock()
            let script = path.hasSuffix(".js")
            let body = script ? (path == "/ads.js" ? "window.adScriptLoaded = true" : "window.normalScriptLoaded = true") : """
            <!doctype html><title>Blocking fixture</title>
            <script src='/ads.js'></script><script src='/normal.js'></script>
            <div class='textads' id='static-ad' style='height:80px'>Advertising</div>
            <p id='content'>Normal content stays visible</p>
            <iframe src='/frame'></iframe>
            """
            let frameBody = "<!doctype html><script src='/ads.js'></script><div class='textads' style='height:40px'>Frame ad</div>"
            let content = path == "/frame" ? frameBody : body
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(script ? "application/javascript" : "text/html")\r\nCache-Control: no-store\r\nContent-Length: \(content.utf8.count)\r\nConnection: close\r\n\r\n\(content)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
final class AdBlockingTests: XCTestCase {
    @MainActor func testStoppingWhileRulesPrepareDoesNotRestartNavigation() async throws {
        _ = NSApplication.shared
        let server = try BlockingHTTPServer(); defer { server.stop() }
        try await waitUntil("HTTP fixture listening") { server.url != nil }
        let suite = "Rise.StopBlockingTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
        }
        let tab = browser.addTab()
        tab.prepareForLoad = { _ in try await Task.sleep(for: .milliseconds(300)) }
        tab.load(server.url!)
        XCTAssertTrue(tab.isLoading)
        browser.reload() // The toolbar's reload action is Stop during preparation.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(server.count("/"), 0)
        XCTAssertFalse(tab.isLoading)
        browser.reload()
        try await waitUntil("Reload after Stop starts a fresh navigation") { server.count("/") == 1 && !tab.isLoading }
    }
    @MainActor private func waitUntil(_ message: String, timeout: TimeInterval = 15, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor func testBundledRulesCompileWithWebKitAndBlockRealRequestsBeforeFirstLoad() async throws {
        _ = NSApplication.shared
        let started = Date()
        let compiled = try await AdBlockRules.compilation.value
        XCTAssertEqual(compiled.count, 7)
        print("Rise: native blocking rules ready in \(Date().timeIntervalSince(started)) seconds")
        let server = try BlockingHTTPServer(); defer { server.stop() }
        try await waitUntil("HTTP fixture listening") { server.url != nil }
        let suite = "Rise.AdBlockingTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(browser.adBlocker.enabled)
        let content = SiteControlsController(browser: browser); _ = content.view
        let item = try XCTUnwrap(content.rows["Block Ads & Trackers"])
        XCTAssertEqual(item.state, .on)
        let tab = browser.addTab(url: server.url!)
        try await waitUntil("Fixture loaded") { tab.webView.title == "Blocking fixture" && !tab.webView.isLoading }
        let check = """
        (() => {
          const dynamic = document.createElement('div'); dynamic.className = 'textads'; dynamic.style.height = '80px'; document.body.append(dynamic);
          return { normal: !!window.normalScriptLoaded, ad: !!window.adScriptLoaded,
            staticHeight: document.querySelector('#static-ad').offsetHeight, dynamicHeight: dynamic.offsetHeight,
            contentHeight: document.querySelector('#content').offsetHeight,
            framedAd: !!document.querySelector('iframe').contentWindow.adScriptLoaded };
        })()
        """
        let result = try await tab.webView.evaluateJavaScript(check) as? [String: Any]
        XCTAssertEqual(result?["normal"] as? Bool, true)
        XCTAssertEqual(result?["ad"] as? Bool, false)
        XCTAssertEqual(result?["staticHeight"] as? Int, 0)
        XCTAssertEqual(result?["dynamicHeight"] as? Int, 0)
        XCTAssertGreaterThan(result?["contentHeight"] as? Int ?? 0, 0)
        XCTAssertEqual(result?["framedAd"] as? Bool, false)
        XCTAssertEqual(server.count("/ads.js"), 0, "Blocked scripts must never reach the server")
        let initialLoads = server.count("/")
        item.performClick(nil)
        try await waitUntil("Disabling reloads the current page") { !browser.adBlocker.enabled && server.count("/") > initialLoads && !tab.webView.isLoading }
        XCTAssertGreaterThan(server.count("/ads.js"), 0)
        let unblocked = try await tab.webView.evaluateJavaScript(check) as? [String: Any]
        XCTAssertEqual(unblocked?["ad"] as? Bool, true)
        XCTAssertEqual(unblocked?["staticHeight"] as? Int, 80)
        XCTAssertEqual(unblocked?["dynamicHeight"] as? Int, 80)
        XCTAssertFalse(AdBlocker(preferences: defaults).enabled, "The preference must persist")
        let allowedAds = server.count("/ads.js"), beforeEnable = server.count("/")
        let offContent = SiteControlsController(browser: browser); _ = offContent.view
        let offItem = try XCTUnwrap(offContent.rows["Block Ads & Trackers"])
        XCTAssertEqual(offItem.state, .off); offItem.performClick(nil)
        try await waitUntil("Enabling reloads the current page") { browser.adBlocker.enabled && server.count("/") > beforeEnable && !tab.webView.isLoading }
        XCTAssertEqual(server.count("/ads.js"), allowedAds)
        let blockedAgain = try await tab.webView.evaluateJavaScript("!!window.adScriptLoaded") as? Bool
        XCTAssertEqual(blockedAgain, false)
        // Two immediate menu clicks must reverse the setting, even before either
        // async rule installation has yielded. Only the final policy may reload.
        let beforeRapidToggle = server.count("/")
        browser.toggleAdBlocking(); browser.toggleAdBlocking()
        XCTAssertTrue(browser.adBlocker.enabled)
        try await waitUntil("Rapid toggles settle and reload with blocking enabled") {
            server.count("/") > beforeRapidToggle && !tab.webView.isLoading
        }
        XCTAssertEqual(server.count("/ads.js"), allowedAds)
        XCTAssertTrue(AdBlocker(preferences: defaults).enabled)
    }
}
