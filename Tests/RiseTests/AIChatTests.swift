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
            // Pages past the row's ends scroll into view first.
            chip.scrollToVisible(chip.bounds.insetBy(dx: -AIChatStyle.composerChipInset, dy: 0))
            XCTAssertTrue(button.isHidden, "Scrolling the row under no pointer shows none")
            button.isHidden = false
            // An 18 pt disc in a 2 pt ring, centred 4 pt in from the corner.
            XCTAssertEqual(button.frame.width, 22)
            XCTAssertEqual(button.frame.midX, chip.bounds.width-4, accuracy: 0.5); XCTAssertEqual(button.frame.midY, 4, accuracy: 0.5)
            let overhang = chip.convert(NSPoint(x: button.frame.midX+6, y: button.frame.midY-6), to: view.composer)
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

    /// A chat answering each question with `lines` paragraphs at once.
    private func answeringChat(lines: Int) -> AIChatView {
        let view = AIChatView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        view.snapshot = { _ in nil }
        let text = (1...lines).map { "Paragraph \($0) of the answer." }.joined(separator: "\n\n")
        view.respond = { _ in AsyncThrowingStream { $0.yield(.responded); $0.yield(.text(text)); $0.finish() } }
        view.layoutSubtreeIfNeeded()
        return view
    }
    private func answered(_ view: AIChatView) async throws {
        for _ in 0..<100 where view.isAnswering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.isAnswering)
    }

    func testTheScrollerEndsJustAboveTheComposer() async throws {
        let view = answeringChat(lines: 60)
        view.send("A long one?"); try await answered(view)
        view.layoutSubtreeIfNeeded(); view.scroll.tile()
        let scroller = try XCTUnwrap(view.scroll.verticalScroller)
        let frame = view.convert(scroller.frame, from: view.scroll)
        XCTAssertEqual(frame.maxY, view.composer.frame.minY-AIChatStyle.scrollerGap, accuracy: 1, "It ends just above the composer")
        XCTAssertGreaterThan(frame.height, 100)
        XCTAssertTrue(scroller is GmailScroller, "The calendar card's thin scroller")
        XCTAssertEqual(scroller.controlSize, .small)
        // Hidden while a question lifts off, it's the same scroller when it's back.
        view.scroll.hasVerticalScroller = false; view.scroll.hasVerticalScroller = true
        XCTAssertTrue(view.scroll.verticalScroller is GmailScroller)
    }

    private func scrollLimit(_ view: AIChatView) -> CGFloat {
        max(0, (view.scroll.documentView?.frame.height ?? 0)-view.scroll.contentSize.height)
    }
    func testSendingScrollsOnlyFarEnoughToShowTheQuestionAndFollowsALongAnswerToItsEnd() async throws {
        let view = answeringChat(lines: 40)
        view.send("First?"); try await answered(view)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scrollLimit(view), 300)
        XCTAssertEqual(view.scroll.contentView.bounds.minY, scrollLimit(view), accuracy: 0.5, "A long answer is followed to its end")
        // An answer that hasn't started: the question and "Thinking…".
        view.respond = { _ in AsyncThrowingStream { _ in } }
        view.send("Second?")
        let second = try XCTUnwrap(view.turnViews.last)
        let scrolled = view.scroll.contentView.bounds.minY
        let top = second.frame.minY-AIChatStyle.contentTop
        XCTAssertLessThan(scrolled, top-200, "Not all the way up: what came before stays in sight")
        let bubble = view.convert(second.bubblePlace, from: second)
        XCTAssertLessThanOrEqual(bubble.maxY, view.composer.frame.minY, "The question shows above the composer")
        XCTAssertGreaterThan(bubble.minY, AIChatStyle.headerHeight+100)
    }

    /// The answer as it comes in, a paragraph at a time.
    private final class Feed: @unchecked Sendable {
        var continuation: AsyncThrowingStream<AIChatAgentEvent, Error>.Continuation?
    }
    private func give(_ feed: Feed, _ view: AIChatView, paragraphs: ClosedRange<Int>) async throws {
        feed.continuation?.yield(.text(paragraphs.map { "\n\nParagraph \($0) of the answer." }.joined()))
        for _ in 0..<100 where !(view.turnViews.last?.answer.markdown ?? "").hasSuffix("Paragraph \(paragraphs.upperBound) of the answer.") {
            try await Task.sleep(for: .milliseconds(10))
        }
        view.layoutSubtreeIfNeeded()
    }
    /// A mouse's wheel, turned `pixels` towards the top; the scroll view scrolls for it a moment later.
    private func wheel(_ view: AIChatView, by pixels: Int32) async throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        let before = view.scroll.contentView.bounds.minY
        view.scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        for _ in 0..<50 where view.scroll.contentView.bounds.minY == before { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// A chat answering a long question, at the end of its first 40 paragraphs.
    private func followingChat() async throws -> (AIChatView, Feed) {
        let view = AIChatView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        view.snapshot = { _ in nil }
        let feed = Feed()
        view.respond = { _ in AsyncThrowingStream { feed.continuation = $0; $0.yield(.responded) } }
        view.layoutSubtreeIfNeeded()
        view.send("A long one?")
        for _ in 0..<100 where feed.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        try await give(feed, view, paragraphs: 1...40)
        XCTAssertTrue(view.followsAnswer)
        XCTAssertGreaterThan(scrollLimit(view), 300)
        XCTAssertEqual(view.scroll.contentView.bounds.minY, scrollLimit(view), accuracy: 0.5, "At the end as it grows")
        return (view, feed)
    }

    func testAtItsEndTheConversationFollowsTheAnswerScrolledUpItStaysAndBackAtTheEndItFollowsAgain() async throws {
        let (view, feed) = try await followingChat()
        let clip = view.scroll.contentView
        // Scrolled up by hand, it stays where it's put as the answer goes on.
        clip.scroll(to: NSPoint(x: 0, y: scrollLimit(view)-300)); view.scroll.reflectScrolledClipView(clip)
        XCTAssertFalse(view.followsAnswer)
        let read = clip.bounds.minY
        try await give(feed, view, paragraphs: 41...50)
        XCTAssertEqual(clip.bounds.minY, read, accuracy: 0.5, "It stays where it was put")

        // Back at the end, it follows again.
        clip.scroll(to: NSPoint(x: 0, y: scrollLimit(view))); view.scroll.reflectScrolledClipView(clip)
        XCTAssertTrue(view.followsAnswer)
        try await give(feed, view, paragraphs: 51...60)
        XCTAssertEqual(clip.bounds.minY, scrollLimit(view), accuracy: 0.5, "Following again")

        // A wider panel makes the answer shorter, pulling the scroll back: that isn't the user's.
        view.setFrameSize(NSSize(width: 720, height: 800)); view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.followsAnswer)
        try await give(feed, view, paragraphs: 61...65)
        XCTAssertEqual(clip.bounds.minY, scrollLimit(view), accuracy: 0.5)
        feed.continuation?.finish()
        try await answered(view)
    }

    func testAMouseWheelScrollingUpStopsTheFollowingAndBackDownToTheEndPicksItUp() async throws {
        // A scroll view scrolls for a wheel in a window, as the display refreshes.
        try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0, "The display is asleep, so the wheel doesn't scroll.")
        let (view, feed) = try await followingChat()
        let clip = view.scroll.contentView
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        try await wheel(view, by: 40)
        XCTAssertLessThan(clip.bounds.minY, scrollLimit(view)-1, "The wheel scrolled it up")
        XCTAssertFalse(view.followsAnswer)
        try await give(feed, view, paragraphs: 41...45)
        XCTAssertLessThan(clip.bounds.minY, scrollLimit(view)-1)
        for _ in 0..<40 where clip.bounds.minY < scrollLimit(view)-1 { try await wheel(view, by: -40) }
        XCTAssertTrue(view.followsAnswer)
        // Out of the window again, where it follows without a display link.
        window.contentView = nil
        try await give(feed, view, paragraphs: 46...50)
        XCTAssertEqual(clip.bounds.minY, scrollLimit(view), accuracy: 0.5)
        feed.continuation?.finish()
        try await answered(view)
    }

    func testTheRemoveButtonIsItsDiscAloneWithAnEvenRingAndACentredCross() throws {
        let chip = AIChatPageChip(page("Icônes", "https://icones.js.org"), removable: true)
        chip.frame = NSRect(x: 0, y: 0, width: 184, height: 54); chip.layout()
        let button = try XCTUnwrap(chip.removeButton)
        button.layout()
        let middle = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        XCTAssertTrue(button.isOnDisc(middle))
        // Every way to its edge, and no further: not the corners of its square, nor low at its foot.
        for angle in stride(from: 0.0, to: 2*Double.pi, by: Double.pi/8) {
            let inside = NSPoint(x: middle.x+8.9*cos(angle), y: middle.y+8.9*sin(angle))
            let outside = NSPoint(x: middle.x+9.2*cos(angle), y: middle.y+9.2*sin(angle))
            XCTAssertTrue(button.isOnDisc(inside), "\(angle)"); XCTAssertFalse(button.isOnDisc(outside), "\(angle)")
        }
        XCTAssertFalse(button.isOnDisc(NSPoint(x: middle.x+8.5, y: middle.y+8.5)), "A corner of its square")
        // The ring takes a click so it doesn't reach the page, but past it is the chip's.
        let ring = button.convert(NSPoint(x: middle.x, y: middle.y+10), to: chip)
        XCTAssertTrue(button.hitTest(ring) === button)
        XCTAssertNil(button.hitTest(button.convert(NSPoint(x: middle.x+10, y: middle.y+10), to: chip)))
        // The cross, ring and disc share the disc's middle, the cross 5 pt across.
        let layers = try XCTUnwrap(button.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
        XCTAssertEqual(layers.count, 3)
        let boxes = layers.compactMap { $0.path?.boundingBoxOfPath }
        XCTAssertEqual(boxes[0].width, 22, accuracy: 0.001); XCTAssertEqual(boxes[1].width, 18, accuracy: 0.001)
        XCTAssertEqual(boxes[2].width, 5, accuracy: 0.001); XCTAssertEqual(boxes[2].height, 5, accuracy: 0.001)
        for box in boxes { XCTAssertEqual(box.midX, middle.x, accuracy: 0.001); XCTAssertEqual(box.midY, middle.y, accuracy: 0.001) }
        XCTAssertEqual(layers[2].lineWidth, 1.5)

        // In Light, paler than it was but darker than the page; its ring the composer's own colour.
        let light = AIChatColors(.neutral)
        chip.applyColors(light)
        func gray(_ color: NSColor) -> CGFloat { color.usingColorSpace(.sRGB)!.redComponent }
        XCTAssertGreaterThan(gray(light.remove), gray(NSColor(hex: 0xC7C7C7)))
        XCTAssertLessThan(gray(light.remove), 0.92)
        XCTAssertEqual(layers[0].fillColor, light.composer.cgColor)
        XCTAssertEqual(layers[1].fillColor, light.remove.cgColor)
        XCTAssertEqual(light.removeHover, NSColor(hex: 0x171717))
    }

    func testTheComposerHasNoCameraAndItsMicrophoneDictates() throws {
        let composer = AIChatComposer(frame: NSRect(x: 0, y: 0, width: 464, height: 60))
        composer.layoutSubtreeIfNeeded(); composer.layout()
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        let titles = buttons(composer).compactMap { $0.accessibilityLabel() }
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("screenshot") }, "\(titles)")
        XCTAssertTrue(titles.contains("Dictate"))
        // The waveform sits between ⋯ and the microphone, hidden until it listens.
        XCTAssertTrue(composer.waveform.isHidden)
        XCTAssertEqual(composer.dictation.phase, .idle)
    }

    func testAttachedPagesKeepTheirWidthAndScrollAcrossWithTheSidebarsFade() throws {
        let composer = AIChatComposer(frame: NSRect(x: 0, y: 0, width: 464, height: 160))
        func attached(_ count: Int) { composer.setAttachments((0..<count).map { AIChatAttachment(tabID: nil, title: "Page \($0)", url: URL(string: "https://example.com/\($0)"), favicon: nil) }); composer.settle(); composer.layout() }
        attached(2)
        XCTAssertEqual(composer.chips.map(\.frame.width), [AIChatStyle.chipSize.width, AIChatStyle.chipSize.width])
        XCTAssertEqual(composer.chipEdges, .init(top: 0, bottom: 0), "Two fit, so neither end fades")
        XCTAssertNil(composer.chipsScroll.layer?.mask)
        // Four don't fit, but keep their width; the newest is scrolled to, its row fading on the left.
        attached(4)
        XCTAssertEqual(Set(composer.chips.map(\.frame.width)), [AIChatStyle.chipSize.width])
        let clip = composer.chipsScroll.contentView
        XCTAssertEqual(clip.bounds.maxX, composer.chipsView.frame.width, accuracy: 0.5)
        XCTAssertEqual(composer.chipEdges, .init(top: 1, bottom: 0))
        XCTAssertNotNil(composer.chipsScroll.layer?.mask)
        // Scrolled back a little, both ends fade, the left in proportion to how far it's scrolled.
        clip.scroll(to: NSPoint(x: 48, y: 0)); composer.chipsScroll.reflectScrolledClipView(clip)
        XCTAssertEqual(composer.chipEdges, .init(top: 0.5, bottom: 1))
        clip.scroll(to: .zero); composer.chipsScroll.reflectScrolledClipView(clip)
        XCTAssertEqual(composer.chipEdges, .init(top: 0, bottom: 1))
        XCTAssertEqual(composer.chips[0].frame.minX, AIChatStyle.composerChipInset)
    }

    func testPastingPutsTheCopiedTextInAsPlainWords() throws {
        let composer = AIChatComposer(frame: NSRect(x: 0, y: 0, width: 464, height: 100))
        let window = NSWindow(contentRect: composer.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(composer)
        defer { window.close() }
        window.makeFirstResponder(composer.input)
        let board = NSPasteboard.general, saved = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            board.clearContents()
            board.writeObjects(saved.map { pairs in let item = NSPasteboardItem(); pairs.forEach { item.setData($0.1, forType: $0.0) }; return item })
        }
        board.clearContents()
        let bold = NSAttributedString(string: "Copied words", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
        board.writeObjects([bold])
        composer.input.string = "Hi "; composer.input.setSelectedRange(NSRange(location: 3, length: 0))
        composer.input.paste(nil)
        XCTAssertEqual(composer.text, "Hi Copied words")
        let font = composer.input.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, AIChatStyle.inputFontSize, "In the composer's own style")
        for paste in [#selector(NSTextView.pasteAsRichText(_:)), #selector(NSTextView.pasteAsPlainText(_:)), Selector(("pasteAndMatchStyle:"))] {
            composer.input.string = ""
            composer.input.perform(paste, with: nil)
            XCTAssertEqual(composer.text, "Copied words", "\(paste)")
        }
    }

    func testDictatedWordsGoInAtTheCursorOrOverTheSelection() throws {
        let composer = AIChatComposer(frame: NSRect(x: 0, y: 0, width: 464, height: 100))
        // In a window, which gives the text its undo.
        let window = NSWindow(contentRect: composer.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(composer)
        defer { window.close() }
        // Each dictation arrives in an event of its own, as undo groups them.
        func dictate(_ words: String) { composer.insertDictated(words); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        dictate("Hello there.")
        XCTAssertEqual(composer.text, "Hello there.")
        dictate("How are you?")
        XCTAssertEqual(composer.text, "Hello there. How are you?")
        composer.input.setSelectedRange(NSRange(location: 6, length: 5))
        dictate("again")
        XCTAssertEqual(composer.text, "Hello again. How are you?")
        composer.input.setSelectedRange(NSRange(location: 0, length: 0))
        dictate("Well")
        XCTAssertEqual(composer.text, "Well Hello again. How are you?")
        dictate("  ")
        XCTAssertEqual(composer.text, "Well Hello again. How are you?", "Nothing said, nothing goes in")
        XCTAssertTrue(window.firstResponder === composer.input, "The cursor stays in the text")
        // One undo takes the last words back out, and only them.
        composer.input.undoManager?.undo()
        XCTAssertEqual(composer.text, "Hello again. How are you?")
    }

    func testTheWaveformGrowsWithTheVoiceDriftsLeftAndThenSweepsWhileTranscribing() throws {
        let waveform = AIChatWaveform(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        waveform.start()
        XCTAssertFalse(waveform.isHidden)
        XCTAssertEqual(waveform.heights.count, 42)
        XCTAssertTrue(waveform.heights.allSatisfy { $0 == AIChatWaveform.dot }, "A line of resting dots")
        // Loud for half a second, then quiet for half a second, a frame at a time.
        for frame in 0..<60 {
            waveform.hear(frame < 30 ? 1 : 0)
            waveform.advance(1/60)
        }
        let tallest = waveform.heights.max() ?? 0
        XCTAssertGreaterThan(tallest, AIChatWaveform.tallest*0.9, "The loud dots grew")
        let loud = try XCTUnwrap(waveform.heights.firstIndex { $0 > AIChatWaveform.tallest*0.9 })
        // The newest are quiet, by the microphone at the right; the loud ones have drifted left of them.
        XCTAssertLessThan(waveform.heights.last ?? 0, AIChatWaveform.dot+1)
        XCTAssertLessThan(waveform.x(of: loud), 240-25)
        let before = waveform.x(of: loud)
        waveform.advance(0.05)
        XCTAssertLessThan(waveform.x(of: loud-0), before+0.001)
        // Growing smoothly: a dot heard once isn't at its height a frame later.
        let fresh = AIChatWaveform(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        fresh.start(); fresh.advance(0.11); fresh.hear(1); fresh.advance(1/60)
        let newest = fresh.heights.last ?? 0
        XCTAssertGreaterThan(newest, AIChatWaveform.dot); XCTAssertLessThan(newest, AIChatWaveform.tallest*0.6)

        // Transcribing: the line comes to rest, and one wave sweeps to and fro over the middle.
        waveform.transcribe()
        XCTAssertEqual(waveform.mode, .transcribing)
        waveform.hear(1)
        var peaks: [CGFloat] = []
        for frame in 0..<180 {
            waveform.advance(1/60)
            if frame >= 60, frame % 15 == 0, let peak = waveform.heights.indices.max(by: { waveform.heights[$0] < waveform.heights[$1] }) {
                peaks.append(waveform.x(of: peak))
            }
        }
        let raised = waveform.heights.filter { $0 > AIChatWaveform.dot+2 }.count
        XCTAssertGreaterThan(raised, 1); XCTAssertLessThan(raised, 12, "One wave, not the voice's dots")
        XCTAssertLessThan(waveform.heights.max() ?? 0, AIChatWaveform.dot+AIChatWaveform.waveHeight+0.5)
        let span = (peaks.max() ?? 0)-(peaks.min() ?? 0)
        XCTAssertGreaterThan(span, 240*0.3, "It sweeps both ways: \(peaks)")
        XCTAssertTrue(peaks.allSatisfy { $0 > 240*0.15 && $0 < 240*0.85 }, "Over the middle: \(peaks)")
    }

    func testAMiddleClickTakesAnAttachedPageOff() throws {
        let view = AIChatView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        let icones = page("Icônes", "https://icones.js.org"), python = page("Python", "https://www.python.org")
        view.openPages = { [icones, python] }
        view.setCurrentPage(icones)
        let item = try XCTUnwrap(view.composer.plusButton.makeMenu?()?.items.first { $0.title == "Python" })
        (item.target as? MenuAction)?.invoke()
        XCTAssertEqual(view.composer.attachments.map(\.title), ["Python", "Icônes"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.composer.frame = NSRect(x: 8, y: 8, width: 464, height: 170)
        view.composer.layoutSubtreeIfNeeded(); view.composer.layout()

        // A real middle button's event, as a mouse sends: AppKit's own events can't say which button.
        func middle(_ type: NSEvent.EventType, on chip: NSView, at point: NSPoint) -> NSEvent? {
            let location = chip.convert(point, to: nil)
            guard let base = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
                  let event = base.cgEvent?.copy() else { return nil }
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
            guard let middle = NSEvent(cgEvent: event) else { return nil }
            XCTAssertEqual(middle.locationInWindow.x, location.x, accuracy: 0.5); XCTAssertEqual(middle.locationInWindow.y, location.y, accuracy: 0.5)
            return middle
        }
        // As AppKit routes them: the press to what's under the pointer, going up to the chip from
        // its title or tile, and the release to whatever took the press, wherever it's let go.
        func click(_ chip: NSView, at point: NSPoint, releaseOn other: NSView? = nil, releaseAt: NSPoint? = nil) throws {
            let down = try XCTUnwrap(middle(.otherMouseDown, on: chip, at: point))
            XCTAssertEqual(down.buttonNumber, 2, "The middle button")
            let pressed = try XCTUnwrap(window.contentView?.hitTest(down.locationInWindow))
            XCTAssertTrue(pressed === chip || pressed.isDescendant(of: chip))
            pressed.otherMouseDown(with: down)
            pressed.otherMouseUp(with: try XCTUnwrap(middle(.otherMouseUp, on: other ?? chip, at: releaseAt ?? point)))
        }
        // Let go on another chip, nothing comes off.
        let first = view.composer.chips[0], second = view.composer.chips[1]
        try click(first, at: NSPoint(x: 60, y: 27), releaseOn: second, releaseAt: NSPoint(x: 60, y: 27))
        XCTAssertEqual(view.composer.attachments.map(\.title), ["Python", "Icônes"])
        // Pressed and let go on its title, it comes off.
        try click(first, at: NSPoint(x: 60, y: 18))
        XCTAssertEqual(view.composer.attachments.map(\.title), ["Icônes"])
        // On its favicon's tile too.
        try click(try XCTUnwrap(view.composer.chips.first), at: NSPoint(x: 20, y: 27))
        XCTAssertEqual(view.composer.attachments.map(\.title), [])
    }

    // MARK: Mentions

    private func favicon(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill(); return true
        }
    }
    /// A chat in a window, which gives its text the keyboard and undo, with three open pages.
    private func mentionChat() -> (AIChatView, NSWindow, python: AIChatAttachment, icones: AIChatAttachment, docs: AIChatAttachment) {
        let view = AIChatView(frame: NSRect(x: 0, y: 0, width: 480, height: 800))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = view
        let python = AIChatAttachment(tabID: UUID(), title: "Welcome to Python.org", url: URL(string: "https://www.python.org"), favicon: favicon(NSColor(hex: 0x3776AB)))
        let icones = AIChatAttachment(tabID: UUID(), title: "Icônes", url: URL(string: "https://icones.js.org"), favicon: favicon(NSColor(hex: 0xE8A33D)))
        let docs = AIChatAttachment(tabID: UUID(), title: "Docs", url: URL(string: "https://docs.example.com"), favicon: nil)
        view.openPages = { [python, icones, docs] }
        view.setCurrentPage(icones)
        view.layoutSubtreeIfNeeded()
        view.composer.focus()
        return (view, window, python, icones, docs)
    }
    /// Typed a key at a time, as the keyboard does.
    private func type(_ text: String, in composer: AIChatComposer) {
        for character in text { composer.input.insertText(String(character), replacementRange: composer.input.selectedRange()) }
    }

    func testTypingAtOffersTheOpenPagesNarrowingAsItGoesAndTabOrReturnMentionsOne() throws {
        let (view, window, python, icones, docs) = mentionChat()
        defer { window.close() }
        let composer = view.composer
        type("Compare ", in: composer)
        XCTAssertFalse(view.mentionMenu.isShown)
        type("@", in: composer)
        XCTAssertTrue(view.mentionMenu.isShown, "Over the @ as it's typed")
        XCTAssertEqual(view.mentionMenu.pages, [icones, python, docs], "Every open page, the one in front first")
        // Just above the @'s line, its titles starting where the @ does.
        let menu = view.mentionMenu.frame, at = view.mentionAnchor
        XCTAssertEqual(menu.maxY, at.minY-AIChatMentionMenu.gap, accuracy: 1)
        XCTAssertGreaterThan(menu.maxY, composer.frame.minY, "Over the composer's top, not above all of it")
        XCTAssertEqual(menu.minX+AIChatMentionMenu.padding+AIChatMentionMenu.Row.inset, at.minX, accuracy: 1, "Its favicons start where the @ does")
        type("py", in: composer)
        XCTAssertEqual(view.mentionMenu.pages, [python])
        // Tab picks: the @ and what followed it become the mention, and its page is attached.
        composer.input.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertFalse(view.mentionMenu.isShown)
        XCTAssertEqual(composer.mentions, [python])
        XCTAssertEqual(composer.text, "Compare Welcome to Python.org ")
        XCTAssertTrue(composer.attachments.contains(python))
        // Return picks too, after choosing with the arrows.
        type("and @", in: composer)
        composer.input.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(view.mentionMenu.selected, 1)
        composer.input.doCommand(by: #selector(NSResponder.moveUp(_:)))
        type("doc", in: composer)
        composer.input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(composer.mentions, [python, docs])
        XCTAssertTrue(view.turns.isEmpty, "Return picked; it didn't send")
        // An @ in the middle of a word, as in an address, isn't a mention.
        type("mail me@", in: composer)
        XCTAssertFalse(view.mentionMenu.isShown)
        // Nothing matching, the menu goes, and the @ stays a word.
        type(" @zzz", in: composer)
        XCTAssertFalse(view.mentionMenu.isShown)
        composer.input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(composer.text.hasSuffix("@zzz"))
    }

    func testAMentionIsDeletedWholeEitherWayAndItsPageComesOffWithIt() throws {
        let (view, window, python, _, docs) = mentionChat()
        defer { window.close() }
        let composer = view.composer
        type("Read @py", in: composer); composer.input.doCommand(by: #selector(NSResponder.insertTab(_:)))
        type("and @doc", in: composer); composer.input.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(composer.mentions, [python, docs])
        XCTAssertTrue(composer.attachments.contains(docs))
        // Delete, past the space after it: one press takes the whole mention.
        composer.input.deleteBackward(nil); composer.input.deleteBackward(nil)
        XCTAssertEqual(composer.mentions, [python])
        XCTAssertFalse(composer.attachments.contains(docs), "Mentioned only, it comes off with its mention")
        // Forward Delete, with the cursor in front of it, in a key press of its own, as undo groups them.
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        composer.input.setSelectedRange(NSRange(location: 5, length: 0))
        composer.input.deleteForward(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(composer.mentions, [])
        XCTAssertFalse(composer.attachments.contains(python))
        // Undo brings it back as itself, attached again.
        composer.input.undoManager?.undo()
        XCTAssertEqual(composer.mentions, [python])
        XCTAssertTrue(composer.attachments.contains(python))
    }

    func testTakingOffAMentionedPageLeavesItsTitleAsWords() throws {
        let (view, window, python, _, _) = mentionChat()
        defer { window.close() }
        let composer = view.composer
        type("Summarise @py", in: composer); composer.input.doCommand(by: #selector(NSResponder.insertTab(_:)))
        let chip = try XCTUnwrap(composer.chips.first { $0.attachment == python })
        chip.onRemove?()
        XCTAssertEqual(composer.mentions, [])
        XCTAssertEqual(composer.text, "Summarise Welcome to Python.org ")
        XCTAssertFalse(composer.attachments.contains(python))
    }

    func testAQuestionWithMentionsReachesTheModelAsReferencesInTheOrderWritten() throws {
        let (view, window, python, icones, _) = mentionChat()
        defer { window.close() }
        let composer = view.composer
        type("  Compare @py", in: composer); composer.input.doCommand(by: #selector(NSResponder.insertTab(_:)))
        type("with @ico", in: composer); composer.input.doCommand(by: #selector(NSResponder.insertTab(_:)))
        type("  ", in: composer)
        // Copied, a mention is its title.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RiseMentionTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        composer.input.selectAll(nil)
        XCTAssertTrue(composer.input.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "  Compare Welcome to Python.org with Icônes   ")
        composer.input.setSelectedRange(NSRange(location: composer.input.string.utf16.count, length: 0))

        composer.sendButton.action?()
        let turn = try XCTUnwrap(view.turns.last)
        XCTAssertEqual(turn.parts, [.text("Compare "), .mention(python), .text(" with "), .mention(icones)])
        XCTAssertEqual(turn.question, "Compare Welcome to Python.org with Icônes")
        XCTAssertEqual(turn.prompt, "Compare @[Welcome to Python.org](https://www.python.org) with @[Icônes](https://icones.js.org)")
        XCTAssertEqual(turn.mentions, [python, icones])
        XCTAssertTrue(turn.pages.contains(python) && turn.pages.contains(icones))
        XCTAssertTrue(AIChatPrompt.instructions.contains("@[title](URL)"))
        var answered = turn
        answered.snapshots = [PageAssistant.Page(title: "Welcome to Python.org", url: "https://www.python.org", selection: "", text: "Python.")]
        XCTAssertTrue(AIChatPrompt.content(answered).hasSuffix("</page>\n\n"+turn.prompt))
        // Its bubble shows the mentions as pills too.
        let bubble = AIChatBubble(turn.parts)
        bubble.applyColors(AIChatColors(.neutral))
        XCTAssertEqual(bubble.textView.textStorage?.mentions.map(\.page), [python, icones])
        // The composer is empty again, with nothing mentioned.
        XCTAssertEqual(composer.mentions, []); XCTAssertEqual(composer.text, "")
        // A bracket in a title can't end its reference early.
        let odd = AIChatAttachment(tabID: nil, title: "A [draft]", url: URL(string: "https://example.com"), favicon: nil)
        XCTAssertEqual(AIChatQuestionPart.reference(to: odd), "@[A (draft)](https://example.com)")
    }

    func testAMentionsPillIsWashedInItsFaviconsColourAsAPinnedTabIs() throws {
        let colors = AIChatColors(.neutral)
        let blue = favicon(NSColor(hex: 0x3776AB))
        let page = AIChatAttachment(tabID: nil, title: "A very long title that goes on and on past what a pill shows", url: URL(string: "https://example.com"), favicon: blue)
        let cell = AIChatMentionCell(page: page, style: .composer(colors))
        let accent = try XCTUnwrap(FaviconColor.dominant(blue))
        XCTAssertEqual(cell.fill, PinnedLayout.tint(accent, theme: .neutral, selected: true, hovered: false))
        // Without a favicon, a grey.
        let plain = AIChatMentionCell(page: AIChatAttachment(tabID: nil, title: "Docs", url: nil, favicon: nil), style: .composer(colors))
        XCTAssertEqual(plain.fill, PinnedLayout.tint(nil, theme: .neutral, selected: true, hovered: false))
        // A long title is cut short with an ellipsis, the pill ending just after it.
        XCTAssertTrue(cell.shownTitle.hasSuffix("…"))
        XCTAssertLessThanOrEqual((cell.shownTitle as NSString).size(withAttributes: [.font: cell.titleFont]).width, AIChatMentionCell.maximumTextWidth)
        XCTAssertLessThan(cell.cellSize().width, AIChatMentionCell.maximumTextWidth+40)
        // It takes no more of its line than the text does, so the line doesn't move.
        let font = AIChatStyle.font(AIChatStyle.inputFontSize)
        XCTAssertLessThanOrEqual(cell.cellBaselineOffset().y+cell.layoutHeight, font.ascender)
        XCTAssertGreaterThanOrEqual(cell.cellBaselineOffset().y, font.descender)
    }

    // MARK: Buttons

    func testTheComposersButtonsHaveRisesHoverHintsNotTooltips() throws {
        let composer = AIChatComposer(frame: NSRect(x: 0, y: 0, width: 464, height: 100))
        composer.applyColors(AIChatColors(.neutral))
        for (button, text, shortcut) in [(composer.plusButton as ChromeButton, "Add pages", "@"), (composer.moreButton, "More", ""),
                                         (composer.micButton, "Dictate", "Hold to talk")] {
            XCTAssertEqual(button.hoverHint?.text, text); XCTAssertEqual(button.hoverHint?.shortcut, shortcut)
            XCTAssertNil(button.toolTip)
        }
        XCTAssertEqual(composer.sendButton.hoverHint.text, "Send"); XCTAssertEqual(composer.sendButton.hoverHint.shortcut, "↩")
        composer.isAnswering = true
        XCTAssertEqual(composer.sendButton.hoverHint.text, "Stop answering")
    }

    func testTheMicrophoneBecomesSolarsStopWithItsSquareInRedAndHoldingTalks() throws {
        let composer = AIChatComposer(frame: NSRect(x: 0, y: 0, width: 464, height: 100))
        XCTAssertTrue(composer.micButton.glyphImage === AIChatMicButton.micImage)
        let ring = NSColor(hex: 0xBCBCBC), red = NSColor(hex: 0xFF3B30)
        let stop = AIChatMicButton.stopImage(ring: ring, red: red)
        XCTAssertEqual(stop.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(stop.isTemplate)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        stop.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18)); NSGraphicsContext.restoreGraphicsState()
        func color(_ x: Int, _ y: Int) -> NSColor { bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
        // The square's middle is red; the ring, 7.5 pt out from the middle, is the microphone's grey.
        XCTAssertEqual(color(36, 36).redComponent, 1, accuracy: 0.05); XCTAssertLessThan(color(36, 36).greenComponent, 0.35)
        XCTAssertEqual(color(36, 6).alphaComponent, 1, accuracy: 0.05); XCTAssertEqual(color(36, 6).redComponent, 0xBC/255, accuracy: 0.06)
        // Between them, nothing.
        XCTAssertLessThan(color(36, 14).alphaComponent, 0.1)
        // Held to talk, letting go stops it; a tap, or the press that stopped it, doesn't.
        XCTAssertTrue(AIChatMicButton.releaseStops(startedByPress: true, held: 0.6))
        XCTAssertFalse(AIChatMicButton.releaseStops(startedByPress: true, held: 0.15))
        XCTAssertFalse(AIChatMicButton.releaseStops(startedByPress: false, held: 2))
    }
}
