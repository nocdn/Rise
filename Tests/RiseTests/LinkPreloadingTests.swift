import XCTest
@testable import Rise

// Preloading itself is checked on Chromium: Tests/Live/ChromiumFeatureChecks.swift.
final class LinkPreloadingTests: XCTestCase {
    func testEligibilityRejectsSpecialSchemesAndSameDocumentLinks() {
        let source = URL(string: "https://example.com/page")!
        for value in ["https://example.com/page#part", "mailto:test@example.com", "file:///tmp/page", "javascript:alert(1)", "https://user:secret@example.com/other"] {
            XCTAssertFalse(LinkPreloader.isEligible(URL(string: value)!, from: source))
        }
        XCTAssertTrue(LinkPreloader.isEligible(URL(string: "https://other.example/page")!, from: source))
    }
}
