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
}
