import XCTest
@testable import RiseCore

final class AddressSuggestionEngineTests: XCTestCase {
    func testLearnedPrefixesBeatPopularSitesAndCompleteOnlyTheHostUntilAPathIsTyped() throws {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        history.record(URL(string: "https://github.enterprise.example/docs/swift")!, title: "Internal docs")
        let first = try XCTUnwrap(AddressSuggestionEngine.suggestions(for: "git", history: history, tabs: []).first)
        XCTAssertEqual(first.completion, "github.enterprise.example")
        XCTAssertEqual(first.url?.absoluteString, "https://github.enterprise.example/")
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "github.enterprise.example/d", history: history, tabs: []).first?.completion,
                       "github.enterprise.example/docs/swift")
        XCTAssertNil(AddressSuggestionEngine.suggestions(for: "internal docs", history: history, tabs: []).first?.completion)
    }
    func testOpenTabsDeduplicateHistoryAndRequireExactQueryAndAnchor() {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let url = URL(string: "https://example.com/docs?q=one#intro")!
        history.record(url, title: "Old title")
        let tab = AddressSuggestionTab(id: UUID(), title: "Current docs", url: url)
        let values = AddressSuggestionEngine.suggestions(for: "current docs", history: history, tabs: [tab])
        XCTAssertEqual(values.filter { $0.tabID == tab.id }.count, 1)
        XCTAssertEqual(AddressSuggestionEngine.openTab(for: url, in: [tab])?.id, tab.id)
        XCTAssertNil(AddressSuggestionEngine.openTab(for: URL(string: "https://example.com/docs?q=two#intro")!, in: [tab]))
        XCTAssertNil(AddressSuggestionEngine.openTab(for: URL(string: "https://example.com/docs?q=one#other")!, in: [tab]))
        XCTAssertFalse(AddressSuggestionEngine.suggestions(for: url.absoluteString, history: history, tabs: [tab], currentURL: url,
            editingCurrentAddress: true).contains { $0.tabID == tab.id })
    }
    func testRemoteResultsKeepTypedActionAndOpenTabsAndDeduplicateDestinations() {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let tab = AddressSuggestionTab(id: UUID(), title: "Swift docs", url: URL(string: "https://example.com/swift")!)
        let local = AddressSuggestionEngine.suggestions(for: "swift", history: history, tabs: [tab], limit: 4)
        let mixed = AddressSuggestionEngine.merging(["swift", "swift concurrency", "swift concurrency", "swift language"], into: local, limit: 4)
        XCTAssertTrue(mixed.first?.isTypedAction == true)
        XCTAssertTrue(mixed.contains { $0.tabID == tab.id })
        XCTAssertEqual(Set(mixed.compactMap(\.url)).count, mixed.count)
        XCTAssertLessThanOrEqual(mixed.count, 4)
    }
    func testNewTabSuggestionsLearnFrequencyAndNeverExposeCredentials() {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let frequent = URL(string: "https://daily.example/")!, rare = URL(string: "https://rare.example/")!
        history.record(rare, title: "Rare")
        for _ in 0..<10 { history.record(frequent, title: "Daily") }
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "", history: history, tabs: []).first?.url, frequent)
        let secret = AddressSuggestionTab(id: UUID(), title: "Secret", url: URL(string: "https://user:password@example.com/")!)
        XCTAssertFalse(AddressSuggestionEngine.suggestions(for: "secret", history: history, tabs: [secret]).contains { $0.tabID == secret.id })
        XCTAssertTrue(AddressSuggestionEngine.suggestions(for: "", history: history, tabs: [], limit: 0).isEmpty)
        XCTAssertEqual(AddressResolver.resolve("e.g.")?.host, "www.google.com")
    }
    func testRemoteLiteralAddressesBecomeLinksWithFaviconsAndCanReuseAnOpenTab() throws {
        let tab = AddressSuggestionTab(id: UUID(), title: "Amazon", url: URL(string: "https://www.amazon.co.uk/")!)
        let values = AddressSuggestionEngine.merging(["amazon uk", "https://www.amazon.co.uk/"], into: [], tabs: [tab])
        let link = try XCTUnwrap(values.first { $0.symbol == "globe" })
        XCTAssertEqual(link.url, tab.url)
        XCTAssertEqual(link.tabID, tab.id)
        XCTAssertTrue(link.fetchFavicon)
        XCTAssertEqual(values.first?.symbol, "magnifyingglass")
        XCTAssertEqual(AddressSuggestionEngine.merging(["https://example.com", "https://EXAMPLE.com:443/"], into: []).count, 1)
    }
}
