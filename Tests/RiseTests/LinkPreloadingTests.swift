import XCTest
import AppKit
import WebKit
import Network
@testable import Rise

// Real HTTP responses let the test verify WebKit cache reuse, not just a mocked
// hover callback. A fresh loopback port also isolates every run's cache entries.
private final class PreloadTestServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.PreloadTestServer")
    private let lock = NSLock()
    private var requests: [String: [String]] = [:]
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    var baseURL: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/") } }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests[path]?.count ?? 0 }
    func headers(_ path: String) -> String { lock.lock(); defer { lock.unlock() }; return requests[path]?.first ?? "" }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = data; if let chunk { buffer.append(chunk) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, data: buffer) }
                return
            }
            let path = text.components(separatedBy: " ").dropFirst().first ?? "/"
            self.lock.lock(); self.requests[path, default: []].append(text); self.lock.unlock()
            let body: String
            if path == "/" {
                body = """
                <!doctype html><title>Hover source</title>
                <a id="warm" href="/warm"><span>Warm target</span></a>
                <a id="short" href="/short">Short hover</a>
                <a id="disabled" href="/disabled">Disabled</a>
                <a id="download" href="/download" download>Download</a>
                <a id="anchor" href="#section">Anchor</a>
                <a id="cold" href="/cold">Uncacheable</a>
                <a id="failed" href="/failed">Failure</a>
                <iframe src="/frame"></iframe>
                """
            } else if path == "/frame" {
                body = "<!doctype html><a id='framed' href='/framed'>Framed link</a>"
            } else if path == "/warm" {
                body = "<!doctype html><title>Warm target</title><link rel='stylesheet' href='/style.css'><p>Cached content</p><script>fetch('/script-ran')</script>"
            } else { body = path == "/style.css" ? "body { color: blue; }" : "<!doctype html><title>Other</title>" }
            let mime = path == "/style.css" ? "text/css" : "text/html"
            let status = path == "/failed" ? "500 Internal Server Error" : "200 OK"
            let cache = path == "/cold" ? "no-store" : "public, max-age=3600"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nCache-Control: \(cache)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

final class LinkPreloadingTests: XCTestCase {
    @MainActor private func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), description)
    }
    @MainActor private func evaluate(_ script: String, in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(script)
    }
    @MainActor func testHoverDelayCancellationToggleFramesAndActualCacheReuse() async throws {
        _ = NSApplication.shared
        let server = try PreloadTestServer(); defer { server.stop() }
        try await waitUntil("HTTP fixture is listening") { server.baseURL != nil }
        let suite = "Rise.PreloadTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: defaults)
        defer {
            browser.linkPreloader.cancelAll(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: session.deletingLastPathComponent())
        }
        let tab = browser.addTab(url: server.baseURL!)
        try await waitUntil("Source page loaded") { tab.webView.title == "Hover source" && !tab.webView.isLoading }
        let hover = { (id: String) in "document.getElementById('\(id)').dispatchEvent(new PointerEvent('pointerover', {bubbles: true, pointerType: 'mouse'}))" }
        XCTAssertFalse(browser.linkPreloader.enabled)
        try await evaluate(hover("disabled"), in: tab.webView)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertEqual(server.count("/disabled"), 0)
        XCTAssertEqual(browser.linkStatus.url?.path, "/disabled", "The destination appears even when preloading is disabled")
        XCTAssertFalse(browser.linkStatus.isHidden)
        let content = SiteControlsController(browser: browser); _ = content.view
        let menuEntry = try XCTUnwrap(content.rows["Preload Links"])
        XCTAssertEqual(menuEntry.state, .off)
        menuEntry.performClick(nil)
        XCTAssertTrue(browser.linkPreloader.enabled)
        let updatedContent = SiteControlsController(browser: browser); _ = updatedContent.view
        XCTAssertEqual(updatedContent.rows["Preload Links"]?.state, .on)
        XCTAssertTrue(LinkPreloader(preferences: defaults).enabled)

        try await evaluate(hover("short"), in: tab.webView)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(server.count("/short"), 0)
        try await evaluate("document.getElementById('short').dispatchEvent(new PointerEvent('pointerout', {bubbles:true}))", in: tab.webView)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(server.count("/short"), 0)
        XCTAssertTrue(browser.linkStatus.isHidden)
        try await evaluate(hover("download"), in: tab.webView)
        try await Task.sleep(for: .milliseconds(200))
        try await evaluate(hover("anchor"), in: tab.webView)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.count("/download"), 0)
        XCTAssertEqual(server.count("/"), 1)

        try await evaluate(hover("warm"), in: tab.webView)
        try await waitUntil("WebKit preloads the target and stylesheet") {
            server.count("/warm") == 1 && server.count("/style.css") == 1 && browser.linkPreloader.activeLoadCount == 0
        }
        XCTAssertEqual(server.count("/script-ran"), 0, "Background page must not execute its scripts")
        XCTAssertTrue(server.headers("/warm").lowercased().contains("purpose: prefetch"))
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(tab.webView.url, server.baseURL)
        XCTAssertTrue(browser.linkStatus.ready)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertTrue(browser.linkStatus.isShimmering) }

        try await evaluate(hover("cold"), in: tab.webView)
        try await waitUntil("Uncacheable response completed") { server.count("/cold") == 1 && browser.linkPreloader.activeLoadCount == 0 }
        XCTAssertTrue(browser.linkStatus.ready, "A successful preload signals completion even when the response needs revalidation")
        XCTAssertFalse(browser.linkPreloader.isReady(server.baseURL!.appendingPathComponent("cold")))
        XCTAssertTrue(browser.linkPreloader.isComplete(server.baseURL!.appendingPathComponent("cold")))
        try await evaluate(hover("failed"), in: tab.webView)
        try await waitUntil("Failed response discarded") { server.count("/failed") == 1 && browser.linkPreloader.activeLoadCount == 0 }
        XCTAssertFalse(browser.linkStatus.ready)

        // Enabling after the iframe has loaded must apply there too.
        try await evaluate("document.querySelector('iframe').contentDocument.getElementById('framed').dispatchEvent(new PointerEvent('pointerover', {bubbles:true,pointerType:'mouse'}))", in: tab.webView)
        try await waitUntil("Already-loaded iframe preloads its link") { server.count("/framed") == 1 }
        browser.linkPreloader.setEnabled(false)
        try await evaluate(hover("disabled"), in: tab.webView)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertEqual(server.count("/disabled"), 0)
        XCTAssertEqual(browser.linkPreloader.activeLoadCount, 0)

        try await evaluate("document.getElementById('warm').click()", in: tab.webView)
        try await waitUntil("Click navigates and executes scripts normally") {
            tab.webView.title == "Warm target" && !tab.webView.isLoading && server.count("/script-ran") == 1
        }
        XCTAssertEqual(server.count("/warm"), 1, "Navigation should reuse the prefetched HTTP response")
        XCTAssertEqual(server.count("/style.css"), 1)
        XCTAssertTrue(tab.webView.canGoBack)
        browser.goBack()
        try await waitUntil("Back returns to the original document") { tab.webView.title == "Hover source" && !tab.webView.isLoading }
    }
    func testEligibilityRejectsSpecialSchemesAndSameDocumentLinks() {
        let source = URL(string: "https://example.com/page")!
        for value in ["https://example.com/page#part", "mailto:test@example.com", "file:///tmp/page", "javascript:alert(1)", "https://user:secret@example.com/other"] {
            XCTAssertFalse(LinkPreloader.isEligible(URL(string: value)!, from: source))
        }
        XCTAssertTrue(LinkPreloader.isEligible(URL(string: "https://other.example/page")!, from: source))
    }
    @MainActor func testPopupConfigurationsCanShareTheHoverController() {
        _ = NSApplication.shared
        let suite = "Rise.PreloadTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preloader = LinkPreloader(preferences: defaults)
        let configuration = WKWebViewConfiguration()
        let first = WKWebView(frame: .zero, configuration: configuration)
        let popup = WKWebView(frame: .zero, configuration: configuration)
        preloader.install(on: first); preloader.install(on: popup); preloader.install(on: first)
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1)
    }
}
