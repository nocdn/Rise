import XCTest
@testable import RiseCore

final class BrowsingHistoryTests: XCTestCase {
    private func storage() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json") }
    func testVisitsSurviveRelaunchCanonicalizeFragmentsAndClearPermanently() throws {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        history.record(URL(string: "https://user:password@EXAMPLE.com:443/docs#first")!, title: "Docs")
        history.record(URL(string: "https://example.com/docs#second")!, title: "Updated docs")
        history.record(URL(string: "about:blank")!, title: "Blank")
        history.record(URL(fileURLWithPath: "/private/file"), title: "File")
        try history.save()
        let restored = BrowsingHistory(storageURL: file)
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries.first?.url, "https://example.com/docs")
        XCTAssertEqual(restored.entries.first?.visits, 2)
        XCTAssertEqual(restored.entries.first?.title, "Updated docs")
        try restored.clear()
        XCTAssertTrue(BrowsingHistory(storageURL: file).entries.isEmpty)
    }
    func testHistoryReadAheadOnAnotherThreadIsTheSameAndKeepsCounting() throws {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        history.record(URL(string: "https://example.com/a")!, title: "A")
        history.record(URL(string: "https://example.com/a")!, title: "A")
        history.record(URL(string: "https://example.org/b")!, title: "B")
        try history.save()
        let preloaded = BrowsingHistory(preloaded: .init(storageURL: file))
        XCTAssertEqual(preloaded.entries, BrowsingHistory(storageURL: file).entries)
        preloaded.record(URL(string: "https://example.com/a")!, title: "A"); try preloaded.save()
        XCTAssertEqual(BrowsingHistory(storageURL: file).visits(to: URL(string: "https://example.com/a")), 3)
        XCTAssertTrue(BrowsingHistory(preloaded: .init(storageURL: storage())).entries.isEmpty, "No file is no history")
    }
    func testAMistypedAddressThatNeverLoadedStopsBeingSuggested() {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        let typo = URL(string: "https://remotedesktop.google.come/access")!, real = URL(string: "https://remotedesktop.google.com/access")!
        history.recordTyped(typo); history.recordTyped(real); history.record(real, title: "Remote Access")
        XCTAssertEqual(history.destination(for: "remotedesktop.google.come")?.site.host, "remotedesktop.google.come")
        history.forgetFailedTyping(typo)
        history.forgetFailedTyping(real)
        XCTAssertNil(history.destination(for: "remotedesktop.google.come"), "The typo no longer fills in")
        XCTAssertEqual(history.destination(for: "remotedesktop.google.com/a")?.page?.url, real.absoluteString,
                       "A page that has loaded before stays through a failure, such as being offline")
    }
    func testIndividualRemovalCanonicalizesAndPersistsWithoutRemovingOtherVisits() throws {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        let removed = URL(string: "https://example.com/article")!, kept = URL(string: "https://example.com/other")!
        history.record(removed, title: "Remove this visit")
        history.record(removed, title: "Remove this visit")
        history.record(kept, title: "Keep this visit")
        try history.save()
        XCTAssertTrue(history.remove(URL(string: "https://user:secret@EXAMPLE.com:443/article#section")!))
        XCTAssertTrue(history.ranked(for: "Remove this").isEmpty)
        XCTAssertEqual(history.entries.map(\.url), [kept.absoluteString])
        try history.save()
        XCTAssertEqual(BrowsingHistory(storageURL: file).entries, history.entries)
        XCTAssertFalse(history.remove(removed))
        XCTAssertFalse(history.remove(URL(fileURLWithPath: "/tmp/history")))
        XCTAssertEqual(history.entries.count, 1)
        history.record(removed, title: "New visit")
        XCTAssertEqual(history.entries.first { $0.url == removed.absoluteString }?.visits, 1)
    }
    func testFrecencyRewardsRepeatedVisitsAndRecencyWithinTheSameMatchTier() {
        let history = BrowsingHistory(storageURL: storage()), now = Date(timeIntervalSince1970: 1_000_000)
        let frequent = URL(string: "https://frequent.example/docs")!, recent = URL(string: "https://recent.example/docs")!
        for _ in 0..<20 { history.record(frequent, title: "Docs", at: now.addingTimeInterval(-86400)) }
        history.record(recent, title: "Docs", at: now)
        XCTAssertEqual(history.ranked(for: "docs", at: now).first?.url, frequent.absoluteString)
        history.record(URL(string: "https://old.example")!, title: "Old", at: now.addingTimeInterval(-86400*60))
        XCTAssertLessThan(history.ranked(for: "", at: now).firstIndex { $0.url == BrowsingHistory.key(recent) }!, history.ranked(for: "", at: now).firstIndex { $0.url == "https://old.example/" }!)
    }
    func testLiteralPrefixesOutrankPopularSubstringMatchesAndMultipleWordsMustMatch() {
        let history = BrowsingHistory(storageURL: storage())
        let prefix = URL(string: "https://github.com/nocdn/Rise")!, other = URL(string: "https://example.com/github")!
        for _ in 0..<100 { history.record(other, title: "GitHub notes") }
        history.record(prefix, title: "Rise source")
        XCTAssertEqual(history.ranked(for: "git").first?.url, prefix.absoluteString)
        XCTAssertEqual(history.ranked(for: "RISE source").count, 1)
        XCTAssertTrue(history.ranked(for: "Rise unrelated").isEmpty)
    }
    func testCompletionIsALiteralPrefixAndRetainsSchemePortPathQueryAndUserCasing() {
        let url = URL(string: "https://www.example.com:8443/docs?section=swift")!
        XCTAssertEqual(BrowsingHistory.completion(for: "EXam", url: url), "EXample.com:8443", "A site's name fills in only the site")
        XCTAssertEqual(BrowsingHistory.completion(for: "https://www.ex", url: url), "https://www.example.com:8443")
        XCTAssertNil(BrowsingHistory.completion(for: "example.com:8443", url: url), "The whole site typed has nothing to fill in")
        XCTAssertEqual(BrowsingHistory.completion(for: "example.com:8443/", url: url), "example.com:8443/docs?section=swift")
        XCTAssertEqual(BrowsingHistory.completion(for: "https://www.example.com:8443/d", url: url), url.absoluteString)
        XCTAssertEqual(BrowsingHistory.site(of: url), URL(string: "https://www.example.com:8443/"))
        XCTAssertNil(BrowsingHistory.completion(for: "docs", url: url))
        XCTAssertNil(BrowsingHistory.completion(for: "example swift", url: url))
        XCTAssertEqual(BrowsingHistory.completion(for: "e", url: url), "example.com:8443")
        XCTAssertNil(BrowsingHistory.completion(for: "", url: url))
        XCTAssertEqual(BrowsingHistory.completion(for: "exam", url: URL(string: "https://example.com/")!), "example.com")
    }
    func testBoundedHistoryTitleUpdatesDoNotCountAsVisitsAndInvalidStorageIsIgnored() throws {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let history = BrowsingHistory(storageURL: file)
        for index in 0...BrowsingHistory.maximumEntries {
            history.record(URL(string: "https://example.com/\(index)")!, title: "Page \(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(history.entries.count, BrowsingHistory.maximumEntries)
        XCTAssertFalse(history.entries.contains { $0.url == "https://example.com/0" })
        history.updateTitle("New title", for: URL(string: "https://example.com/2000")!)
        XCTAssertEqual(history.entries.first { $0.url.hasSuffix("/2000") }?.visits, 1)
        try history.save()
        try Data("broken JSON".utf8).write(to: file)
        XCTAssertTrue(BrowsingHistory(storageURL: file).entries.isEmpty)
    }
}
