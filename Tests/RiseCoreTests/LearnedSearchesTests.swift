import XCTest
@testable import RiseCore

final class LearnedSearchesTests: XCTestCase {
    private func storage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("searches.json")
    }
    func testTheParameterOrPathSegmentHoldingTheSearchBecomesTheTemplate() {
        XCTAssertEqual(LearnedSearches.template(from: URL(string: "https://szukaj.onet.pl/wyniki/?qt=atak")!, terms: ["atak"]),
                       "https://szukaj.onet.pl/wyniki/?qt={q}")
        XCTAssertEqual(LearnedSearches.template(from: URL(string: "https://shop.example/search?ref=nav&query=usb+c&page=1#top")!, terms: ["USB  c "]),
                       "https://shop.example/search?query={q}", "Spaces and case don't matter; the page's own state is left out")
        XCTAssertEqual(LearnedSearches.template(from: URL(string: "https://dict.example:8080/define/hello%20world")!, terms: ["hello world"]),
                       "https://dict.example:8080/define/{q}")
        XCTAssertNil(LearnedSearches.template(from: URL(string: "https://shop.example/item?id=42")!, terms: ["usb c"]), "Not where the search went")
        XCTAssertNil(LearnedSearches.template(from: URL(string: "https://shop.example/?page=2")!, terms: ["2"]), "One letter is too little to go by")
        XCTAssertNil(LearnedSearches.template(from: URL(string: "file:///tmp/?q=cats")!, terms: ["cats"]))
    }
    func testASiteIsSearchedFromItsOwnAddressAndItsDomainAndKeepsWhatItLearned() throws {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let searches = LearnedSearches(storageURL: file)
        XCTAssertTrue(searches.learn(from: URL(string: "https://szukaj.onet.pl/wyniki/?qt=atak")!, terms: ["atak"], name: nil))
        let onet = try XCTUnwrap(searches.site(forAddress: "onet.pl"))
        XCTAssertEqual(onet.name, "Onet", "Named after its domain when the page doesn't say")
        XCTAssertEqual(onet.searchURL(for: "ładny dzień")?.absoluteString, "https://szukaj.onet.pl/wyniki/?qt=%C5%82adny%20dzie%C5%84")
        XCTAssertEqual(searches.site(forAddress: "https://www.szukaj.onet.pl/")?.domain, "szukaj.onet.pl")
        XCTAssertNil(searches.site(forAddress: "wp.pl"))

        XCTAssertTrue(searches.learn(from: URL(string: "https://www.example.co.uk/search?q=lamps")!, terms: ["lamps"], name: "Example Shop"))
        XCTAssertTrue(searches.learn(from: URL(string: "https://help.example.co.uk/find?term=returns")!, terms: ["returns"], name: "Example Help"))
        XCTAssertEqual(searches.site(forAddress: "example.co.uk")?.name, "Example Shop", "A domain that searches itself keeps that")
        XCTAssertEqual(searches.site(forAddress: "help.example.co.uk")?.name, "Example Help")

        try searches.save()
        XCTAssertEqual(LearnedSearches(storageURL: file).searches, searches.searches)
        try searches.clear()
        XCTAssertNil(LearnedSearches(storageURL: file).site(forAddress: "onet.pl"))
    }
    func testSitesRiseAlreadySearchesKeepTheirOwnSearch() {
        let searches = LearnedSearches(storageURL: storage())
        XCTAssertFalse(searches.learn(from: URL(string: "https://github.com/search?q=hello+world&type=repositories")!, terms: ["hello world"], name: "GitHub"))
        XCTAssertFalse(searches.learn(from: URL(string: "https://m.youtube.com/results?search_query=cats")!, terms: ["cats"], name: nil))
        XCTAssertTrue(searches.learn(from: URL(string: "https://www.instagram.com/explore/search/keyword/?q=cats")!, terms: ["cats"], name: "Instagram"),
                      "A well-known site without a search of Rise's own learns one")
        XCTAssertEqual(searches.site(forAddress: "instagram.com")?.searchURL(for: "dogs")?.absoluteString,
                       "https://www.instagram.com/explore/search/keyword/?q=dogs")
    }
    func testConcurrentDevicesMergeTemplatesAndClearCannotBeUndoneByAnOfflineDevice() throws {
        let a = LearnedSearches(storageURL: storage()), b = LearnedSearches(storageURL: storage())
        XCTAssertTrue(a.learn(from: URL(string: "https://shop.example/search?q=lamps")!, terms: ["lamps"], name: "Shop"))
        XCTAssertTrue(b.learn(from: URL(string: "https://docs.example/find?term=swift")!, terms: ["swift"], name: "Docs"))
        let first = a.snapshot.merging(b.snapshot), reversed = b.snapshot.merging(a.snapshot)
        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.searches.count, 2)
        a.merge(first); b.merge(first)
        let offline = b.snapshot
        try a.clear()
        b.merge(a.snapshot)
        XCTAssertTrue(b.searches.isEmpty)
        a.merge(offline)
        XCTAssertTrue(a.searches.isEmpty)
        XCTAssertTrue(a.learn(from: URL(string: "https://shop.example/search?q=chairs")!, terms: ["chairs"], name: "Shop"))
        b.merge(a.snapshot)
        XCTAssertEqual(b.site(forAddress: "shop.example")?.searchURL(for: "table")?.absoluteString, "https://shop.example/search?q=table")
        try b.save()
        XCTAssertEqual(LearnedSearches(storageURL: b.storageURL).snapshot, b.snapshot)
    }
    func testLegacyStorageMigratesAndMalformedCloudTemplatesAreRejected() throws {
        let file = storage(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let saved = LearnedSearches.Search(name: "Shop", template: "https://shop.example/search?q={q}", learned: Date())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["shop.example": saved]).write(to: file)
        let migrated = LearnedSearches(storageURL: file)
        XCTAssertNotNil(migrated.site(forAddress: "shop.example"))
        let invalid = ["javascript:alert('{q}')", "https://other.example/?q={q}", "https://u:p@shop.example/?q={q}", "https://shop.example/?q={q}&other={q}"]
        for template in invalid {
            let incoming = LearnedSearches.Snapshot(searches: ["shop.example": .init(name: "Bad", template: template, learned: Date().addingTimeInterval(1))])
            XCTAssertFalse(migrated.merge(incoming))
        }
        let newer = LearnedSearches.Snapshot(searches: ["shop.example": .init(name: "New shop", template: "https://shop.example/find/{q}", learned: Date().addingTimeInterval(2))])
        XCTAssertTrue(migrated.merge(newer))
        XCTAssertFalse(migrated.merge(newer), "Applying the same cloud edit twice is idempotent")
        XCTAssertFalse(migrated.learn(from: URL(string: "https://shop.example/"+String(repeating: "x", count: 1100)+"?q=lamps")!,
                                      terms: ["lamps"], name: "Shop"), "A bounded set of templates fits CloudKit's record limit")
    }
    func testSameTimeDomainConflictsConvergeEvenWhenConcatenatedFieldsAreEqual() {
        let date = Date()
        let a = LearnedSearches.Snapshot(searches: ["shop.example": .init(name: "b", template: "https://shop.example/?q={q}a", learned: date)])
        let b = LearnedSearches.Snapshot(searches: ["shop.example": .init(name: "ab", template: "https://shop.example/?q={q}", learned: date)])
        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(b).merging(a), a.merging(b))
    }
}
