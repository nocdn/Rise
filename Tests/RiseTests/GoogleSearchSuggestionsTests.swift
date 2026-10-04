import XCTest
import AppKit
import RiseCore
@testable import Rise

private final class SearchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private let stateLock = NSLock()
    private var stopped = false
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
        DispatchQueue.global().asyncAfter(deadline: .now()+(query == "old query" ? 0.2 : 0.08)) { [self] in
            stateLock.lock(); let cancelled = stopped; stateLock.unlock()
            guard !cancelled else { return }
            let terms = [query, query+" beans", query+" cake", query+" recipe", query+" near me", query+" reviews", query+" online", query+" extra"]
            let bytes = try! JSONSerialization.data(withJSONObject: [query, terms])
            let response = HTTPURLResponse(url: request.url!, statusCode: query == "offline query" ? 503 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

final class GoogleSearchSuggestionsTests: XCTestCase {
    private func session() -> URLSession {
        SearchProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchProtocol.self]
        return URLSession(configuration: config)
    }
    @MainActor func testDebounceCachingURLExclusionAndCorrectQueryEncoding() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.08); defer { provider.cancel() }
        var delivered: [String] = []; provider.onLoad = { delivered.append($0) }
        XCTAssertTrue(provider.suggestions(for: "co").isEmpty)
        XCTAssertTrue(provider.suggestions(for: "coffee").isEmpty)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertEqual(delivered, ["coffee"]); XCTAssertEqual(SearchProtocol.snapshot().count, 1)
        XCTAssertEqual(provider.suggestions(for: "coffee").count, 6)
        let request = try XCTUnwrap(SearchProtocol.snapshot().first)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.url?.host, "www.google.com")
        _ = provider.suggestions(for: "cancelled query"); provider.cancel()
        for text in ["", "a", "https://example.com/private?token=secret", "localhost:3000", "calendar.google.com", "/private/file", "me@example.com"] {
            XCTAssertTrue(provider.suggestions(for: text).isEmpty)
        }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(SearchProtocol.snapshot().count, 1)
        XCTAssertEqual(provider.suggestions(for: "coffee").count, 6, "Reopening uses the bounded memory cache")
        XCTAssertEqual(SearchProtocol.snapshot().count, 1)
        let term = "résumé & café?"
        let components = try XCTUnwrap(URLComponents(url: GoogleSearchSuggestions.searchURL(for: term), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first?.value, term)
    }
    @MainActor func testNewerQueryAndCancellationCannotBeOverwrittenByOlderResponses() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005); defer { provider.cancel() }
        var delivered: [String] = []; provider.onLoad = { delivered.append($0) }
        _ = provider.suggestions(for: "old query")
        try await Task.sleep(for: .milliseconds(25))
        _ = provider.suggestions(for: "new query")
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(delivered, ["new query"])
        XCTAssertTrue(provider.suggestions(for: "new query").allSatisfy { $0.hasPrefix("new query") })
        _ = provider.suggestions(for: "closed query")
        try await Task.sleep(for: .milliseconds(20)); provider.cancel()
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(delivered, ["new query"])
    }
    func testJSONValidationDeduplicationAndUntrustedTextRemainPlainStrings() throws {
        let bytes = try JSONSerialization.data(withJSONObject: ["coffee", ["coffee", "coffee beans", "COFFEE BEANS", "", " coffee cake ", "<b>coffee</b>", "bad\nterm"]])
        XCTAssertEqual(GoogleSearchSuggestions.parse(bytes, query: "coffee"), ["coffee beans", "coffee cake", "<b>coffee</b>"])
        XCTAssertNil(GoogleSearchSuggestions.parse(bytes, query: "another query"))
        XCTAssertNil(GoogleSearchSuggestions.parse(Data("not JSON".utf8), query: "coffee"))
        XCTAssertNil(GoogleSearchSuggestions.parse(Data(repeating: 0, count: 128_001), query: "coffee"))
        XCTAssertFalse(GoogleSearchSuggestions.isSearchQuery(String(repeating: "a", count: 257)))
    }
    @MainActor func testLiveResultsPreserveInputCaretAndHighlightedHistoryAndSubmitGoogleSuggestion() async throws {
        _ = NSApplication.shared
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.02)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, searchSuggestions: provider)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        for index in 0..<8 { browser.browsingHistory.record(URL(string: "https://example.com/\(index)")!, title: "coffee document \(index)") }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText(" coffee ", replacementRange: editor.selectedRange())
        palette.selectResult(6)
        let highlighted = palette.suggestions[6].url, caret = editor.selectedRange()
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(palette.suggestions.count, 8)
        XCTAssertEqual(palette.suggestions[palette.selectedIndex].url, highlighted)
        XCTAssertEqual(editor.string, " coffee "); XCTAssertEqual(editor.selectedRange(), caret)
        XCTAssertEqual(browser.browsingHistory.entries.count, 8, "Fetching suggestions records no visits")
        let index = try XCTUnwrap(palette.suggestions.firstIndex { $0.title == "coffee beans" })
        var submitted: URL?
        palette.submit = { _, suggestion in submitted = suggestion?.url }
        palette.selectResult(index); editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submitted, GoogleSearchSuggestions.searchURL(for: "coffee beans"))
        editor.selectAll(nil); editor.insertText("offline query", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(palette.suggestions.count, 1, "Network failure leaves the direct search available")
        XCTAssertEqual(editor.string, "offline query")
        editor.selectAll(nil); editor.insertText("closed query", replacementRange: editor.selectedRange())
        browser.hidePalette()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(palette.isPresented)
        XCTAssertFalse(SearchProtocol.snapshot().contains { $0.url?.absoluteString.contains("closed%20query") == true })
    }
}
