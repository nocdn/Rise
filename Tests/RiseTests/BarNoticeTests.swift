import XCTest
import AppKit
@testable import Rise

@MainActor final class BarNoticeTests: XCTestCase {
    private func bar() -> (PlainNavBar, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = PlainNavBar(copy: {}, settings: {}, zoom: {})
        bar.frame = NSRect(x: 0, y: 0, width: 800, height: PlainNavBar.Metrics.height)
        window.contentView?.addSubview(bar)
        bar.show(url: URL(string: "https://example.com/a"), title: "Example")
        return (bar, window)
    }

    func testALinkAfterTheWordsTakesClicksAndNothingElseDoes() throws {
        let (bar, window) = bar(); defer { window.close() }
        var opened = 0
        bar.showNotice("Saved to", image: BarNotice.photoImage, link: .init(text: "Downloads") { opened += 1 }, hold: 2)
        let notice = try XCTUnwrap(bar.notice)
        bar.layoutSubtreeIfNeeded(); notice.layoutSubtreeIfNeeded()
        XCTAssertEqual(notice.text, "Saved to Downloads")
        let link = try XCTUnwrap(notice.linkLabel)
        XCTAssertEqual(link.stringValue, "Downloads")
        XCTAssertEqual(notice.frame.width, link.frame.maxX, accuracy: 0.5, "The row ends with its link")
        let words = notice.subviews.compactMap { $0 as? PlainNavBarText }.first { !($0 is BarLinkLabel) }
        XCTAssertGreaterThan(link.frame.minX, try XCTUnwrap(words).frame.maxX-4, "After the words")
        let onLink = bar.convert(NSPoint(x: link.frame.midX, y: link.frame.midY), from: notice)
        XCTAssertTrue(bar.hitTest(onLink) === link)
        let onWords = bar.convert(NSPoint(x: 30, y: link.frame.midY), from: notice)
        XCTAssertFalse(bar.hitTest(onWords) is BarLinkLabel, "The words leave clicks to the bar")
        XCTAssertTrue(link.accessibilityPerformPress()); XCTAssertEqual(opened, 1)
        // A row that's gone doesn't take clicks while it leaves.
        bar.hideNotice()
        XCTAssertFalse(bar.hitTest(onLink) is BarLinkLabel)
    }

    func testAnotherMessageSwapsTheWholeRowAndTheSameAgainKeepsIt() throws {
        let (bar, window) = bar(); defer { window.close() }
        bar.showNotice("Starring Repository", image: BarNotice.spinnerImage, hold: 90)
        let starring = try XCTUnwrap(bar.notice)
        XCTAssertTrue(starring.subviews.first?.subviews.first is SpinnerView, "A spinner in the glyph's place")
        bar.showNotice("Starring Repository", image: BarNotice.spinnerImage, hold: 90)
        XCTAssertTrue(bar.notice === starring)
        bar.showNotice("Starred Repository", image: BarNotice.starImage, hold: 2)
        XCTAssertFalse(bar.notice === starring); XCTAssertEqual(starring.alphaValue, 0)
        XCTAssertEqual(bar.notice?.text, "Starred Repository"); XCTAssertEqual(bar.text.alphaValue, 0)
    }
}
