import XCTest
@testable import RiseCore

final class AddressSuggestionEngineTests: XCTestCase {
    func testASingleLetterCompletesTheLearnedDestinationAfterRelaunch() throws {
        let file = URL.temporaryDirectory.appendingPathComponent("RiseAddress-\(UUID())/history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        let home = URL(string: "https://x.com/")!, article = URL(string: "https://x.com/person/status/123")!
        for _ in 0..<12 { history.record(home, title: "X") }
        for _ in 0..<10 { history.record(article, title: "A post on X") }
        for _ in 0..<100 { history.record(URL(string: "https://example.com/")!, title: "X notes") }
        try history.save()
        let restored = BrowsingHistory(storageURL: file)
        let tab = AddressSuggestionTab(id: UUID(), title: "X", url: home)
        for query in ["x", "X"] {
            let values = AddressSuggestionEngine.suggestions(for: query, history: restored, tabs: [tab])
            XCTAssertEqual(values.first?.completion, query+".com")
            XCTAssertEqual(values.first?.url, home)
            XCTAssertEqual(values.first?.tabID, tab.id)
            let mixed = AddressSuggestionEngine.merging(["x", "x news"], into: values)
            XCTAssertEqual(mixed.first?.completion, query+".com", "Remote search terms cannot replace the learned completion")
        }
        let fresh = BrowsingHistory(storageURL: file.deletingLastPathComponent().appendingPathComponent("fresh.json"))
        XCTAssertNil(AddressSuggestionEngine.suggestions(for: "x", history: fresh, tabs: []).first?.completion,
                     "One letter alone must not pick an unvisited site from the catalog")
        fresh.record(URL(string: "https://example.com/")!, title: "X notes")
        XCTAssertNil(AddressSuggestionEngine.suggestions(for: "x", history: fresh, tabs: []).first?.completion,
                     "A title or URL substring cannot become an inline completion")
    }
    func testASingleLetterMatchesTheSiteInsteadOfItsSchemeOrWWWPrefix() {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for _ in 0..<20 { history.record(URL(string: "https://www.example.com/")!, title: "Frequent page") }
        for (query, domain) in [("h", "hello.example"), ("w", "www.wikipedia.org"), ("e", "www.example.com")] {
            let url = URL(string: "https://\(domain)/")!
            history.record(url, title: "Another page")
            let first = AddressSuggestionEngine.suggestions(for: query, history: history, tabs: []).first
            XCTAssertEqual(first?.url, url)
            XCTAssertEqual(first?.completion, domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain)
        }
        XCTAssertNil(BrowsingHistory.completion(for: "h", url: URL(string: "https://example.com/")!))
        XCTAssertNil(BrowsingHistory.completion(for: "w", url: URL(string: "https://www.example.com/")!))
    }
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
    func testRepeatedPageVisitsCompleteThePreferredPathFromExistingSavedHistory() throws {
        let file = URL.temporaryDirectory.appendingPathComponent("RiseAddress-\(UUID())/history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        let home = URL(string: "https://voxi.co.uk/")!, account = URL(string: "https://voxi.co.uk/account")!
        let yesterday = Date().addingTimeInterval(-86400)
        for _ in 0..<12 { history.record(account, title: "My account", at: yesterday) }
        for _ in 0..<3 { history.record(home, title: "VOXI") }
        try history.save()
        let restored = BrowsingHistory(storageURL: file)
        let tab = AddressSuggestionTab(id: UUID(), title: "Your VOXI account", url: account)
        for (query, completion) in [("vox", "voxi.co.uk/account"), ("VOX", "VOXi.co.uk/account"),
                                    ("https://vox", account.absoluteString), ("voxi.co.uk/a", "voxi.co.uk/account")] {
            let values = AddressSuggestionEngine.suggestions(for: query, history: restored, tabs: [tab])
            XCTAssertEqual(values.first?.completion, completion)
            XCTAssertEqual(values.first?.url, account, "Go must open the completed path, not its homepage")
            XCTAssertEqual(values.first?.tabID, tab.id)
            XCTAssertEqual(values.filter { $0.url == account }.count, 1)
        }
        for _ in 0..<40 { restored.record(home, title: "VOXI") }
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: restored, tabs: []).first?.completion,
                       "voxi.co.uk", "A changed browsing habit can make the homepage preferred again")
        restored.remove(home)
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: restored, tabs: []).first?.completion, "voxi.co.uk/account")
    }
    func testOneOffDeepLinksAndRepeatedSearchQueriesDoNotFillAnIncidentalPath() {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let article = URL(string: "https://news.example/some-article")!
        history.record(article, title: "An article")
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "news", history: history, tabs: []).first?.completion, "news.example")
        let results = URL(string: "https://shop.example/search?q=lamps")!
        for _ in 0..<10 { history.record(results, title: "Lamps") }
        let result = AddressSuggestionEngine.suggestions(for: "shop", history: history, tabs: []).first
        XCTAssertEqual(result?.completion, "shop.example")
        XCTAssertEqual(result?.url, URL(string: "https://shop.example/"))
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "shop.example/s", history: history, tabs: []).first?.completion,
                       "shop.example/search?q=lamps", "An explicitly typed path can still complete its full address")
    }
    func testAccountCompletionDoesNotLoseItsPathToRepeatedLoginRedirects() throws {
        let file = URL.temporaryDirectory.appendingPathComponent("RiseAccount-\(UUID())/history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        let account = URL(string: "https://www.voxi.co.uk/account")!
        let signIn = URL(string: "https://www.voxi.co.uk/sign-in?returnTo=account")!
        let home = URL(string: "https://www.voxi.co.uk/")!
        // The phone had 22 account visits and 19 sign-ins. A few more redirects must
        // not flip the learned destination back to the host, or become the completion.
        for _ in 0..<22 { history.record(account, title: "Your account") }
        for _ in 0..<30 { history.record(signIn, title: "Sign in") }
        for _ in 0..<3 { history.record(home, title: "VOXI") }
        try history.save()
        let restored = BrowsingHistory(storageURL: file)
        let tab = AddressSuggestionTab(id: UUID(), title: "Your account", url: account)
        for query in ["v", "vo", "vox", "voxi", "voxi.co.uk", "voxi.co.uk/", "www.vox", "https://www.vox"] {
            let first = try XCTUnwrap(AddressSuggestionEngine.suggestions(for: query, history: restored, tabs: [tab]).first)
            XCTAssertEqual(first.url, account, query)
            XCTAssertEqual(first.completion, BrowsingHistory.completion(for: query, url: account, includePath: true), query)
            XCTAssertEqual(first.tabID, tab.id)
        }
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "voxi.co.uk/s", history: restored, tabs: []).first?.url, signIn,
                       "An explicitly typed login path still completes normally")
        for _ in 0..<60 { restored.record(home, title: "VOXI") }
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: restored, tabs: []).first?.url, home,
                       "A genuine change toward the homepage still changes the destination")
    }
    func testTypedAccountPreferenceSurvivesRedirectsAndDoesNotPromoteOneOffPaths() throws {
        let file = URL.temporaryDirectory.appendingPathComponent("RiseTypedAccount-\(UUID())/history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        let account = URL(string: "https://voxi.co.uk/account")!, home = URL(string: "https://voxi.co.uk/")!
        let signIn = URL(string: "https://voxi.co.uk/sign-in?returnTo=account")!
        history.recordTyped(account)
        history.record(signIn, title: "Sign in")
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: history, tabs: []).first?.url, home,
                       "A single address choice is not a repeated habit")
        for _ in 0..<5 { history.recordTyped(account); history.record(signIn, title: "Sign in") }
        try history.save()
        let restored = BrowsingHistory(storageURL: file)
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: restored, tabs: []).first?.url, account,
                       "Repeatedly asking for the account beats where authentication redirects")
        for index in 0..<10 {
            let article = URL(string: "https://news.example/article-\(index)")!
            for _ in 0..<3 { restored.record(article, title: "Article") }
        }
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "news", history: restored, tabs: []).first?.completion, "news.example",
                       "Several equally used pages do not invent a preferred path")
    }
    /// A console used through several pages adds up past a page's half-share of a site,
    /// but the address typed over and over is still what the person means.
    func testRepeatedlyTypedAddressSurvivesASiteSpreadAcrossManyPages() throws {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let console = URL(string: "https://opencode.ai/console")!
        for (address, visits) in [("https://opencode.ai/", 1), ("https://opencode.ai/console/", 1),
                                  ("https://opencode.ai/console/go", 4), ("https://opencode.ai/console/workspace", 7),
                                  ("https://opencode.ai/console/wrk_01/go", 3), ("https://opencode.ai/console/login", 1)] {
            for _ in 0..<visits { history.record(URL(string: address)!, title: "OpenCode Console") }
        }
        for _ in 0..<4 { history.recordTyped(console) }
        let first = try XCTUnwrap(AddressSuggestionEngine.suggestions(for: "open", history: history, tabs: []).first)
        XCTAssertEqual(first.completion, "opencode.ai/console")
        XCTAssertEqual(first.url, console)
        let exact = try XCTUnwrap(AddressSuggestionEngine.suggestions(for: "opencode.ai/console", history: history, tabs: []).first)
        XCTAssertEqual(exact.url, console, "An address typed in full stays itself")
        XCTAssertNil(exact.completion, "A complete address has nothing left to fill in")
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

    /// Many pages of one site outweigh one page of another, and what's typed weighs most of all.
    func testTheSiteVisitedAndTypedMostFillsInNotTheBusiestSinglePage() {
        let history = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for _ in 0..<7 { history.record(URL(string: "https://gitlab.com/gitlab-org/gitlab/-/merge_requests")!, title: "Merge requests") }
        for number in 46970...46976 { for _ in 0..<2 { history.record(URL(string: "https://gitlab.cfdata.org/fe/stratus/-/merge_requests/\(number)")!, title: "MR") } }
        XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "gitl", history: history, tabs: []).first?.completion, "gitlab.cfdata.org",
                       "Fourteen visits across a site's pages beat seven to one page, and fill in the site, not one of its pages")

        let typed = BrowsingHistory(storageURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for _ in 0..<12 { typed.record(URL(string: "https://gitlab.com/gitlab-org/gitlab/-/merge_requests")!, title: "Merge requests") }
        // Typing the address sent the browser to sign in, so only that page was kept as a visit.
        for _ in 0..<3 { typed.recordTyped(URL(string: "https://gitlab.cfdata.org/")!); typed.record(URL(string: "https://gitlab.cfdata.org/users/sign_in")!, title: "Sign in") }
        let first = AddressSuggestionEngine.suggestions(for: "gitl", history: typed, tabs: []).first
        XCTAssertEqual(first?.completion, "gitlab.cfdata.org")
        XCTAssertEqual(first?.url, URL(string: "https://gitlab.cfdata.org/"))
    }
}
