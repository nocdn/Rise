import XCTest
@testable import RiseCore

final class PopularSitesTests: XCTestCase {
    func testWellKnownSitesFillInForTheirRegionAndSearchWhereverTheirAddressPoints() throws {
        let british = try XCTUnwrap(PopularSites.completion(for: "amaz", in: "GB"))
        XCTAssertEqual(british.completed, "amazon.co.uk", "Britain gets Amazon's British domain")
        XCTAssertEqual(PopularSites.completion(for: "amaz", in: "US")?.completed, "amazon.com")
        XCTAssertEqual(PopularSites.completion(for: "You", in: "GB")?.completed, "Youtube.com", "What was typed keeps its own letters")
        XCTAssertEqual(PopularSites.completion(for: "www.yout", in: "GB")?.completed, "www.youtube.com")
        XCTAssertNil(PopularSites.completion(for: "y", in: "GB"), "One letter is too little to guess from")
        XCTAssertNil(PopularSites.completion(for: "youtube.com", in: "GB"), "Nothing left to fill in")
        XCTAssertNil(PopularSites.completion(for: "amazon prime", in: "GB"), "Words aren't an address")

        // Typed out in another region's form, the search goes to that domain.
        let american = try XCTUnwrap(PopularSites.site(forAddress: "https://www.amazon.com/", in: "GB"))
        XCTAssertEqual(american.name, "Amazon")
        XCTAssertEqual(american.searchURL(for: "usb c & cable")?.absoluteString, "https://www.amazon.com/s?k=usb%20c%20%26%20cable")
        XCTAssertEqual(PopularSites.site(forAddress: "youtube.com", in: "GB")?.searchURL(for: "lofi")?.absoluteString,
                       "https://www.youtube.com/results?search_query=lofi")
        XCTAssertEqual(PopularSites.site(forAddress: "gmail.com", in: "GB")?.searchURL(for: "from:bob invoice")?.absoluteString,
                       "https://mail.google.com/mail/u/0/#search/from%3Abob%20invoice", "Gmail searches the mailbox")
        XCTAssertNil(PopularSites.site(forAddress: "youtube.com/watch", in: "GB"), "Only the site itself, not one of its pages")
        XCTAssertEqual(PopularSites.site(forAddress: "instagram.com", in: "GB")?.isSearchable, false)
    }
}
