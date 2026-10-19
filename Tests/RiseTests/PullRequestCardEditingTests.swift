import AppKit
import XCTest
@testable import Rise

@MainActor final class PullRequestCardEditingTests: XCTestCase {
    func testDoubleClickEditsInPlaceKeepsTheHeightUntilReturnAndCustomContentToggles() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)); window.contentView = host
        // On screen, so the card's height spring runs. Closed without releasing itself or animating,
        // as Swift owns it.
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.orderFrontRegardless()
        let card = PullRequestTooltip(); host.addSubview(card)
        defer { card.dismiss(immediately: true); window.orderOut(nil) }
        var content = PullRequestTooltip.Content(title: "feat(card): edit in place", reference: "!1", details: nil,
                                                 summary: "The first line of a description that runs on.\nA second line.\nAnd a third.", phase: .done)
        card.onEdit = { _, title, summary in
            if let title { content.custom.title = title }
            if let summary { content.custom.summary = summary }
            content.custom.shown = true; card.update(content)
        }
        card.onShowCustom = { _, shown in content.custom.shown = shown; card.update(content) }
        card.present(key: "pr", content: content, left: 10, placement: .beside(top: 10, maxBottom: 690), theme: .neutral)
        func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }
        func doubleClick(_ view: NSView) {
            view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
        }
        try await settle()
        let full = card.frame.height

        let summary = card.summaryView
        doubleClick(summary)
        XCTAssertTrue(summary.isEditable && card.isEditing)
        XCTAssertEqual(summary.selectedRange(), NSRange(location: 0, length: (summary.string as NSString).length), "All of it selected")
        summary.delete(nil)
        try await settle()
        XCTAssertEqual(card.frame.height, full, accuracy: 1, "Emptied, the card keeps its height while editing")
        summary.insertText("A note.", replacementRange: summary.selectedRange())
        summary.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle()
        XCTAssertFalse(card.isEditing); XCTAssertEqual(content.custom.summary, "A note.")
        XCTAssertLessThan(card.frame.height, full-20, "Return fits the card to the edit")

        let item = try XCTUnwrap(card.makeMoreMenu().items.first { $0.title == "Custom Content" })
        XCTAssertEqual(item.state, .on); XCTAssertTrue(item.isEnabled)
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        try await settle()
        XCTAssertEqual(card.frame.height, full, accuracy: 1, "Unchecked, the request's own description comes back")
        XCTAssertEqual(card.summaryView.string, content.summary)
        let again = try XCTUnwrap(card.makeMoreMenu().items.first { $0.title == "Custom Content" })
        NSApp.sendAction(try XCTUnwrap(again.action), to: again.target, from: again)
        XCTAssertEqual(card.summaryView.string, "A note.", "Checked again, the edit is back")

        doubleClick(card.titleLabel)
        let editor = try XCTUnwrap(card.titleLabel.currentEditor() as? NSTextView)
        editor.insertText("Notes", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(content.custom.title, "Notes"); XCTAssertEqual(card.titleLabel.stringValue, "Notes")
    }
    func testSavedEditsShowWholeWhenTheCardOpensRatherThanPlayingIn() {
        _ = NSApplication.shared
        // In a window on screen, where a description being written plays in word by word.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 500)); window.contentView = host
        window.orderFrontRegardless()
        let card = PullRequestTooltip(); host.addSubview(card)
        defer { card.dismiss(immediately: true); window.orderOut(nil) }
        var content = PullRequestTooltip.Content(title: "fix: it", reference: "!1", details: nil, summary: "The model's description.", phase: .done)
        content.custom = .init(title: nil, summary: "My notes, saved earlier.", shown: true)
        // Shown, closed, and opened again, as hovering the same tab twice does.
        card.present(key: "pr", content: content, left: 0, placement: .beside(top: 0, maxBottom: 500), theme: .neutral)
        card.dismiss(immediately: true)
        card.present(key: "pr", content: content, left: 0, placement: .beside(top: 0, maxBottom: 500), theme: .neutral)
        XCTAssertEqual(card.summaryView.string, "My notes, saved earlier.")
        XCTAssertFalse(card.isRevealingSummary, "No words playing in")
    }
}
