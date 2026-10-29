import XCTest
import AppKit
import RiseCore
@testable import Rise

private final class SearchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private let stateLock = NSLock()
    private var stopped = false
    /// Searches only; connection warm-ups carry no text.
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.httpMethod != "HEAD" } }
    static func warmUps() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.httpMethod == "HEAD" } }
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
    @MainActor func testSlashCommandsCancelPendingRemoteSuggestionsAndRemovingSlashResumesThem() async throws {
        _ = NSApplication.shared
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, searchSuggestions: provider)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        _ = browser.addTab()
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("old query", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(30))
        editor.selectAll(nil); editor.insertText("/zoom", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(palette.isCommandMode)
        XCTAssertTrue(palette.suggestions.allSatisfy { $0.command != nil })
        XCTAssertFalse(SearchProtocol.snapshot().contains { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value?.hasPrefix("/") == true
        })
        editor.selectAll(nil); editor.insertText("coffee", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(palette.isCommandMode)
        XCTAssertTrue(palette.suggestions.allSatisfy { $0.command == nil })
        XCTAssertTrue(palette.suggestions.contains { $0.title == "coffee beans" })
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
    @MainActor func testTypingOnKeepsFittingResultsAndAnEarlierAnswerFillsInBeforeTheCurrentOne() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005); defer { provider.cancel() }
        var delivered: [(String, [String])] = []
        provider.onLoad = { delivered.append(($0, provider.suggestions(for: $0))) }
        _ = provider.suggestions(for: "cof")
        try await Task.sleep(for: .milliseconds(30))
        _ = provider.suggestions(for: "cof c")
        for _ in 0..<50 where delivered.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(SearchProtocol.snapshot().count, 2, "Typing on doesn't cancel the earlier request")
        XCTAssertEqual(delivered.first?.0, "cof c")
        XCTAssertEqual(delivered.first?.1, ["cof cake"], "The earlier answer shows what still fits until the current one arrives")
        XCTAssertEqual(delivered.last?.1.first, "cof c beans", "Then the current answer replaces it")
        let shown = provider.suggestions(for: "cof c")
        XCTAssertEqual(provider.suggestions(for: "cof c xyz"), shown, "The rows already showing stay until the new answer arrives")
    }
    @MainActor func testTheAddressBarKeepsItsRowsWhileGoogleAnswersAndOnlyShortensWhenNothingCameBack() async throws {
        _ = NSApplication.shared
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, searchSuggestions: provider)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        func type(_ text: String) { editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange()) }
        func titles() -> [String] { palette.suggestions.map(\.title) }
        type("coffee")
        for _ in 0..<50 where !titles().contains("coffee beans") { try await Task.sleep(for: .milliseconds(10)) }
        let rows = palette.suggestions.count, height = palette.frame.height
        XCTAssertGreaterThan(rows, 2)
        type("tea time")
        XCTAssertEqual(palette.suggestions.count, rows, "Nothing matches the new text yet, but the list keeps its rows")
        XCTAssertEqual(palette.frame.height, height)
        XCTAssertTrue(titles().contains("coffee beans"))
        for _ in 0..<50 where !titles().contains("tea time beans") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(palette.suggestions.count, rows, "The new answer replaces the rows in place")
        XCTAssertFalse(titles().contains("coffee beans"))
        type("offline query")
        XCTAssertEqual(palette.suggestions.count, rows)
        for _ in 0..<50 where palette.suggestions.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(titles(), ["offline query"], "With no answer coming, the held rows go")
    }
    @MainActor func testOpeningTheAddressBarWarmsTheConnectionWithoutAnyTypedText() async throws {
        _ = NSApplication.shared
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, searchSuggestions: provider)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        browser.showWindow(nil); browser.newTab(); browser.hidePalette(); browser.newTab()
        for _ in 0..<50 where SearchProtocol.warmUps().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let warmUps = SearchProtocol.warmUps()
        XCTAssertEqual(warmUps.count, 1, "Reopening right away doesn't warm again")
        XCTAssertEqual(warmUps.first?.url?.host, "www.google.com")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(warmUps.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "")
        XCTAssertFalse(try XCTUnwrap(warmUps.first).httpShouldHandleCookies)
        XCTAssertTrue(SearchProtocol.snapshot().isEmpty)
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
    @MainActor func testRemoteCompletionsRetainMatchingOpenTabsAndIdentifyExistingSearchPages() async throws {
        _ = NSApplication.shared
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, searchSuggestions: provider)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad(); $0.iconTask?.cancel() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        for index in 0..<3 {
            let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/\(index)")!; tab.rename("coffee document \(index)")
        }
        let search = browser.addTab(); search.requestedURL = GoogleSearchSuggestions.searchURL(for: "coffee beans"); search.rename("Saved search")
        browser.showWindow(nil); browser.newTab()
        let editor = try XCTUnwrap(browser.palette.input.currentEditor() as? NSTextView)
        editor.insertText("coffee", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(browser.palette.suggestions.count, 8)
        for tab in browser.tabs { XCTAssertTrue(browser.palette.suggestions.contains { $0.tabID == tab.id }) }
        XCTAssertEqual(browser.palette.suggestions.filter { $0.tabID == search.id }.count, 1)
        XCTAssertTrue(browser.palette.suggestions.contains { $0.title == "coffee cake" }, "Search completions still fill the remaining space")
    }
    @MainActor func testChoosingKagiCancelsGoogleAutocompleteAndDoesNotRequestNewGoogleTerms() async throws {
        _ = NSApplication.shared
        let session = session(); defer { session.invalidateAndCancel() }
        let provider = GoogleSearchSuggestions(session: session, delay: 0.005)
        let suite = "Rise.SearchSuggestionsTests.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: file, restore: false, preferences: preferences, searchSuggestions: provider)
        defer {
            browser.hidePalette(); browser.suggestionFavicons.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        browser.showWindow(nil); browser.newTab()
        let editor = try XCTUnwrap(browser.palette.input.currentEditor() as? NSTextView)
        editor.insertText("coffee", replacementRange: editor.selectedRange())
        // Wait for the request to start, so this tests cancellation of an in-flight
        // request rather than depending on the main run loop's timer scheduling.
        for _ in 0..<200 where SearchProtocol.snapshot().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(SearchProtocol.snapshot().count, 1)
        browser.selectSearchEngine(.kagi)
        XCTAssertEqual(browser.palette.suggestions.first?.url?.host, "kagi.com")
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(browser.palette.suggestions.count, 1, "Cancelled Google results cannot reappear")
        editor.selectAll(nil); editor.insertText("kagi query", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(SearchProtocol.snapshot().count, 1)
        XCTAssertEqual(browser.palette.suggestions.first?.title, "kagi query")
    }
}
