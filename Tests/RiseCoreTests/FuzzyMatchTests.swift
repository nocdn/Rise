import XCTest
@testable import RiseCore

final class FuzzyMatchTests: XCTestCase {
    func testWholeWordsAtTheStartBeatScatteredLetters() throws {
        XCTAssertEqual(FuzzyMatch.score("", in: "Anything"), 0)
        XCTAssertNil(FuzzyMatch.score("xyz", in: "Python"))
        // Accents and case don't matter.
        XCTAssertNotNil(FuzzyMatch.score("ICO", in: "Icônes"))
        let start = try XCTUnwrap(FuzzyMatch.score("py", in: "Python docs"))
        let word = try XCTUnwrap(FuzzyMatch.score("py", in: "Learn Python"))
        let inside = try XCTUnwrap(FuzzyMatch.score("py", in: "Happy days"))
        let scattered = try XCTUnwrap(FuzzyMatch.score("pyd", in: "Python docs"))
        XCTAssertGreaterThan(start, word); XCTAssertGreaterThan(word, inside)
        XCTAssertLessThan(scattered, inside, "Letters in order count for less than the whole")
        // Every word must match, in any order.
        XCTAssertNotNil(FuzzyMatch.score("docs py", in: "Python docs"))
        XCTAssertNil(FuzzyMatch.score("docs ruby", in: "Python docs"))
    }

    func testRankingPutsTheBestFirstAndKeepsTiesInOrder() {
        let pages = [("GitHub", "github.com"), ("Python docs", "docs.python.org"), ("Learn Python", "learn.example"), ("Gmail", "mail.google.com")]
        let ranked = { (query: String) in FuzzyMatch.ranked(pages, query: query) { [$0.0, $0.1] }.map(\.0) }
        XCTAssertEqual(ranked(""), ["GitHub", "Python docs", "Learn Python", "Gmail"])
        XCTAssertEqual(ranked("py"), ["Python docs", "Learn Python"])
        // Two at the start tie, in their own order; one in an address's middle comes after.
        XCTAssertEqual(ranked("g"), ["GitHub", "Gmail", "Python docs"])
        XCTAssertEqual(ranked("mail").first, "Gmail")
        // The address counts, a little less than the title.
        XCTAssertEqual(ranked("google"), ["Gmail"])
    }
}
