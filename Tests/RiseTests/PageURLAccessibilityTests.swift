import XCTest
import AppKit
@testable import Rise

final class PageURLAccessibilityTests: XCTestCase {
    @MainActor func testFullURLIsReadableAndTracksNavigationWithoutChangingTheVisibleAddress() {
        _ = NSApplication.shared
        var copied = false
        let bar = PlainNavBar(copy: { copied = true }, settings: {}, zoom: {})
        let first = URL(string: "https://example.com/a%20path?query=one%26two#section")!
        bar.show(url: first, title: "Example")
        XCTAssertEqual(bar.copyButton.accessibilityValue() as? String, first.absoluteString)
        XCTAssertEqual(bar.copyButton.accessibilityLabel(), "Copy current URL")
        XCTAssertEqual(bar.text.stringValue, "example.com / Example")
        XCTAssertFalse(bar.isHovered)
        XCTAssertEqual(bar.copyButton.alphaValue, 0, "Reading the URL needs no hover")
        XCTAssertFalse(copied, "Reading the URL must not copy it")

        let next = URL(string: "https://example.com/redirected?query=next#other")!
        bar.show(url: next, title: "Example")
        XCTAssertEqual(bar.copyButton.accessibilityValue() as? String, next.absoluteString)
        XCTAssertEqual(bar.text.stringValue, "example.com / Example")
        bar.showCopied()
        XCTAssertEqual(bar.copyButton.accessibilityValue() as? String, next.absoluteString,
                       "Temporary feedback must not replace the current URL")
        bar.hideNotice()

        bar.show(url: URL(string: "about:blank"), title: "")
        XCTAssertEqual(bar.copyButton.accessibilityValue() as? String, "", "Blank pages must clear the previous URL")
        bar.show(url: first, title: "Example")
        bar.show(url: nil, title: "")
        XCTAssertEqual(bar.copyButton.accessibilityValue() as? String, "", "An empty bar must clear the previous URL")
    }

    @MainActor func testSplitPageBarsExposeTheirOwnURL() {
        _ = NSApplication.shared
        let left = PlainNavBar(copy: {}, settings: {}, zoom: {})
        let right = PlainNavBar(copy: {}, settings: {}, zoom: {})
        let leftURL = URL(string: "https://example.com/left")!
        let rightURL = URL(string: "https://example.com/right")!
        left.show(url: leftURL, title: "Same title")
        right.show(url: rightURL, title: "Same title")
        XCTAssertEqual(left.copyButton.accessibilityValue() as? String, leftURL.absoluteString)
        XCTAssertEqual(right.copyButton.accessibilityValue() as? String, rightURL.absoluteString)
        left.show(url: nil, title: "")
        XCTAssertEqual(right.copyButton.accessibilityValue() as? String, rightURL.absoluteString)
    }
}
