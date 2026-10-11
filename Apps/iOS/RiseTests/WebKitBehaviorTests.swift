import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class WebKitBehaviorTests: XCTestCase {
    @MainActor private func host(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    @MainActor private func load(_ html: String, in webView: WKWebView, baseURL: URL? = nil) async throws {
        webView.loadHTMLString(html, baseURL: baseURL)
        for _ in 0..<750 {
            if !webView.isLoading,
               (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete" {
                // Navigation completion precedes delivery of the initial viewport to the UI process.
                try await Task.sleep(for: .milliseconds(200))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The local WebKit fixture did not finish loading")
    }

    private static let inputPage = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, viewport-fit=cover">
    <style>body { margin: 32px; } input { font-size: 12px; width: 200px; }</style>
    </head><body><input id="tiny" aria-label="Small input"></body></html>
    """

    @MainActor func testPeekDismissalPreservesTheOriginalPageAndCanBeRepeated() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        try await load("""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="height:3000px"><input id="draft" value="unfinished draft"></body></html>
        """, in: browser.webView)
        try await browser.webView.evaluateJavaScript("window.scrollTo(0, 600)")
        try await Task.sleep(for: .milliseconds(200))
        let originalURL = browser.webView.url
        let originalOffset = browser.webView.scrollView.contentOffset.y
        XCTAssertGreaterThan(originalOffset, 500)
        let historyCount = browser.webView.backForwardList.backList.count
        let destination = URL(string: "https://example.com/peek")!

        browser.showPeek(URL(string: "mailto:someone@example.com")!)
        XCTAssertNil(browser.presentedViewController)
        for _ in 0..<2 {
            browser.showPeek(destination)
            let peek = try XCTUnwrap(browser.presentedViewController as? PeekViewController)
            XCTAssertTrue(peek.presentationController is PeekPresentationController)
            browser.showPeek(destination)
            XCTAssertTrue(browser.presentedViewController === peek, "A second request must not stack sheets")
            try await Task.sleep(for: .milliseconds(500))
            let card = peek.view.frame, bounds = window.bounds, margin = PeekPresentationController.margin
            XCTAssertEqual(card.height, bounds.height*PeekPresentationController.heightFraction, accuracy: 1)
            XCTAssertEqual(card.minX, margin, accuracy: 0.5)
            XCTAssertEqual(bounds.maxX-card.maxX, margin, accuracy: 0.5)
            XCTAssertEqual(bounds.maxY-card.maxY, margin, accuracy: 0.5)
            XCTAssertTrue(browser.view.transform.isIdentity, "The page behind is dimmed, not scaled")
            peek.browser.webView.stopLoading()
            try await load(Self.inputPage, in: peek.browser.webView)
            XCTAssertFalse(peek.browser.webView === browser.webView)
            XCTAssertTrue(peek.browser.webView.configuration.websiteDataStore === browser.webView.configuration.websiteDataStore)
            let cap = try await peek.browser.webView.evaluateJavaScript("document.querySelector('meta[name=viewport]').content") as? String
            XCTAssertTrue(try XCTUnwrap(cap).contains("maximum-scale=1"))
            peek.browser.showPeek(destination)
            XCTAssertNil(peek.browser.presentedViewController, "Peek pages must not create nested sheets")
            await withCheckedContinuation { continuation in
                peek.dismiss(animated: true) { continuation.resume() }
            }
            XCTAssertNil(browser.presentedViewController)
            XCTAssertTrue(browser.view.transform.isIdentity, "Closing springs the page back to full size")
            XCTAssertEqual(browser.webView.url, originalURL)
            XCTAssertEqual(browser.webView.scrollView.contentOffset.y, originalOffset, accuracy: 1)
            XCTAssertEqual(browser.webView.backForwardList.backList.count, historyCount)
            let draft = try await browser.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
            XCTAssertEqual(draft, "unfinished draft")
        }
    }

    @MainActor func testDraggingPeekDownRestoresThePageAndDismissesPastTheThreshold() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        browser.showPeek(URL(string: "https://example.com/peek")!)
        let peek = try XCTUnwrap(browser.presentedViewController as? PeekViewController)
        let sheet = try XCTUnwrap(peek.presentationController as? PeekPresentationController)
        try await Task.sleep(for: .milliseconds(700))

        sheet.drag(to: sheet.travel*0.2)
        XCTAssertEqual(peek.view.transform.ty, sheet.travel*0.2, accuracy: 0.5)
        XCTAssertTrue(browser.view.transform.isIdentity)
        sheet.endDrag(velocity: 0)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(browser.presentedViewController === peek, "A short drag springs back")
        XCTAssertEqual(peek.view.transform.ty, 0, accuracy: 0.5)
        let rest = peek.view.frame
        sheet.drag(to: -sheet.reach*0.3)
        XCTAssertEqual(peek.view.frame.maxY, rest.maxY, accuracy: 3, "Growing keeps the card's bottom in place")
        XCTAssertEqual(peek.view.frame.minY, rest.minY-sheet.reach*0.3, accuracy: 1)
        XCTAssertGreaterThan(peek.view.frame.width, rest.width)
        sheet.endDrag(velocity: 0)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(browser.presentedViewController === peek, "A short drag up springs back")
        XCTAssertEqual(peek.view.frame.minY, rest.minY, accuracy: 0.5)
        XCTAssertEqual(peek.view.frame.height, rest.height, accuracy: 0.5)

        sheet.drag(to: 40)
        sheet.endDrag(velocity: 1500)
        for _ in 0..<100 where browser.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(browser.presentedViewController, "A flick dismisses even a short drag")
        XCTAssertTrue(browser.view.transform.isIdentity)
    }

    @MainActor func testPeekHasOnlyAHandleThatGrowsWhenHeldAndAStripMatchingThePageTop() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        browser.showPeek(URL(string: "https://example.com/peek")!)
        let peek = try XCTUnwrap(browser.presentedViewController as? PeekViewController)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(peek.navigationController)
        XCTAssertEqual(peek.browser.view.frame.minY, PeekViewController.headerHeight, accuracy: 0.5,
                       "Only the handle's strip sits above the page")
        let handle = peek.handle
        XCTAssertEqual(handle.pill.bounds.width, PeekHandle.restingLength)
        XCTAssertEqual(handle.pill.bounds.height, PeekHandle.thickness)
        XCTAssertGreaterThan(handle.frame.height, PeekViewController.headerHeight, "The touch area reaches into the page")
        XCTAssertTrue(peek.isOnHandle(CGPoint(x: peek.view.bounds.midX, y: PeekViewController.headerHeight+8)))
        XCTAssertFalse(peek.isOnHandle(CGPoint(x: 10, y: PeekViewController.headerHeight+8)))
        var white: CGFloat = 0, restingAlpha: CGFloat = 0, pressedAlpha: CGFloat = 0
        handle.pillColor.getWhite(&white, alpha: &restingAlpha)
        handle.setPressed(true)
        XCTAssertEqual(handle.pill.bounds.width, PeekHandle.pressedLength)
        handle.pillColor.getWhite(&white, alpha: &pressedAlpha)
        XCTAssertGreaterThan(pressedAlpha, restingAlpha, "Holding darkens the handle")
        handle.setPressed(false)
        XCTAssertEqual(handle.pill.bounds.width, PeekHandle.restingLength)

        let web = peek.browser.webView
        web.stopLoading()
        let pages: [(html: String, rgb: (CGFloat, CGFloat, CGFloat), dark: Bool)] = [
            // A coloured header bar continues into the strip.
            ("<body style='margin:0'><div style='height:60px;background:rgb(255,204,0)'>Title</div></body>", (1, 0.8, 0), false),
            // Stripes across the edge don't agree on one colour, so the site's theme colour stands in.
            ("<head><meta name='theme-color' content='rgb(0,0,255)'></head><body style='margin:0'>" +
             "<div style='height:60px;background:repeating-linear-gradient(90deg,#000 0 4px,#fff 4px 8px)'></div></body>",
             (0, 0, 1), true),
        ]
        for page in pages {
            try await load("<html>" + page.html + "</html>", in: web)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(40))
                peek.header.backgroundColor?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                if abs(red-page.rgb.0) < 0.05, abs(green-page.rgb.1) < 0.05, abs(blue-page.rgb.2) < 0.05 { break }
            }
            XCTAssertEqual(red, page.rgb.0, accuracy: 0.05); XCTAssertEqual(green, page.rgb.1, accuracy: 0.05)
            XCTAssertEqual(blue, page.rgb.2, accuracy: 0.05)
            XCTAssertEqual(peek.handle.onDarkBackground, page.dark, "The handle stays visible on dark strips")
        }
    }

    @MainActor func testExpandingPeekMakesItsLivePageTheMainPageWithBackToThePrevious() async throws {
        for byDragging in [true, false] {
            let browser = BrowserViewController(startURL: nil)
            let window = try host(browser)
            defer { window.isHidden = true }
            try await load("<html><body>original</body></html>", in: browser.webView,
                           baseURL: URL(string: "https://example.com/original")!)
            let original = browser.webView
            browser.showPeek(URL(string: "https://example.com/first")!)
            let peek = try XCTUnwrap(browser.presentedViewController as? PeekViewController)
            let sheet = try XCTUnwrap(peek.presentationController as? PeekPresentationController)
            try await Task.sleep(for: .milliseconds(700))
            let current = URL(string: "https://example.com/followed-link")!
            peek.browser.webView.stopLoading()
            try await load("<html><body style='height:3000px'><input id='draft'></body></html>",
                           in: peek.browser.webView, baseURL: current)
            try await peek.browser.webView.evaluateJavaScript(
                "document.getElementById('draft').value = 'typed in Peek'; window.scrollTo(0, 500); void 0")
            let page = peek.browser.webView

            if byDragging {
                sheet.drag(to: -sheet.reach*0.7)
                sheet.endDrag(velocity: 0)
            } else {
                peek.openInMainPage()
            }
            for _ in 0..<100 where browser.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(browser.presentedViewController)
            XCTAssertTrue(browser.webView === page, "The Peek's live page moves in rather than loading again")
            XCTAssertTrue(page.superview === browser.view)
            XCTAssertEqual(page.frame, browser.view.bounds)
            XCTAssertTrue(browser.view.transform.isIdentity)
            XCTAssertEqual(browser.webView.url, current)
            let draft = try await page.evaluateJavaScript("document.getElementById('draft').value") as? String
            XCTAssertEqual(draft, "typed in Peek")

            XCTAssertTrue(browser.previousPages.last === original)
            browser.returnToPreviousPage()
            XCTAssertTrue(browser.webView === original)
            XCTAssertTrue(original.superview === browser.view)
            XCTAssertNil(page.superview)
            XCTAssertEqual(browser.webView.url, URL(string: "https://example.com/original")!)
            XCTAssertTrue(browser.previousPages.isEmpty)
        }
    }

    @MainActor func testInputFocusDoesNotZoomButManualZoomStillWorks() async throws {
        // Establish that this device actually exercises WebKit's small-input focus zoom.
        let baselineConfiguration = WKWebViewConfiguration()
        baselineConfiguration.ignoresViewportScaleLimits = true
        let baseline = WKWebView(frame: .zero, configuration: baselineConfiguration)
        let baselineController = UIViewController()
        baselineController.view = baseline
        let baselineWindow = try host(baselineController)
        defer { baselineWindow.isHidden = true }
        try await load(Self.inputPage, in: baseline)
        let originalScale = baseline.scrollView.zoomScale
        XCTAssertEqual(originalScale, 1, accuracy: 0.01, "The initial viewport must settle before testing focus zoom")
        baseline.becomeFirstResponder()
        try await baseline.evaluateJavaScript("document.getElementById('tiny').focus()")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(baseline.scrollView.zoomScale, originalScale+0.05,
                             "The control must reproduce automatic focus zoom, so the regression check is meaningful")
        baseline.endEditing(true); baselineWindow.isHidden = true

        let browser = BrowserViewController(startURL: nil)
        let webView = browser.webView
        let window = try host(browser)
        defer { window.endEditing(true); window.isHidden = true }
        try await load(Self.inputPage, in: webView)
        let before = webView.scrollView.zoomScale
        XCTAssertEqual(before, 1, accuracy: 0.01)
        webView.becomeFirstResponder()
        try await webView.evaluateJavaScript("document.getElementById('tiny').focus()")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(webView.scrollView.zoomScale, before, accuracy: 0.01)
        let font = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('tiny')).fontSize")
        XCTAssertEqual(font as? String, "12px", "Suppressing input zoom must not restyle the page")
        XCTAssertGreaterThan(webView.scrollView.maximumZoomScale, before+0.4)
        XCTAssertTrue(webView.scrollView.pinchGestureRecognizer?.isEnabled == true,
                      "The focus zoom policy keeps WebKit's native pinch gesture enabled")
    }

    @MainActor func testPolicyPreservesViewportLayoutAndHandlesDynamicReplacement() async throws {
        let browser = BrowserViewController(startURL: nil)
        let webView = browser.webView, window = try host(browser)
        defer { window.isHidden = true }
        try await load(Self.inputPage, in: webView)
        let result = try await webView.evaluateJavaScript("document.querySelector('meta[name=viewport]').content")
        let content = try XCTUnwrap(result as? String)
        XCTAssertTrue(content.contains("width=device-width")); XCTAssertTrue(content.contains("viewport-fit=cover"))
        XCTAssertTrue(content.contains("maximum-scale=1")); XCTAssertFalse(content.contains("maximum-scale=5"))

        try await webView.evaluateJavaScript("""
        document.querySelector('meta[name=viewport]').remove();
        const replacement = document.createElement('meta');
        replacement.name = 'viewport';
        replacement.content = 'width=640, initial-scale=0.8, maximum-scale=9, viewport-fit=cover';
        document.head.appendChild(replacement);
        void 0;
        """)
        let replaced = try await webView.evaluateJavaScript("document.querySelector('meta[name=viewport]').content") as? String
        XCTAssertTrue(try XCTUnwrap(replaced).contains("maximum-scale=0.8"))
        XCTAssertTrue(try XCTUnwrap(replaced).contains("width=640"))
        XCTAssertTrue(try XCTUnwrap(replaced).contains("viewport-fit=cover"))
    }

    @MainActor func testPolicyAddsMissingViewportWithoutInventingALayoutWidth() async throws {
        let browser = BrowserViewController(startURL: nil)
        let webView = browser.webView, window = try host(browser)
        defer { window.isHidden = true }
        try await load("<html><head><title>No viewport</title></head><body><input id='tiny' style='font-size:12px'></body></html>", in: webView)
        let before = webView.scrollView.zoomScale
        XCTAssertLessThan(before, 1, "A desktop-width page keeps its auto-fit layout")
        let content = try await webView.evaluateJavaScript("document.querySelector('meta[name=viewport]').content") as? String
        XCTAssertTrue(try XCTUnwrap(content).hasPrefix("maximum-scale="))
        XCTAssertFalse(try XCTUnwrap(content).contains("width="))
        let cap = try XCTUnwrap(Double(try XCTUnwrap(content).replacingOccurrences(of: "maximum-scale=", with: "")))
        XCTAssertEqual(cap, before, accuracy: 0.01)
        webView.becomeFirstResponder()
        try await webView.evaluateJavaScript("document.getElementById('tiny').focus()")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(webView.scrollView.zoomScale, before, accuracy: 0.01)
    }
}
