import XCTest
@testable import RiseCore

final class StartPageSuggestionsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func entry(_ address: String, visits: Int = 1, daysAgo: Double = 0, title: String = "Page") -> HistoryEntry {
        HistoryEntry(url: BrowsingHistory.key(URL(string: address))!, title: title, visits: visits,
                     lastVisited: now.addingTimeInterval(-daysAgo*86400))
    }
    func history(_ entries: [HistoryEntry] = []) throws -> BrowsingHistory {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseStartSuggestions-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        try JSONEncoder().encode(entries).write(to: file)
        return BrowsingHistory(storageURL: file)
    }
    func suggestions(_ history: BrowsingHistory, tabs: [AddressSuggestionTab] = [], limit: Int = 12, at date: Date? = nil) -> [AddressCandidate] {
        AddressSuggestionEngine.suggestions(for: "", history: history, tabs: tabs, limit: limit, at: date ?? now)
    }

    func testOldLifetimeTotalsCannotPinPagesAboveCurrentHabitsForever() throws {
        let old = entry("https://old.example/", visits: 5000, daysAgo: 45)
        let frequent = entry("https://daily.example/account", visits: 20, daysAgo: 1)
        let recent = entry("https://recent.example/article", visits: 2, daysAgo: 1.0/24)
        let history = try history([old, frequent, recent])
        XCTAssertEqual(suggestions(history).compactMap { $0.url?.absoluteString }, [frequent.url, recent.url, old.url])
        XCTAssertEqual(history.entries.first { $0.url == old.url }?.visits, 5000, "Ranking never resets saved learning")
        history.record(URL(string: old.url)!, title: "Used again", at: now)
        XCTAssertEqual(suggestions(history).first?.url?.absoluteString, old.url, "Returning to an old favourite makes it useful again")
    }

    func testDiversityKeepsTheBestRealPageAndGroupsSchemeAndWWWVariants() throws {
        let account = entry("https://www.example.com/account", visits: 20)
        let history = try history([account, entry("https://example.com/", visits: 3), entry("http://example.com/old", visits: 10, daysAgo: 10),
                                   entry("https://docs.example.com/guide", visits: 2), entry("https://example.com:8443/", visits: 2),
                                   entry("https://other.example/", visits: 2)])
        let values = suggestions(history)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values.first?.url?.absoluteString, account.url)
        XCTAssertEqual(Set(values.compactMap { $0.url.flatMap(BrowsingHistory.suggestionSite) }).count, values.count)
        XCTAssertTrue(values.contains { $0.url?.host == "docs.example.com" })
        XCTAssertTrue(values.contains { $0.url?.port == 8443 })
    }

    func testARecentlyChosenOpenTabRefreshesItsShortcutWithoutInventingVisits() throws {
        let account = entry("https://account.example/account", visits: 5, daysAgo: 30)
        let history = try history([account, entry("https://other.example/", visits: 2, daysAgo: 1)])
        XCTAssertNotEqual(suggestions(history).first?.url?.absoluteString, account.url)
        history.recordTyped(URL(string: account.url)!, at: now)
        let tab = AddressSuggestionTab(id: UUID(), title: "Your account", url: URL(string: account.url))
        XCTAssertEqual(suggestions(history, tabs: [tab]).first?.url?.absoluteString, account.url)
        XCTAssertEqual(suggestions(history, tabs: [tab]).first?.tabID, tab.id)
        XCTAssertEqual(suggestions(history, tabs: [tab]).first?.title, "Your account")
        XCTAssertEqual(history.entries.first { $0.url == account.url }?.visits, 5)
    }

    func testAuthenticationHandoffsAndSearchesDoNotBecomeBlankPanelShortcuts() throws {
        let addresses = ["https://example.com/login", "https://signin.example.com/enter-email", "https://example.com/oauth/callback?code=secret",
                         "https://example.com/?access_token=secret", "https://www.google.com/search?q=old+search",
                         "https://www.google.co.uk/?q=old+search", "https://kagi.com/search?q=old+search", "https://shop.example/search?q=old+search"]
        let real = entry("https://example.com/account", visits: 10)
        let history = try history(addresses.map { entry($0, visits: 100) } + [real, entry("https://github.com/issues?q=is%3Aopen", visits: 3)])
        let values = suggestions(history)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.first?.url?.absoluteString, real.url)
        XCTAssertTrue(values.contains { $0.url?.path == "/issues" }, "A reusable filtered workspace is not a web-search handoff")
        XCTAssertTrue(AddressSuggestionEngine.suggestions(for: "signin.example", history: history, tabs: [], at: now)
            .contains { $0.url?.host == "signin.example.com" }, "Filtering a blank shortcut doesn't delete searchable history")
    }

    func testFreshVisitsChangeTheListImmediatelyAndSurviveRelaunchAndSync() throws {
        let old = entry("https://old.example/", visits: 100, daysAgo: 30)
        let local = try history([old]), remote = try history()
        let current = URL(string: "https://current.example/your-page")!
        for _ in 0..<5 { remote.record(current, title: "Current habit", at: now) }
        local.merge(remote.snapshot)
        XCTAssertEqual(suggestions(local).first?.url, current)
        try local.save()
        let reopened = BrowsingHistory(storageURL: local.storageURL)
        XCTAssertEqual(suggestions(reopened).map(\.url), suggestions(local).map(\.url))
        let later = now.addingTimeInterval(30*86400)
        let new = URL(string: "https://new.example/")!
        reopened.record(new, title: "New routine", at: later)
        XCTAssertEqual(suggestions(reopened, at: later).first?.url, new)
        XCTAssertEqual(reopened.entries.first { $0.url == current.absoluteString }?.visits, 5)
    }

    func testStarterLinksAreOnlyAFallbackAndTabBackfillIsAlsoDiverse() throws {
        let history = try history()
        XCTAssertEqual(suggestions(history).map(\.title), ["Hacker News", "Wikipedia", "GitHub"])
        let tabs = [AddressSuggestionTab(id: UUID(), title: "Docs", url: URL(string: "https://work.example/docs")),
                    AddressSuggestionTab(id: UUID(), title: "Other docs", url: URL(string: "https://www.work.example/other")),
                    AddressSuggestionTab(id: UUID(), title: "Another site", url: URL(string: "https://another.example/")),
                    AddressSuggestionTab(id: UUID(), title: "Credentials", url: URL(string: "https://user:secret@secret.example/"))]
        XCTAssertEqual(suggestions(history, tabs: tabs).map(\.title), ["Docs", "Another site"])
        history.record(URL(string: "https://real.example/")!, title: "Your page", at: now)
        XCTAssertEqual(suggestions(history).map(\.title), ["Your page"])
        XCTAssertTrue(suggestions(history, limit: 0).isEmpty)
        XCTAssertTrue(suggestions(history, limit: -1).isEmpty)
        XCTAssertEqual(suggestions(history, tabs: tabs, limit: 1).count, 1)
    }

    func testBlankPanelDecayDoesNotChangeLearnedTypedPathCompletion() throws {
        let account = entry("https://voxi.co.uk/account", visits: 25, daysAgo: 30)
        let history = try history([account, entry("https://voxi.co.uk/", visits: 3), entry("https://new.example/", visits: 4)])
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: history, tabs: [], at: now).first?.completion, "voxi.co.uk/account")
        _ = suggestions(history)
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: history, tabs: [], at: now).first?.completion, "voxi.co.uk/account")
    }
}
