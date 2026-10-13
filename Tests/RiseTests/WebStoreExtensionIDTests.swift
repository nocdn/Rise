#if RISE_CHROMIUM
import XCTest
@testable import Rise

@MainActor final class WebStoreExtensionIDTests: XCTestCase {
    func testFindsTheExtensionOnlyOnAStoreDetailPage() {
        let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        XCTAssertEqual(BrowserController.webStoreExtensionID(URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)?hl=en")), id)
        XCTAssertEqual(BrowserController.webStoreExtensionID(URL(string: "https://chromewebstore.google.com/detail/\(id)")), id)
        XCTAssertNil(BrowserController.webStoreExtensionID(URL(string: "https://chromewebstore.google.com/category/extensions")))
        XCTAssertNil(BrowserController.webStoreExtensionID(URL(string: "https://example.com/detail/x/\(id)")))
    }
}
#endif
