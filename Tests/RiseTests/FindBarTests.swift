import XCTest
import AppKit
@testable import Rise

@MainActor final class FindBarTests: XCTestCase {
    /// Motion's `{ type: "spring", bounce: 0, duration: 0.2 }` is critically damped with
    /// ω ≈ 46.2 rad/s, so it has all but settled at 0.2 s and never overshoots.
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
    func testToolResponseShowsDoneAndReplacementCancelsItsDismissal() async throws {
        let bar = FindBar()
        var streams: [AsyncThrowingStream<String, Error>.Continuation] = []
        bar.answer = { _, _ in AsyncThrowingStream { streams.append($0) } }
        bar.toggleMode()
        bar.input.stringValue = "First question"
        bar.send()
        streams[0].yield("") // A tool call arrives before answer text.
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
    func testResetClearsAnswerAndCancelsRemainingStream() async throws {
        let bar = FindBar()
        var stream: AsyncThrowingStream<String, Error>.Continuation!
        var cleared = false
        bar.clearHighlights = { cleared = true }
        bar.answer = { _, _ in AsyncThrowingStream { stream = $0 } }
        bar.toggleMode(); bar.input.stringValue = "Question"; bar.send()
        stream.yield("Partial answer")
        try await Task.sleep(for: .seconds(FindMotion.doneHold+0.1))
        XCTAssertEqual(bar.badge.caption, .reset)
        XCTAssertTrue(bar.isAnswering)
        bar.badge.resetButton.performClick(nil)
        stream.yield("Late answer"); stream.finish()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(cleared)
        XCTAssertEqual(bar.mode, .find)
        XCTAssertEqual(bar.input.stringValue, "")
        XCTAssertTrue(bar.conversation.isEmpty)
        XCTAssertFalse(bar.isAnswering)
        bar.toggleMode()
        XCTAssertEqual(bar.badge.caption, .send)
        bar.regenerate()
        XCTAssertFalse(bar.isAnswering)
        bar.closeInstantly()
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
        bar.resetToFind(); bar.toggleMode(); bar.handleEscape()
        XCTAssertEqual(bar.mode, .find)
        XCTAssertEqual(dismissals, 2)
        bar.closeInstantly()
    }
    func testStyledAnswerRendersInlineMarkdown() {
        let text = FindBar.styled("It ships **March 3** with `rise`.", color: .black)
        XCTAssertEqual(text.string, "It ships March 3 with rise.")
        let bold = text.attribute(.font, at: 10, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }
}
