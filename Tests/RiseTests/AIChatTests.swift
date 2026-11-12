import XCTest
import AppKit
@testable import Rise

@MainActor final class AIChatTests: XCTestCase {
    private func page(_ title: String, _ url: String) -> AIChatAttachment {
        AIChatAttachment(tabID: UUID(), title: title, url: URL(string: url), favicon: nil)
    }

    func testMessagesPutEachQuestionsPagesInFrontOfItAndSkipUnansweredTurns() {
        var first = AIChatTurn(question: "What is this?", pages: [page("Icônes", "https://icones.js.org")])
        first.snapshots = [PageAssistant.Page(title: "Icônes", url: "https://icones.js.org", selection: "", text: "Icon sets.")]
        first.answer = "A site for icons."
        var failed = AIChatTurn(question: "Lost question", pages: [])
        failed.failed = true
        var current = AIChatTurn(question: "Who made it?", pages: [])
        current.snapshots = [PageAssistant.Page(title: "About", url: "https://example.com", selection: "Anthony Fu", text: "Credits.")]

        let messages = AIChatPrompt.messages(history: [first, failed], current: current, instructions: "Be brief.")
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, "Be brief.")
        XCTAssertEqual(messages[1]["content"] as? String, "<page>\nTitle: Icônes\nURL: https://icones.js.org\n\nIcon sets.\n</page>\n\nWhat is this?")
        XCTAssertEqual(messages[2]["content"] as? String, "A site for icons.")
        XCTAssertEqual(messages[3]["content"] as? String,
                       "<page>\nTitle: About\nURL: https://example.com\nSelected text: Anthony Fu\n\nCredits.\n</page>\n\nWho made it?")
        XCTAssertEqual(AIChatPrompt.content(AIChatTurn(question: "Just this", pages: [])), "Just this")
    }

    func testThoughtLabelIsWholeSecondsAndNeverUnderOne() {
        XCTAssertEqual(AIChatPrompt.thought(0.2), "Thought for 1 second")
        XCTAssertEqual(AIChatPrompt.thought(1.4), "Thought for 1 second")
        XCTAssertEqual(AIChatPrompt.thought(2.6), "Thought for 3 seconds")
    }

    func testAttachmentShowsItsHostWithoutWWWAndMatchesByURL() {
        let a = page("Docs", "https://www.python.org/doc/")
        XCTAssertEqual(a.subtitle, "python.org")
        XCTAssertTrue(a.isSamePage(as: page("Other title", "https://www.python.org/doc/")))
        XCTAssertFalse(a.isSamePage(as: page("Docs", "https://www.python.org/")))
        XCTAssertFalse(AIChatAttachment(tabID: nil, title: "Blank", url: nil, favicon: nil).isSamePage(as: AIChatAttachment(tabID: nil, title: "Blank", url: nil, favicon: nil)))
    }

    func testMarkdownBlocks() {
        let text = """
        ## Overview
        First line
        continues here.

        - One
          - Nested
        2. Two
        > Quoted
        ```swift
        let x = 1
        ```
        ---
        Last
        """
        XCTAssertEqual(AIChatMarkdown.blocks(text), [
            .heading(level: 2, text: "Overview"),
            .paragraph("First line continues here."),
            .bullet(depth: 0, text: "One"),
            .bullet(depth: 1, text: "Nested"),
            .numbered(depth: 0, number: "2", text: "Two"),
            .quote("Quoted"),
            .code("let x = 1"),
            .paragraph("Last"),
        ])
    }

    func testStreamingHoldsBackALastLineThatIsOnlyAMarker() {
        XCTAssertEqual(AIChatMarkdown.blocks("Intro\n-", finished: false), [.paragraph("Intro")])
        XCTAssertEqual(AIChatMarkdown.blocks("Intro\n12.", finished: false), [.paragraph("Intro")])
        XCTAssertEqual(AIChatMarkdown.blocks("Intro\n```py", finished: false), [.paragraph("Intro")])
        XCTAssertEqual(AIChatMarkdown.blocks("Intro\n- a", finished: false), [.paragraph("Intro"), .bullet(depth: 0, text: "a")])
    }

    func testRenderedMarkdownStylesInlineSpansWithoutTheirMarkers() {
        let colors = AIChatColors(.neutral)
        let rendered = AIChatMarkdown.render("Use **bold** and `code`.\n\n- item", colors: colors)
        XCTAssertEqual(rendered.string, "Use bold and code.\n•\titem")
        let bold = rendered.attribute(.font, at: (rendered.string as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bold?.fontDescriptor.symbolicTraits.contains(.bold), true)
        let code = (rendered.string as NSString).range(of: "code").location
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: code, effectiveRange: nil))
        XCTAssertTrue((rendered.attribute(.font, at: code, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
    }

    func testChatAnswersSharpenInPlaceWithoutSlidingIn() {
        XCTAssertFalse(makeAIChatTextView().tokenLayout.travels)
    }

    func testPanelOpensAtDiasWidthAndKeepsWithinItsLimits() {
        let panel = AIChatPanel()
        XCTAssertEqual(panel.width(room: 1600), AIChatStyle.defaultWidth)
        panel.chosenWidth = 200
        XCTAssertEqual(panel.width(room: 1600), AIChatStyle.minimumWidth)
        panel.chosenWidth = 700
        XCTAssertEqual(panel.width(room: 1600), 700)
        // The page keeps the room DevTools leave it.
        let room: CGFloat = 900
        XCTAssertEqual(panel.width(room: room), room-DevToolsPanel.minimumPageWidth-PageAppearance.inset)
    }

    func testEveryAttachedPageCanBeRemovedWithTheButtonOnItsCorner() throws {
        let view = AIChatView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        let icones = page("Icônes", "https://icones.js.org"), python = page("Python", "https://www.python.org")
        let docs = page("Docs", "https://docs.python.org")
        view.openPages = { [icones, python, docs] }
        view.setCurrentPage(icones)
        for title in ["Python", "Docs"] {
            let item = try XCTUnwrap(view.composer.plusButton.makeMenu?()?.items.first { $0.title == title })
            (item.target as? MenuAction)?.invoke()
        }
        let titles = { view.composer.attachments.map(\.title) }
        XCTAssertEqual(titles(), ["Python", "Docs", "Icônes"])

        // Each chip's button pokes out past its top-right corner and still takes the click there.
        view.composer.frame = NSRect(x: 0, y: 0, width: 464, height: 170)
        view.composer.layoutSubtreeIfNeeded(); view.composer.layout()
        for chip in view.composer.chips {
            let button = try XCTUnwrap(chip.removeButton)
            XCTAssertTrue(button.isHidden, "Shown only while the pointer is on the page")
            button.isHidden = false
            XCTAssertEqual(button.frame.width, 18)
            XCTAssertEqual(button.frame.midX, chip.bounds.width-4); XCTAssertEqual(button.frame.midY, 4)
            let overhang = chip.convert(NSPoint(x: button.frame.maxX-3, y: button.frame.minY+3), to: view.composer)
            XCTAssertTrue(view.composer.hitTest(overhang) === button)
        }

        view.composer.chips[1].onRemove?()
        XCTAssertEqual(titles(), ["Python", "Icônes"])
        // The page in front stays off once taken off, until another page comes to the front.
        try XCTUnwrap(view.composer.chips.last).onRemove?()
        XCTAssertEqual(titles(), ["Python"])
        view.setCurrentPage(icones)
        XCTAssertEqual(titles(), ["Python"])
        try XCTUnwrap(view.composer.chips.first).onRemove?()
        XCTAssertEqual(titles(), [])
        view.setCurrentPage(python)
        XCTAssertEqual(titles(), ["Python"])

        // Taken off, added back from the + menu, and taken off again, it stays off.
        try XCTUnwrap(view.composer.chips.first).onRemove?()
        let item = try XCTUnwrap(view.composer.plusButton.makeMenu?()?.items.first { $0.title == "Python" })
        (item.target as? MenuAction)?.invoke()
        XCTAssertEqual(titles(), ["Python"])
        try XCTUnwrap(view.composer.chips.first).onRemove?()
        XCTAssertEqual(titles(), [])
    }

    func testThePageInFrontIsAttachedUntilItHasBeenAskedAbout() {
        let view = AIChatView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        view.respond = { _ in AsyncThrowingStream { $0.finish() } }
        view.snapshot = { _ in nil }
        let icones = page("Icônes", "https://icones.js.org")
        view.setCurrentPage(icones)
        XCTAssertEqual(view.composer.attachments, [icones])

        view.send("What is this?")
        XCTAssertEqual(view.turns.last?.pages, [icones])
        XCTAssertEqual(view.composer.attachments, [], "Already in the conversation")
        view.setCurrentPage(icones)
        XCTAssertEqual(view.composer.attachments, [])

        let python = page("Python", "https://www.python.org")
        view.setCurrentPage(python)
        XCTAssertEqual(view.composer.attachments, [python])
        view.newChat()
        view.setCurrentPage(icones)
        XCTAssertEqual(view.composer.attachments, [icones], "A new chat attaches it again")
    }
}
