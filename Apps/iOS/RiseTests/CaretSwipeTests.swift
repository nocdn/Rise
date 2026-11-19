import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class CaretSwipeTests: XCTestCase {
    @MainActor private func page(_ html: String) async throws -> (WKWebView, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        page.frame = window.bounds; window.rootViewController?.view.addSubview(page)
        page.loadHTMLString("<meta name=viewport content='width=device-width'>"+html, baseURL: nil)
        for _ in 0..<250 where (try? await page.evaluateJavaScript("document.readyState")) as? String != "complete" { try await Task.sleep(for: .milliseconds(20)) }
        return (page, window)
    }

    @MainActor private func js(_ page: WKWebView, _ script: String) async throws -> Any? {
        try await page.callAsyncJavaScript(script, contentWorld: .page)
    }

    /// Waits for the field's caret to reach `expected`, returning how long it took.
    @MainActor @discardableResult
    private func caret(of page: WKWebView, becomes expected: [Int], field: String = "f", file: StaticString = #filePath, line: UInt = #line) async throws -> TimeInterval {
        let start = Date(), deadline = start.addingTimeInterval(3)
        var now: [Int] = []
        repeat {
            now = (try await js(page, "const f = document.getElementById('\(field)'); return [f.selectionStart, f.selectionEnd]") as? [Int]) ?? []
            if now == expected { return Date().timeIntervalSince(start) }
            try await Task.sleep(for: .milliseconds(2))
        } while Date() < deadline
        XCTAssertEqual(now, expected, file: file, line: line)
        return Date().timeIntervalSince(start)
    }

    @MainActor private func ready(_ swipe: CaretSwipe) async throws {
        for _ in 0..<250 where swipe.field == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor func testTheCaretFollowsTheFingerAWholeCharacterAtATimeAndTurnsBackAtOnceFromEitherEnd() async throws {
        let (page, window) = try await page("<input id=f style='font: 17px -apple-system' value='hello world'>")
        defer { window.isHidden = true }
        _ = try await js(page, "const f = document.getElementById('f'); f.focus(); f.setSelectionRange(2, 2)")
        let swipe = CaretSwipe(webView: page)
        swipe.prepare()
        try await ready(swipe)
        let field = try XCTUnwrap(swipe.field)
        XCTAssertEqual(field.before, 2); XCTAssertEqual(field.after, 9); XCTAssertNil(field.collapse)
        XCTAssertGreaterThan(field.characterWidth, 5); XCTAssertLessThan(field.characterWidth, 12)
        let step = CaretSwipe.step(for: field.characterWidth, zoom: page.scrollView.zoomScale)

        // Already a character on by the time the pan begins, as the finger is.
        swipe.begin(from: 100, at: 100+step)
        let first = try await caret(of: page, becomes: [3, 3])
        XCTAssertLessThan(first, 0.1, "the caret lagged \(first)s behind the finger")
        // Under half a character more doesn't move it; past half does.
        swipe.move(to: 100+step*1.4); swipe.move(to: 100+step*1.6)
        try await caret(of: page, becomes: [4, 4])
        swipe.move(to: 100+step*3)
        try await caret(of: page, becomes: [5, 5])
        XCTAssertEqual(swipe.moves, [1, 1, 1])
        // Far past the end, it waits there, and coming back a character moves it back one.
        swipe.move(to: 100+step*40)
        try await caret(of: page, becomes: [11, 11])
        swipe.move(to: 100+step*39)
        try await caret(of: page, becomes: [10, 10])
        swipe.move(to: 100-step*60)
        try await caret(of: page, becomes: [0, 0])
        swipe.move(to: 100-step*58)
        try await caret(of: page, becomes: [2, 2])
        swipe.end()

        // A second finger: from here it selects, from where the caret was, either way.
        _ = try await js(page, "document.getElementById('f').setSelectionRange(4, 4)")
        swipe.prepare(); try await ready(swipe)
        swipe.begin(from: 0, at: 0)
        swipe.move(to: step)
        try await caret(of: page, becomes: [5, 5])
        swipe.startSelecting()
        XCTAssertTrue(swipe.selecting)
        swipe.move(to: step*4)
        try await caret(of: page, becomes: [5, 8])
        swipe.move(to: -step)
        try await caret(of: page, becomes: [3, 5])
        // The first finger lifting, the second goes on from where it is.
        swipe.rebase(at: 300)
        swipe.move(to: 300)
        swipe.move(to: 300-step)
        try await caret(of: page, becomes: [2, 5])
        // Past the start, it holds there.
        swipe.move(to: 300-step*20)
        try await caret(of: page, becomes: [0, 5])
        swipe.end()
        XCTAssertFalse(swipe.selecting)

        // Fast, many small moves: none is lost, and the caret ends where the finger does.
        _ = try await js(page, "document.getElementById('f').setSelectionRange(0, 0)")
        swipe.prepare()
        swipe.begin(from: 0, at: 0)
        for x in stride(from: 0, through: step*7, by: 0.7) { swipe.move(to: x) }
        try await ready(swipe)
        swipe.move(to: step*7)
        try await caret(of: page, becomes: [7, 7])
        swipe.end()
    }

    @MainActor func testEmojiSelectionsAndFieldsThatCantSayWhereTheirCaretIs() async throws {
        let (page, window) = try await page("<input id=f value='a👍🏽b'><input id=e type=email value='me@example.com'><textarea id=t>ab\ncd</textarea>")
        defer { window.isHidden = true }
        _ = try await js(page, "const f = document.getElementById('f'); f.focus(); f.setSelectionRange(0, 0)")
        let swipe = CaretSwipe(webView: page)
        swipe.prepare(); try await ready(swipe)
        XCTAssertEqual(swipe.field?.after, 3)
        var step = CaretSwipe.step(for: swipe.field!.characterWidth, zoom: page.scrollView.zoomScale)
        swipe.begin(from: 0, at: step*2)
        // Past the thumbs up and its skin tone, four of the field's units, as one character.
        try await caret(of: page, becomes: [5, 5])
        swipe.end()

        // A selection collapses at its moving end, then moves from there.
        _ = try await js(page, "document.getElementById('f').setSelectionRange(1, 5, 'backward')")
        swipe.prepare(); try await ready(swipe)
        XCTAssertEqual(swipe.field?.collapse, 1)
        swipe.begin(from: 0, at: -step)
        try await caret(of: page, becomes: [0, 0])
        swipe.end()

        // Over a line break in a text area.
        _ = try await js(page, "const t = document.getElementById('t'); t.focus(); t.setSelectionRange(1, 1)")
        swipe.prepare(); try await ready(swipe)
        step = CaretSwipe.step(for: swipe.field!.characterWidth, zoom: page.scrollView.zoomScale)
        swipe.begin(from: 0, at: step*2)
        try await caret(of: page, becomes: [3, 3], field: "t")
        swipe.end()

        // An email field can't say where its caret is, but its caret still moves.
        _ = try await js(page, "const e = document.getElementById('e'); e.focus()")
        swipe.prepare(); try await ready(swipe)
        XCTAssertNil(swipe.field?.after)
        step = CaretSwipe.step(for: swipe.field!.characterWidth, zoom: page.scrollView.zoomScale)
        swipe.begin(from: 0, at: -step*4)
        let moved = try await page.evaluateJavaScript("getSelection().toString().length + ':' + document.activeElement.id") as? String
        XCTAssertEqual(moved, "0:e")
        XCTAssertEqual(swipe.sent, -4)
        swipe.end()
    }

    /// In WebKit's own bar: the gap runs from ↓ to the microphone, kept a little off each, and a
    /// finger anywhere in it lands on the toolbar the swipe is on rather than passing through.
    @MainActor func testTheSwipeTakesTheGapInWebKitsBarAndOnlyThat() async throws {
        // A field either side, so ↑ and ↓ are on.
        let (page, window) = try await page("<input id=a><input id=f value='hello'><input id=b>")
        defer { window.isHidden = true; page.resignFirstResponder() }
        let content = try XCTUnwrap(page.scrollView.subviews.first { NSStringFromClass(type(of: $0)) == "WKContentView" })
        XCTAssertTrue(content.becomeFirstResponder())
        _ = try await page.evaluateJavaScript("document.getElementById('f').focus()")
        var accessory: UIView?
        for _ in 0..<100 where accessory?.window == nil { accessory = page.inputAccessoryView; try await Task.sleep(for: .milliseconds(20)) }
        let bar = try XCTUnwrap(accessory)
        func toolbars(in view: UIView) -> [UIToolbar] { view.subviews.flatMap { ($0 as? UIToolbar).map { [$0] } ?? toolbars(in: $0) } }
        let toolbar = try XCTUnwrap(toolbars(in: bar).first { $0.items?.isEmpty == false })
        toolbar.layoutIfNeeded()
        let swipe = try XCTUnwrap(FormAccessoryCaretSwipe.installed(on: toolbar))
        let gap = try XCTUnwrap(swipe.gap), barWindow = try XCTUnwrap(toolbar.window)
        func frame(of item: UIBarButtonItem) throws -> CGRect {
            let view = try XCTUnwrap(item.customView ?? item.perform(NSSelectorFromString("view"))?.takeUnretainedValue() as? UIView)
            return try XCTUnwrap(view.superview).convert(view.frame, to: toolbar)
        }
        let items = try XCTUnwrap(toolbar.items)
        let next = try XCTUnwrap(items.first { $0.action.map(NSStringFromSelector) == "_nextTapped" })
        let end = try XCTUnwrap(items.first { $0.customView is FormAccessoryDictation } ?? items.first { $0.action.map(NSStringFromSelector) == "_done" })
        XCTAssertEqual(gap.lowerBound, try frame(of: next).maxX+FormAccessoryCaretSwipe.buttonMargin, accuracy: 0.5)
        XCTAssertEqual(gap.upperBound, try frame(of: end).minX-FormAccessoryCaretSwipe.buttonMargin, accuracy: 0.5)
        XCTAssertGreaterThan(gap.upperBound-gap.lowerBound, 120)
        for x in stride(from: gap.lowerBound, through: gap.upperBound, by: (gap.upperBound-gap.lowerBound)/8) {
            let hit = barWindow.hitTest(toolbar.convert(CGPoint(x: x, y: toolbar.bounds.midY), to: barWindow), with: nil)
            XCTAssertTrue(hit?.isDescendant(of: toolbar) == true, "a finger at \(x) misses the bar")
        }
        // While swiping, a finger on ↑, ↓, the microphone or ✓ is the bar's, not the button's.
        let buttons = try items.compactMap { item -> (UIView, CGRect)? in
            guard item.action != nil || item.customView != nil else { return nil }
            return (try XCTUnwrap(item.customView ?? item.perform(NSSelectorFromString("view"))?.takeUnretainedValue() as? UIView), try frame(of: item))
        }
        XCTAssertEqual(buttons.count, 4)
        func hits(_ rect: CGRect) -> UIView? { barWindow.hitTest(toolbar.convert(CGPoint(x: rect.midX, y: rect.midY), to: barWindow), with: nil) }
        XCTAssertTrue(buttons.allSatisfy { hits($0.1)?.isDescendant(of: $0.0) == true })
        swipe.stillButtons(true)
        XCTAssertTrue(swipe.isSwiping)
        for (button, rect) in buttons {
            let hit = hits(rect)
            XCTAssertTrue(hit?.isDescendant(of: bar) == true)
            XCTAssertFalse(hit?.isDescendant(of: button) == true, "a finger on \(type(of: button)) still reaches it")
        }
        swipe.stillButtons(false)
        XCTAssertFalse(swipe.isSwiping)
        XCTAssertTrue(buttons.allSatisfy { hits($0.1)?.isDescendant(of: $0.0) == true })

        // Once, however often WebKit asks for its bar.
        _ = page.inputAccessoryView; _ = page.inputAccessoryView
        XCTAssertEqual(bar.gestureRecognizers?.filter { $0 is TouchDownPanGestureRecognizer }.count, 1)
        // Above and below the toolbar, a second finger still lands on the bar.
        for y in [bar.bounds.minY+2, bar.bounds.maxY-2] {
            let hit = barWindow.hitTest(bar.convert(CGPoint(x: bar.bounds.midX, y: y), to: barWindow), with: nil)
            XCTAssertTrue(hit?.isDescendant(of: bar) == true, "a finger at \(y) misses the bar")
        }
    }
}
