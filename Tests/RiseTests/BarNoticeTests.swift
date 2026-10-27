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
        let words = notice.subviews.compactMap { $0 as? PlainNavBarText }.first
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

    func testCalendarAndRemindersFitAndBothActionsTakeClicks() throws {
        let (bar, window) = bar(); defer { window.close() }
        for name in ["Calendar", "Reminders"] {
            var opened = false, undone = false
            bar.showNotice("Added to", image: BarNotice.calendarImage,
                           link: .init(text: name) { opened = true }, action: .init(text: "Undo ⌘Z") { undone = true }, hold: 10)
            bar.layoutSubtreeIfNeeded()
            let notice = try XCTUnwrap(bar.notice); notice.layoutSubtreeIfNeeded()
            let link = try XCTUnwrap(notice.linkLabel), action = try XCTUnwrap(notice.actionLabel)
            let textWidth = (name as NSString).size(withAttributes: [.font: PlainNavBar.Metrics.font]).width
            XCTAssertGreaterThanOrEqual(link.bounds.width, ceil(textWidth)+4, "The last glyph has room for its cell margins")
            XCTAssertLessThan(link.frame.maxX, action.frame.minX)
            XCTAssertLessThanOrEqual(action.frame.maxX, notice.bounds.maxX)
            XCTAssertTrue(link.accessibilityPerformPress()); XCTAssertTrue(opened)
            XCTAssertTrue(action.accessibilityPerformPress()); XCTAssertTrue(undone)
        }
    }
    func testASecondSaveWithTheSameConfirmationReplacesTheOldItemLink() throws {
        let (bar, window) = bar(); defer { window.close() }
        var opened = 0
        bar.showNotice("Added to", image: BarNotice.calendarImage, link: .init(text: "Calendar") { opened = 1 })
        bar.showNotice("Added to", image: BarNotice.calendarImage, link: .init(text: "Calendar") { opened = 2 })
        XCTAssertTrue(try XCTUnwrap(bar.notice?.linkLabel).accessibilityPerformPress())
        XCTAssertEqual(opened, 2)
    }
}
