import XCTest
@testable import RiseCore

final class SelectionAddressesTests: XCTestCase {
    func testAddressesTheDetectorMissesAreFound() {
        for (text, query) in [
            ("100 Newland Park Drive, York", "100 Newland Park Drive, York"),
            ("Newland Park Drive, Hull Road, York.", "Newland Park Drive, Hull Road, York"),
            ("Hull Road, York", "Hull Road, York"),
            ("  42 Station Rd\nHeslington\n", "42 Station Rd, Heslington"),
            ("Flat 3, 12 Heslington Lane, York", "Flat 3, 12 Heslington Lane, York"),
            ("5th Avenue, New York", "5th Avenue, New York"),
            ("Visit us at 12 High Street, Oxford", "12 High Street, Oxford"),
            ("ul. Marszałkowska 10, 00-001 Warszawa", "ul. Marszałkowska 10, 00-001 Warszawa"),
            ("Hauptstraße 5, Berlin", "Hauptstraße 5, Berlin"),
            ("Prinsengracht 263", "Prinsengracht 263"),
            ("York YO10 3HP", "York YO10 3HP"),
        ] {
            XCTAssertEqual(SelectionAddresses.find(in: text), query, text)
        }
    }

    func testAddressesTheDetectorFindsAreKeptWhole() {
        for text in ["1600 Amphitheatre Parkway, Mountain View, CA 94043", "10 Downing Street, London SW1A 2AA",
                     "100 Newland Park Drive, York YO10 3HP", "221B Baker Street", "Rue de Rivoli 99, 75001 Paris"] {
            XCTAssertEqual(SelectionAddresses.find(in: text), text, text)
        }
    }

    func testProseNamesAndOtherSelectionsAreNotAddresses() {
        for text in ["", "   ", "York", "Paris", "Park Drive", "Baker Street", "Avenue Q", "I live on Park Road",
                     "Meet me at 5 Main St tomorrow", "The quick brown fox jumps over the lazy dog.", "£844.96",
                     "Where is 12 High Street, Oxford?", "https://example.com/12-high-street", "SW1A 2AA",
                     "6 bedrooms", "Place your order now", "2024 Olympics",
                     String(repeating: "12 High Street, ", count: 20) + "Oxford"] {
            XCTAssertNil(SelectionAddresses.find(in: text), text)
        }
    }

    func testMapsURLSearchesTheWholeAddress() {
        let url = SelectionAddresses.mapsURL(for: "100 Newland Park Drive, York & Co+")
        XCTAssertEqual(url.absoluteString, "https://www.google.com/maps/search/?api=1&query=100%20Newland%20Park%20Drive%2C%20York%20%26%20Co%2B")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value,
                       "100 Newland Park Drive, York & Co+")
    }
}
