import XCTest
@testable import RiseCore

final class LinkCopyTests: XCTestCase {
    private func copy(_ link: String) -> LinkCopy { LinkCopy(URL(string: link)!) }

    func testEmailAndPhoneLinksCopyTheAddressOrNumberAlone() {
        XCTAssertEqual(copy("mailto:hello@example.com?subject=Hi%20there"), LinkCopy(URL(string: "mailto:hello@example.com")!))
        XCTAssertEqual(copy("mailto:hello@example.com?subject=Hi").title, "Copy Email Address")
        XCTAssertEqual(copy("mailto:hello@example.com?subject=Hi").text, "hello@example.com")
        XCTAssertEqual(copy("mailto:a@example.com,%20b@example.com").title, "Copy Email Addresses")
        XCTAssertEqual(copy("mailto:a@example.com,%20b@example.com").text, "a@example.com, b@example.com")
        XCTAssertEqual(copy("MAILTO:Someone@Example.com").text, "Someone@Example.com")
        XCTAssertEqual(copy("mailto:?subject=Hi").title, "Copy Link", "No address to copy")

        XCTAssertEqual(copy("tel:+1-555-0100").title, "Copy Phone Number")
        XCTAssertEqual(copy("tel:+1-555-0100").text, "+1-555-0100")
        XCTAssertEqual(copy("tel:+44%2020%207946%200000;ext=12").text, "+44 20 7946 0000")
        XCTAssertEqual(copy("telprompt:5550100").text, "5550100")
        XCTAssertEqual(copy("callto://5550100").text, "5550100")
        XCTAssertEqual(copy("sms:+15550100?body=Hello").text, "+15550100")
        XCTAssertEqual(copy("sms:+15550100,+15550101").title, "Copy Phone Numbers")
        XCTAssertEqual(copy("facetime:+15550100").title, "Copy Phone Number")
        XCTAssertEqual(copy("facetime-audio:someone@icloud.com").title, "Copy Email Address")
        XCTAssertFalse(copy("tel:5550100").isDownloadable)
        XCTAssertEqual(["mailto:a@b.co", "tel:1", "sms:1", "geo:1,2", "geo:0,0?q=Here", "https://a.co"].map { copy($0).symbol },
                       ["envelope", "phone", "phone", "location", "mappin.and.ellipse", "link"])
    }

    func testMapLinksCopyTheirPlaceAndOthersTheLink() {
        XCTAssertEqual(copy("geo:37.786971,-122.399677;u=35").title, "Copy Coordinates")
        XCTAssertEqual(copy("geo:37.786971,-122.399677;u=35").text, "37.786971,-122.399677")
        XCTAssertEqual(copy("geo:0,0?q=1%20Infinite%20Loop,%20Cupertino").title, "Copy Address")
        XCTAssertEqual(copy("geo:0,0?q=1%20Infinite%20Loop,%20Cupertino").text, "1 Infinite Loop, Cupertino")
        for link in ["https://example.com/a?b=c", "ftp://example.com/file.zip", "data:text/plain,hi"] {
            XCTAssertEqual(copy(link).title, "Copy Link", link)
            XCTAssertNil(copy(link).text)
            XCTAssertTrue(copy(link).isDownloadable)
        }
    }
}
