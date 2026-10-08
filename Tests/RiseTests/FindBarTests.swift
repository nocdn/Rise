import WebKit
import XCTest
import AppKit
@testable import Rise

@MainActor final class FindBarTests: XCTestCase {
    /// Motion's `{ type: "spring", bounce: 0, duration: 0.2 }` is critically damped with
    /// ω ≈ 46.2 rad/s, so it has all but settled at 0.2 s and never overshoots.
    func testAssistantSeesCodeThatGitHubDrawsFromAttributes() async throws {
        // Like GitHub's file view: the lines are empty spans painted from an attribute,
        // under a transparent aria-readonly text area, inside display: contents wrappers.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString("""
        <style>[data-code-text]::before{content:attr(data-code-text)} textarea{color:transparent;background:none}</style>
        <h1>1-4</h1>
        <div style="display:contents"><div style="display:contents">
        <textarea aria-readonly="true">int main ()\n{\n    printf("%6.1f", celsius);\n}</textarea></div></div>
        <div style="display:contents"><p>Wrapped paragraph</p></div>
        <div><span data-code-text="int main ()"></span></div><div><span data-code-text="printf"></span></div>
        <textarea>a draft comment</textarea>
        """, baseURL: URL(string: "https://github.com/a/b/blob/master/1-4"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }
        let page = try await PageAssistant.snapshot(of: web)
        XCTAssertTrue(page.text.contains("1-4"), page.text)
        XCTAssertTrue(page.text.contains("printf(\"%6.1f\", celsius);"), page.text)
        XCTAssertTrue(page.text.contains("Wrapped paragraph"), page.text)
        XCTAssertFalse(page.text.contains("a draft comment"), page.text)
    }

    func testSwapSpringMatchesMotionDuration() {
        let omega = 2 * .pi/FindMotion.swapResponse
        XCTAssertEqual(omega, 46.2, accuracy: 0.2)
        var spring = MotionSpring(0); spring.configure(response: FindMotion.swapResponse, bounce: 0); spring.target = 1
        var peak = 0.0
        for _ in 0..<200 { spring.step(0.001); peak = max(peak, spring.value) }
        XCTAssertGreaterThan(spring.value, 0.998)
        XCTAssertLessThanOrEqual(peak, 1.0001)
    }
    func testPresenceEntersFromAboveAndLeavesDownward() {
        let view = NSView()
        var item = PresenceItem(view, shown: false)
        item.set(true); item.render(at: NSRect(x: 0, y: 10, width: 10, height: 10))
        XCTAssertEqual(view.frame.minY, 10-FindMotion.swapTravel, accuracy: 0.01)
        XCTAssertEqual(view.alphaValue, 0, accuracy: 0.01)
        for _ in 0..<40 { item.step(0.01) }
        item.render(at: NSRect(x: 0, y: 10, width: 10, height: 10))
        XCTAssertEqual(view.frame.minY, 10, accuracy: 0.05); XCTAssertEqual(view.alphaValue, 1, accuracy: 0.01)
        item.set(false); item.step(0.05); item.render(at: NSRect(x: 0, y: 10, width: 10, height: 10))
        XCTAssertGreaterThan(view.frame.minY, 10); XCTAssertLessThan(view.alphaValue, 1)
    }
    func testTabTogglesModeAndEnterAsks() {
        let bar = FindBar()
        var asked: String?
        bar.answer = { question, _ in asked = question; return AsyncThrowingStream { _ in } }
        _ = bar.control(bar.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(bar.mode, .ask)
        bar.input.stringValue = "When is this released?"
        _ = bar.control(bar.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(asked, "When is this released?")
        XCTAssertTrue(bar.badge.isThinking)
        _ = bar.control(bar.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(bar.mode, .find)
    }
    func testFirstResponseShowsDoneAndReplacementCancelsItsDismissal() async throws {
        let bar = FindBar()
        var streams: [AsyncThrowingStream<String, Error>.Continuation] = []
        bar.answer = { _, _ in AsyncThrowingStream { streams.append($0) } }
        bar.toggleMode()
        bar.input.stringValue = "First question"
        bar.send()
        streams[0].yield("") // Snippet metadata arrives before visible answer text.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(bar.badge.caption, .done)
        XCTAssertTrue(bar.conversation.isEmpty)

        bar.input.stringValue = "Second question"
        bar.send()
        XCTAssertEqual(bar.badge.caption, .thinking)
        streams[0].yield("Cancelled answer")
        try await Task.sleep(for: .seconds(FindMotion.doneHold+0.1))
        XCTAssertEqual(bar.badge.caption, .thinking)
        XCTAssertTrue(bar.conversation.isEmpty)
        streams[1].yield("Current answer")
        streams[1].finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(bar.badge.caption, .done)
        XCTAssertEqual(bar.conversation.last?.answer, "Current answer")
        bar.closeInstantly()
    }
    func testAnswerCloseDismissesAndCancelsRemainingStream() async throws {
        let bar = FindBar()
        var stream: AsyncThrowingStream<String, Error>.Continuation!
        bar.dismiss = { bar.hide() }
        bar.present()
        bar.answer = { _, _ in AsyncThrowingStream { stream = $0 } }
        bar.toggleMode(); bar.input.stringValue = "Question"; bar.send()
        stream.yield("Partial answer")
        try await Task.sleep(for: .seconds(FindMotion.doneHold+0.1))
        XCTAssertEqual(bar.badge.caption, .close)
        XCTAssertTrue(bar.isAnswering)
        bar.badge.closeButton.performClick(nil)
        stream.yield("Late answer"); stream.finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(bar.isPresented)
        XCTAssertEqual(bar.mode, .ask)
        XCTAssertEqual(bar.input.stringValue, "Question")
        XCTAssertTrue(bar.conversation.isEmpty)
        XCTAssertFalse(bar.isAnswering)
        bar.present()
        XCTAssertEqual(bar.mode, .find)
        XCTAssertEqual(bar.badge.caption, .send)
        bar.regenerate()
        XCTAssertFalse(bar.isAnswering)
        bar.closeInstantly()
    }
    func testCommandFindRefocusesAndSelectsTheQuestionWithoutDismissingItsAnswer() async throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false)
        defer {
            browser.findBars.values.forEach { $0.discard() }; browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: session.deletingLastPathComponent())
        }
        let tab = browser.addTab()
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        browser.showWindow(nil); browser.showFind()
        let bar = browser.findBar, question = "Tell me about café 🐈"
        bar.answer = { _, _ in AsyncThrowingStream { $0.yield("The completed answer."); $0.finish() } }
        bar.toggleMode(); bar.input.stringValue = question; bar.send()
        let deadline = Date().addingTimeInterval(5)
        while bar.isAnswering && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(bar.isAnswering)
        browser.window?.makeFirstResponder(tab.webView)

        browser.showFind()
        XCTAssertTrue(bar.isPresented)
        XCTAssertEqual(bar.mode, .ask)
        XCTAssertEqual(bar.input.stringValue, question)
        XCTAssertEqual(bar.conversation.count, 1)
        XCTAssertEqual(bar.conversation.last?.answer, "The completed answer.")
        let editor = try XCTUnwrap(bar.input.currentEditor() as? NSTextView)
        XCTAssertTrue(browser.window?.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: question.utf16.count))
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        browser.showFind()
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: question.utf16.count))
        XCTAssertTrue(bar.isPresented)

        bar.handleEscape()
        XCTAssertFalse(bar.isPresented)
        XCTAssertTrue(browser.window?.firstResponder === tab.webView)
    }
    func testInputTokenMenuWaitsForCompletionAndDoesNotReuseReplacedOrFailedUsage() async throws {
        let bar = FindBar()
        defer { bar.discard() }
        var streams: [AsyncThrowingStream<String, Error>.Continuation] = []
        bar.answer = { _, _ in AsyncThrowingStream { streams.append($0) } }
        bar.present(); bar.toggleMode(); bar.input.stringValue = "Question"; bar.send()
        let firstGeneration = bar.answerGeneration
        bar.recordInputTokens(2452, for: firstGeneration)
        streams[0].yield("First answer")
        XCTAssertEqual(bar.makeMoreMenu().items.map(\.title), ["Regenerate", "Copy"], "Usage stays out of the menu while streaming")
        streams[0].finish()
        try await Task.sleep(for: .milliseconds(20))
        let menu = bar.makeMoreMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Regenerate", "Copy", "", "2,452 tok"])
        XCTAssertFalse(try XCTUnwrap(menu.items.last).isEnabled)

        bar.regenerate()
        XCTAssertNil(bar.inputTokenCount)
        bar.recordInputTokens(9999, for: firstGeneration)
        XCTAssertNil(bar.inputTokenCount, "A cancelled request cannot set the new answer's usage")
        bar.recordInputTokens(824, for: bar.answerGeneration)
        streams[1].yield("Replacement answer"); streams[1].finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(bar.makeMoreMenu().items.last?.title, "824 tok")

        bar.regenerate()
        bar.recordInputTokens(1000, for: bar.answerGeneration)
        streams[2].finish(throwing: URLError(.networkConnectionLost))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(bar.inputTokenCount)
        XCTAssertEqual(bar.makeMoreMenu().items.map(\.title), ["Regenerate", "Copy"])
        bar.hide(); bar.present()
        XCTAssertNil(bar.inputTokenCount)
    }
    func testUnmatchedSearchSwitchesToAskBeforeItOutgrowsTheField() async throws {
        let bar = FindBar()
        bar.find = { _, _ in PageFind.Matches(count: 0, index: -1) }
        func type(_ text: String) async throws {
            bar.input.stringValue = text
            bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.input))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await type("missing words")
        XCTAssertEqual(bar.mode, .find, "A short search stays a search")
        try await type("what does this page say about the release")
        XCTAssertEqual(bar.mode, .ask)
        XCTAssertEqual(bar.input.stringValue, "what does this page say about the release")

        bar.toggleMode()
        try await type("what does this page say about the release date")
        XCTAssertEqual(bar.mode, .find, "Going back to Find keeps it a search")
        try await type("")
        try await type("another long question that the page never mentions")
        XCTAssertEqual(bar.mode, .ask, "Clearing the field lets a new search switch again")
    }
    func testEmptyEnterAndEscapeKeepAnUnsentDraft() {
        let bar = FindBar()
        var dismissals = 0
        bar.dismiss = { dismissals += 1 }
        _ = bar.control(bar.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(bar.mode, .ask)
        XCTAssertFalse(bar.hasSubmittedQuestion)
        bar.input.stringValue = "Unsent question"
        _ = bar.control(bar.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(bar.mode, .find)
        XCTAssertEqual(bar.input.stringValue, "Unsent question")
        XCTAssertEqual(dismissals, 0)
        bar.handleEscape()
        XCTAssertEqual(dismissals, 1)
    }
    func testEscapeDismissesAfterSubmittingEvenWhileStreaming() async throws {
        let bar = FindBar()
        var stream: AsyncThrowingStream<String, Error>.Continuation!
        var dismissals = 0
        bar.dismiss = { dismissals += 1 }
        bar.answer = { _, _ in AsyncThrowingStream { stream = $0 } }
        bar.toggleMode(); bar.input.stringValue = "Question"; bar.send()
        XCTAssertTrue(bar.hasSubmittedQuestion)
        bar.handleEscape()
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(bar.mode, .ask)
        stream.yield("Answer"); stream.finish()
        try await Task.sleep(for: .milliseconds(20))
        bar.handleEscape()
        XCTAssertEqual(dismissals, 2)
        bar.present(); bar.toggleMode(); bar.handleEscape()
        XCTAssertEqual(bar.mode, .find)
        XCTAssertEqual(dismissals, 2)
        bar.closeInstantly()
    }
    func testHiddenAnswerCloseDoesNotKeepStaleHoverBackground() {
        let badge = SendBadge()
        badge.caption = .close; badge.settle()
        badge.closeButton.hover = true
        badge.closeButton.layer?.backgroundColor = badge.closeButton.hoverColor.cgColor
        badge.renderContents()
        XCTAssertFalse(badge.closeButton.hover)
        XCTAssertEqual(badge.closeButton.layer?.backgroundColor?.alpha, 0)
    }
    func testStreamHoldsBackOpenMarkdownAndPlaysWordsOutWithAFadingHighlight() {
        var stream = TokenStream()
        stream.base = OKLab(NSColor.black)
        stream.receive("It ships **March 3")
        XCTAssertEqual(stream.text, "It ships", "Words wait until they're whole and their Markdown has closed")
        stream.place(in: "It ships", at: 0)
        XCTAssertFalse(stream.step(at: 0.015))
        XCTAssertEqual(stream.hiddenFrom, 0, "Laid-out words stay hidden until the brief initial delay")
        XCTAssertTrue(stream.step(at: 0.5))
        XCTAssertNil(stream.hiddenFrom)
        let tints = stream.tints
        XCTAssertEqual(tints.map(\.range), [NSRange(location: 2, length: 6), NSRange(location: 0, length: 2)])
        XCTAssertEqual(tints[0].color, TokenMotion.highlight(0))
        XCTAssertEqual(tints[1].color.l, TokenMotion.highlight(1).l, accuracy: 0.0001)
        XCTAssertFalse(stream.needsFrames, "A held highlight needs no frames")

        stream.receive("It ships **March 3** with"); stream.finish()
        XCTAssertEqual(stream.text, "It ships **March 3** with")
        stream.place(in: "It ships March 3 with", at: 0.6)
        XCTAssertFalse(stream.step(at: 0.6))
        XCTAssertEqual(stream.hiddenFrom, 8)
        XCTAssertTrue(stream.step(at: 2))
        _ = stream.step(at: 2+TokenMotion.colorTransition)
        XCTAssertTrue(stream.tints.isEmpty, "Every word settles into the text color once the answer is done")
    }
    func testStyledAnswerRendersInlineMarkdown() {
        let text = FindBar.styled("It ships **March 3** with `rise`.", color: .black)
        XCTAssertEqual(text.string, "It ships March 3 with rise.")
        let bold = text.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }
    func testShortBurstStillRevealsGraduallyAfterTheModelFinishes() {
        var stream = TokenStream()
        let answer = "He currently works at Cloudflare and previously interned at Objective."
        stream.receive(answer); stream.finish(); stream.place(in: answer as NSString, at: 0)
        _ = stream.step(at: TokenMotion.lead+0.1)
        XCTAssertTrue(stream.isRevealing, "A short, completed response must not flash all its words at once")
        XCTAssertNotNil(stream.hiddenFrom)
        _ = stream.step(at: 1)
        XCTAssertFalse(stream.isRevealing)
        XCTAssertFalse(stream.needsFrames)
    }
    func testFirstWordStartsPromptlyWithoutRevealingTheRestOfTheBurst() {
        var stream = TokenStream()
        let answer = "First word followed by the rest of the answer."
        stream.receive(answer); stream.finish(); stream.place(in: answer as NSString, at: 1)
        XCTAssertFalse(stream.step(at: 1.015))
        XCTAssertTrue(stream.step(at: 1.05), "The first word should begin within 50 ms of receiving displayable text")
        XCTAssertEqual(stream.newest, NSRange(location: 0, length: 5))
        XCTAssertNotNil(stream.hiddenFrom, "The remaining words retain their gradual cadence")
        XCTAssertTrue(stream.tints.contains { $0.color.alpha > 0 }, "The first word is visibly fading in")
    }
    func testRapidChunksAndBufferCatchUpNeverExceedTheWordCadence() {
        var stream = TokenStream()
        var answer = ""
        for (index, word) in ["He", "currently", "works", "at", "Cloudflare", "and", "previously", "interned", "at", "Objective."].enumerated() {
            answer += word+" "
            stream.receive(answer); stream.place(in: answer as NSString, at: Double(index)*0.001)
        }
        stream.finish(); stream.place(in: answer as NSString, at: 0.01)
        var appearances: [Double] = []
        for tick in 0..<1000 {
            let time = Double(tick)*0.001
            if stream.step(at: time) { appearances.append(time) }
        }
        XCTAssertEqual(appearances.count, 10, "Each word should have its own reveal rather than batching into one frame")
        for (first, next) in zip(appearances, appearances.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next-first, 1/TokenMotion.fastest-0.001)
        }
    }
    func testAnswerGrowsThroughEightRenderedLinesThenScrollsAndResetsForAShortAnswer() async throws {
        let bar = FindBar(); bar.frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        bar.present(); bar.toggleMode(); bar.input.stringValue = "Question"
        var continuation: AsyncThrowingStream<String, Error>.Continuation!
        bar.answer = { _, _ in AsyncThrowingStream { continuation = $0 } }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        let scroll = try XCTUnwrap(descendants(bar).compactMap { $0 as? NSScrollView }.first)
        func answer(_ text: String) async throws {
            bar.send(); continuation.yield(text); continuation.finish()
            try await Task.sleep(for: .milliseconds(20)); bar.layoutSubtreeIfNeeded()
        }
        try await answer((1...8).map { "Line \($0)" }.joined(separator: "\n"))
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertEqual(scroll.verticalScrollElasticity, .none, "Short answers should not bounce or scroll")
        let eightLineHeight = scroll.frame.height
        try await answer((1...12).map { "Line \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertEqual(scroll.frame.height, eightLineHeight, accuracy: 2, "At most the trailing line gap differs at the eight-line boundary")
        XCTAssertEqual(scroll.verticalScrollElasticity, .automatic)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        text.scrollToBeginningOfDocument(nil)
        text.scrollToEndOfDocument(nil)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The bottom of a long answer remains reachable")
        try await answer("A short replacement answer.")
        XCTAssertFalse(scroll.hasVerticalScroller)
        XCTAssertEqual(scroll.verticalScrollElasticity, .none)
        XCTAssertLessThan(scroll.frame.height, eightLineHeight)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
        try await answer(String(repeating: "This long paragraph wraps naturally into multiple lines. ", count: 20))
        XCTAssertTrue(scroll.hasVerticalScroller, "Wrapped lines count even without explicit newlines")
        XCTAssertEqual(scroll.frame.height, eightLineHeight, accuracy: 2)
        bar.closeInstantly()
    }

    func testShimmerOnALongQuestionStaysInsideTheField() throws {
        _ = NSApplication.shared
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let field = NSTextField(string: String(repeating: "what is happening in this very big merge request? ", count: 3))
        field.isBordered = false; field.drawsBackground = false; field.font = .systemFont(ofSize: 13)
        field.frame = NSRect(x: 10, y: 6, width: 160, height: 18)
        let shimmer = InputShimmer(); shimmer.field = field; shimmer.bandColor = .black
        container.addSubview(field); container.addSubview(shimmer)
        shimmer.frame = field.frame.insetBy(dx: 0, dy: -3)
        shimmer.start(); defer { shimmer.cancel() }
        field.isHidden = true // Only the band shows in the image.
        func inked(_ progress: CGFloat, x: ClosedRange<Int>) throws -> Int {
            shimmer.progress = progress
            let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide)/container.bounds.width
            var count = 0
            for px in Int(CGFloat(x.lowerBound)*scale)..<Int(CGFloat(x.upperBound)*scale) {
                for py in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.05 { count += 1 }
            }
            return count
        }
        for progress: CGFloat in [0.3, 0.6, 0.9] {
            XCTAssertEqual(try inked(progress, x: 172...320), 0, "The band never draws past the field, over the badge: \(progress)")
        }
        XCTAssertGreaterThan(try inked(0.9, x: 10...170), 0, "The band still sweeps the visible text, ending at its right edge")
    }
}
