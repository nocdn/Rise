import XCTest
import UIKit
import WebKit
@testable import RiseiOS

/// A toast rides on the bar's top as panels open and close, and a held link's Summarise.
final class LinkSummaryTests: XCTestCase {
    @MainActor private func host(_ browser: BrowserViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        return window
    }

    /// Where the toast's middle is on screen as drawn, and where it belongs over the bar as drawn.
    @MainActor private func toastGap(_ browser: BrowserViewController, _ toast: Toast) -> (shown: CGFloat, expected: CGFloat) {
        let bar = browser.bottomBar.layer.presentation() ?? browser.bottomBar.layer
        let top = bar.position.y-bar.bounds.height/2
        let plaque = toast.layer.presentation() ?? toast.layer
        let expected = max(browser.view.safeAreaInsets.top+35, top-12-27)
        return (plaque.position.y+plaque.transform.m42, expected)
    }

    /// Samples every frame for `seconds`, returning the furthest the toast was from its place and
    /// how far it travelled.
    @MainActor private func follow(_ browser: BrowserViewController, _ toast: Toast, for seconds: Double) async throws -> (drift: CGFloat, travel: CGFloat) {
        var drift: CGFloat = 0, low = CGFloat.infinity, high = -CGFloat.infinity
        let end = CACurrentMediaTime()+seconds
        while CACurrentMediaTime() < end {
            let gap = toastGap(browser, toast)
            drift = max(drift, abs(gap.shown-gap.expected))
            low = min(low, gap.shown); high = max(high, gap.shown)
            try await Task.sleep(for: .milliseconds(8))
        }
        return (drift, high-low)
    }

    @MainActor func testToastRidesOnTheBarAsMenusOpenAndClose() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let browser = BrowserViewController(startURL: fixture.url)
        let window = try host(browser)
        defer { window.isHidden = true }
        for _ in 0..<500 where browser.webView.isLoading || browser.webView.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let toast = Toast(message: "Archived 4 unused tabs", glyph: UIImage(systemName: "archivebox.fill"), name: "archive")
        browser.showToast(toast)
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertLessThan(abs(toastGap(browser, toast).shown-toastGap(browser, toast).expected), 0.5, "It rests over the bar")

        for panel in [BottomBar.Panel.menu, .tabMenu, .search] where panel != .tabMenu {
            browser.openPanel(panel)
            let opening = try await follow(browser, toast, for: 0.7)
            print("PROBE toast open \(panel): drift=\(opening.drift) travel=\(opening.travel)")
            XCTAssertGreaterThan(opening.travel, 100, "It rises with \(panel)")
            XCTAssertLessThan(opening.drift, 1, "It stays on the bar's top every frame as \(panel) opens")
            browser.closePanel()
            let closing = try await follow(browser, toast, for: 0.8)
            print("PROBE toast close \(panel): drift=\(closing.drift) travel=\(closing.travel)")
            XCTAssertLessThan(closing.drift, 1, "And as it closes")
            try await Task.sleep(for: .seconds(0.3))
        }
        browser.setBottomBarCollapsed(true)
        let collapsing = try await follow(browser, toast, for: 0.6)
        print("PROBE toast collapse: drift=\(collapsing.drift) travel=\(collapsing.travel)")
        XCTAssertLessThan(collapsing.drift, 1, "And as the bar collapses")
        XCTAssertFalse(toast.dismissed)
    }

    @MainActor func testSummariseInALinksMenuStreamsIntoAPanelAndIsKeptForThePage() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let browser = BrowserViewController(startURL: fixture.url)
        let window = try host(browser)
        defer { window.isHidden = true; browser.closePanel() }
        let page = browser.webView
        for _ in 0..<500 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .seconds(0.5))
        // A page whose text its script writes a moment after it loads.
        let link = fixture.url.appendingPathComponent("preview/delayed")

        // The link's menu has Summarise, after Open Here, with an SF Symbol.
        let open = UIAction(title: "Open", identifier: BrowserViewController.openLinkIdentifier) { _ in }
        let menu = browser.nativeLinkMenu(in: page, url: link, actions: [open, UIAction(title: "Copy Link") { _ in }])
        func all(_ elements: [UIMenuElement]) -> [UIAction] {
            elements.flatMap { ($0 as? UIMenu).map { all($0.children) } ?? [$0 as? UIAction].compactMap { $0 } }
        }
        let titles = all(menu.children).map(\.title)
        print("PROBE menu: \(titles)")
        let summarise = try XCTUnwrap(all(menu.children).first { $0.identifier == BrowserViewController.summariseLinkIdentifier })
        XCTAssertEqual(summarise.title, "Summarise")
        XCTAssertNotNil(summarise.image)
        XCTAssertEqual(titles.firstIndex(of: "Summarise"), (titles.firstIndex(of: "Open Here") ?? -9)+1, "Just after Open Here")

        // A scripted model, streaming words at about a model's pace.
        let paragraphs = [
            Array(repeating: "The delayed article is a test page whose text its own script writes in after it loads, so reading it waits for that.", count: 3).joined(separator: " "),
            Array(repeating: "Its summary streams into the panel word by word, the panel growing ahead of each new line until the summary is complete.", count: 3).joined(separator: " "),
        ]
        var sentText = ""
        browser.summariseLinkModel = { snapshot, _, streamed in
            sentText = snapshot.text
            var reply = ""
            for (index, paragraph) in paragraphs.enumerated() {
                if index > 0 { reply += "\n\n" }
                for word in paragraph.split(separator: " ") {
                    reply += word+" "
                    streamed(reply)
                    try await Task.sleep(for: .milliseconds(15))
                }
            }
            return PageSummary(paragraphs: paragraphs)
        }
        SummaryCache.remove(SummaryCache.linkKey(of: link))
        let successes = browser.linkSummarySuccessCount
        let started = CACurrentMediaTime()
        browser.summariseLink(link)
        for _ in 0..<100 where !browser.isPanelOpen { try await Task.sleep(for: .milliseconds(10)) }
        let panel = browser.bottomBar.linkSummary
        XCTAssertTrue(browser.isPanelOpen && browser.bottomBar.panel == .linkSummary, "The bar grows into the summary's panel")
        XCTAssertEqual(panel.title.text, "Summarising")
        XCTAssertTrue(panel.isShimmering, "Shimmering while it waits")
        XCTAssertEqual(panel.answerView.entranceTravel, 0, "Words don't slide in")
        XCTAssertFalse(panel.subviews.contains { $0 is UIImageView && $0.frame.minY < LinkSummaryPanel.headerHeight && $0.frame.maxX < panel.title.frame.minX+1 },
                       "No icon in the title: \(panel.subviews.map { "\(type(of: $0)) \($0.frame)" })")
        try await Task.sleep(for: .seconds(0.6))
        let waiting = browser.bottomBar.frame.height
        print("PROBE waiting height \(waiting)")
        XCTAssertLessThan(waiting, 200, "Small while it waits")

        // Every frame while it streams: the newest line is clear of the panel's bottom edge.
        let safeBottom = max(window.safeAreaInsets.bottom, 16)
        var tightest = CGFloat.infinity, heights: [CGFloat] = [], streamingFrames = 0, shortestDrawing = CGFloat.infinity
        while !panel.isFinished, CACurrentMediaTime()-started < 30 {
            let bar = browser.bottomBar.layer.presentation() ?? browser.bottomBar.layer
            let revealed = panel.answerView.revealedHeight(for: panel.answerView.bounds.width)
            if revealed > 0 {
                streamingFrames += 1
                let textBottom = BottomBar.searchTop+LinkSummaryPanel.headerHeight+LinkSummaryPanel.answerTop+revealed
                let room = bar.bounds.height-textBottom
                let capped = browser.bottomBar.frame.height >= window.bounds.height-window.safeAreaInsets.top-12-1
                if !capped { tightest = min(tightest, room) }
                heights.append(bar.bounds.height)
                // The view drawing the text is as tall as the text revealed, never cutting it off.
                if let drawing = panel.answerView.subviews.first(where: { String(describing: type(of: $0)) == "_UITextContainerView" }) {
                    let drawn = (drawing.layer.presentation() ?? drawing.layer).bounds.height
                    shortestDrawing = min(shortestDrawing, drawn-revealed)
                }
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        print("PROBE streamed frames=\(streamingFrames) tightest room under the newest line=\(tightest) safe=\(safeBottom) heights \(heights.first ?? 0)→\(heights.last ?? 0)")
        XCTAssertTrue(sentText.contains("Client rendering is ready"), "The page's own text, written after it loaded, was what was summarised: \(sentText)")
        XCTAssertGreaterThan(streamingFrames, 20)
        XCTAssertGreaterThanOrEqual(tightest, safeBottom, "The newest line never reaches the panel's edge")
        print("PROBE drawing room=\(shortestDrawing)")
        XCTAssertGreaterThanOrEqual(shortestDrawing, -3.5, "The text's drawing never cuts off a revealed line (bar the 3 pt line spacing under the last)")
        XCTAssertGreaterThan(heights.last ?? 0, waiting+100, "It grew upwards with the summary")
        for (a, b) in zip(heights, heights.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a-0.5, "Only ever growing") }

        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(panel.title.text, "Summary", "Summarising turns to Summary")
        let font = panel.answerView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThanOrEqual(font?.pointSize ?? 0, 17, "Larger than Find's 15 pt answers")
        XCTAssertFalse(panel.isShimmering)
        XCTAssertEqual(browser.linkSummarySuccessCount, successes+1, "The success haptic")
        XCTAssertEqual(SummaryCache.linkSummary(for: link)?.paragraphs, paragraphs, "Kept for the page")

        // A summary that fits: a swipe on it, up or down, is the sheet's, as on its title.
        let middle = CGPoint(x: panel.answerView.frame.midX, y: panel.answerView.frame.minY+40)
        XCTAssertFalse(panel.answerView.isScrollEnabled, "Nothing to scroll")
        XCTAssertTrue(panel.canPullToClose(at: middle, velocity: CGPoint(x: 0, y: -600)), "Up on the summary rubber-bands the sheet")
        XCTAssertTrue(panel.canPullToClose(at: middle, velocity: CGPoint(x: 0, y: 600)), "Down on it closes it")
        XCTAssertTrue(panel.canPullToClose(at: CGPoint(x: middle.x, y: 10), velocity: CGPoint(x: 0, y: -600)), "As on the title")
        XCTAssertFalse(panel.canPullToClose(at: middle, velocity: CGPoint(x: 600, y: 20)), "Not sideways")

        // Opening the link and pinching finds it ready.
        browser.closePanel()
        try await Task.sleep(for: .seconds(0.8))
        page.load(URLRequest(url: link))
        for _ in 0..<500 where page.url != link || page.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .seconds(0.3))
        browser.startSummarise(.menu)
        let shown = try XCTUnwrap(browser.summarise)
        XCTAssertEqual(shown.memorised?.paragraphs, paragraphs, "Summarise has the link's summary ready")
        shown.finish()
    }

    /// A summary taller than the sheet gets scrolls: up on it scrolls it, and down from its top closes.
    @MainActor func testALongSummaryScrollsBeforeTheSheetMoves() throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let panel = LinkSummaryPanel(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.addSubview(panel)
        defer { panel.removeFromSuperview() }
        panel.begin(URL(string: "https://example.com/")!)
        panel.show(Array(repeating: "A long summary that runs well past the sheet's tallest, so it has to scroll.", count: 30).joined(separator: " "), finished: true)
        panel.answerView.advance(at: CACurrentMediaTime()+60)
        panel.layoutIfNeeded()
        let middle = CGPoint(x: panel.answerView.frame.midX, y: panel.answerView.frame.minY+40)
        XCTAssertTrue(panel.answerView.isScrollEnabled, "It scrolls")
        XCTAssertFalse(panel.canPullToClose(at: middle, velocity: CGPoint(x: 0, y: -600)), "Up on it scrolls the summary")
        panel.answerView.setContentOffset(.zero, animated: false)
        XCTAssertTrue(panel.canPullToClose(at: middle, velocity: CGPoint(x: 0, y: 600)), "Down from its top closes")
        panel.answerView.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        XCTAssertFalse(panel.canPullToClose(at: middle, velocity: CGPoint(x: 0, y: 600)), "Down while scrolled scrolls it back first")
        panel.cancel()
    }
}
