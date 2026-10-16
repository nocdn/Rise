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

    @MainActor func testFreshLaunchOpensNewPageOnceAndLoadingBehindItPreservesThePanel() async throws {
        let browser = BrowserViewController(startURL: nil, opensSearchOnFirstAppearance: true)
        let window = try host(browser)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let bar = browser.bottomBar
        XCTAssertTrue(browser.isPanelOpen)
        XCTAssertEqual(bar.panel, .search)
        XCTAssertTrue(bar.shown === bar.search)
        XCTAssertTrue(bar.search.field.isFirstResponder)
        XCTAssertEqual(bar.search.field.text, "")
        XCTAssertEqual(browser.tabs.count, 1, "Opening the dialog does not create another tab")
        XCTAssertEqual(bar.frame.height, (window.bounds.height*BrowserViewController.panelHeightFraction).rounded(), accuracy: 1)

        // The page can finish loading behind the search without taking focus or closing it.
        let original = browser.webView
        try await load("<html><body>The home page loaded behind New Page.</body></html>", in: original)
        XCTAssertTrue(browser.webView === original)
        XCTAssertTrue(browser.isPanelOpen)
        XCTAssertTrue(bar.search.field.isFirstResponder)
        let text = try await original.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertEqual(text, "The home page loaded behind New Page.")
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(400))
        browser.beginAppearanceTransition(false, animated: false); browser.endAppearanceTransition()
        browser.beginAppearanceTransition(true, animated: false); browser.endAppearanceTransition()
        XCTAssertFalse(browser.isPanelOpen, "A later appearance does not reopen New Page")

        // Returning with an open dialog also preserves its draft.
        bar.newPageButton.sendActions(for: .primaryActionTriggered)
        bar.search.field.text = "Keep this draft"
        browser.beginAppearanceTransition(false, animated: false); browser.endAppearanceTransition()
        browser.beginAppearanceTransition(true, animated: false); browser.endAppearanceTransition()
        XCTAssertTrue(browser.isPanelOpen)
        XCTAssertEqual(bar.search.field.text, "Keep this draft")
        browser.closePanel()
    }

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

    @MainActor func testStatusBarStripContinuesThePageTopAndKeepsTheClockReadable() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let statusBar = browser.view.safeAreaInsets.top
        XCTAssertGreaterThan(statusBar, 0)
        XCTAssertEqual(browser.webView.frame.minY, statusBar, "Pages start below the strip")
        for (html, rgb, style) in [
            ("<div style='height:80px;background:rgb(255,102,0)'></div>", (1.0, 0.4, 0.0), UIStatusBarStyle.darkContent),
            ("<div style='height:80px;background:rgb(20,20,60)'></div>", (20.0/255, 20.0/255, 60.0/255), .lightContent),
        ] {
            try await load("<html><body style='margin:0;height:3000px'>" + html + "</body></html>", in: browser.webView)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(40))
                browser.topStrip.backgroundColor?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                if abs(red-rgb.0) < 0.03, abs(green-rgb.1) < 0.03, abs(blue-rgb.2) < 0.03 { break }
            }
            XCTAssertEqual(red, rgb.0, accuracy: 0.03); XCTAssertEqual(green, rgb.1, accuracy: 0.03)
            XCTAssertEqual(blue, rgb.2, accuracy: 0.03)
            XCTAssertEqual(browser.preferredStatusBarStyle, style)
        }
        // Scrolling past the coloured bar brings the page's plain background to the top.
        try await browser.webView.evaluateJavaScript("window.scrollTo(0, 400)")
        var white: CGFloat = 0, alpha: CGFloat = 0
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(40))
            browser.topStrip.backgroundColor?.getWhite(&white, alpha: &alpha)
            if white > 0.97 { break }
        }
        XCTAssertGreaterThan(white, 0.97)
        XCTAssertEqual(browser.preferredStatusBarStyle, .darkContent)
    }

    @MainActor func testPullingPastTheTopKeepsTheStripColourAndFillsTheGap() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let web = browser.webView
        try await load("<html><body style='margin:0;height:3000px;background:white'>" +
                       "<div style='height:80px;background:rgb(255,102,0)'></div></body></html>", in: web)
        func stripRed() -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            browser.topStrip.backgroundColor?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return red+(1-green)+(1-blue)
        }
        for _ in 0..<50 where stripRed() < 2.5 { try await Task.sleep(for: .milliseconds(40)) }
        let orange = try XCTUnwrap(browser.topStrip.backgroundColor)
        let pageBackground = web.underPageBackgroundColor

        web.scrollView.contentOffset.y = -web.scrollView.adjustedContentInset.top-70
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(browser.topStrip.backgroundColor, orange, "Pulling down mustn't sample the gap")
        var gap: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), strip = gap
        web.underPageBackgroundColor.getRed(&gap.0, green: &gap.1, blue: &gap.2, alpha: &gap.3)
        orange.getRed(&strip.0, green: &strip.1, blue: &strip.2, alpha: &strip.3)
        XCTAssertEqual(gap.0, strip.0, accuracy: 0.01, "The gap continues the strip")
        XCTAssertEqual(gap.1, strip.1, accuracy: 0.01); XCTAssertEqual(gap.2, strip.2, accuracy: 0.01)
        web.scrollView.contentOffset.y = -web.scrollView.adjustedContentInset.top
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(web.underPageBackgroundColor, pageBackground, "The page's own colour returns")
        XCTAssertEqual(browser.topStrip.backgroundColor, orange)
    }

    @MainActor func testPullToReloadTicksUpToTheThresholdClicksOnceAndReloadsOnlyPastIt() {
        var reloads = 0
        let pull = PullToReload { reloads += 1 }
        pull.attach(to: WKWebView())
        let threshold = PullToReload.threshold, spacing = PullToReload.tickSpacing
        for distance in stride(from: 0, to: threshold, by: 1) { pull.update(pull: distance) }
        XCTAssertEqual(pull.ticks, Int((threshold-1)/spacing), "One tick per step of the pull")
        XCTAssertFalse(pull.armed)
        XCTAssertEqual(pull.clicks, 0)
        for distance in stride(from: threshold, to: threshold+40, by: 1) { pull.update(pull: distance) }
        XCTAssertTrue(pull.armed)
        XCTAssertEqual(pull.clicks, 1, "Reaching the threshold is one click, with no ticks beyond it")
        let ticksAtThreshold = pull.ticks
        XCTAssertEqual(ticksAtThreshold, Int((threshold-1)/spacing))
        pull.finish()
        XCTAssertEqual(reloads, 1)
        XCTAssertTrue(pull.isReloading)

        // Easing back below the threshold disarms it, and the ticks resume on the way down.
        let eased = PullToReload { reloads += 1 }
        eased.attach(to: WKWebView())
        for distance in stride(from: 0, to: threshold+10, by: 1) { eased.update(pull: distance) }
        for distance in stride(from: threshold+10, to: 40, by: -1) { eased.update(pull: distance) }
        XCTAssertFalse(eased.armed)
        XCTAssertEqual(eased.clicks, 1)
        XCTAssertGreaterThan(eased.ticks, ticksAtThreshold)
        eased.finish()
        XCTAssertEqual(reloads, 1, "Letting go short of the threshold doesn't reload")
        XCTAssertFalse(eased.isReloading)
    }

    @MainActor func testReleasingPastTheThresholdSpinsInAHeldGapUntilTheReloadFinishes() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let web = browser.webView, scrollView = web.scrollView, pull = browser.pullToReload
        try await load("<html><body style='margin:0;height:3000px;background:white'>" +
                       "<div style='height:80px;background:rgb(255,102,0)'></div></body></html>", in: web)
        for _ in 0..<50 where browser.topColor == nil { try await Task.sleep(for: .milliseconds(40)) }
        let orange = try XCTUnwrap(browser.topStrip.backgroundColor)

        // Charging: spokes appear with the pull, all of them at the threshold.
        scrollView.contentOffset.y = -PullToReload.threshold/2
        XCTAssertEqual(pull.overlay.frame.minY, web.frame.minY, accuracy: 0.5)
        XCTAssertEqual(pull.overlay.frame.height, PullToReload.threshold/2, accuracy: 0.5)
        XCTAssertEqual(pull.spinner.shownSpokes, ReloadSpinner.spokeCount/2)
        XCTAssertEqual(pull.spinner.center.y, PullToReload.threshold/4, accuracy: 0.5)
        scrollView.contentOffset.y = -PullToReload.threshold-10
        XCTAssertEqual(pull.spinner.shownSpokes, ReloadSpinner.spokeCount)
        pull.update(pull: scrollView.topOverscroll)
        XCTAssertTrue(pull.armed)

        pull.finish()
        XCTAssertTrue(pull.isReloading)
        XCTAssertTrue(pull.spinner.isSpinning)
        XCTAssertEqual(scrollView.contentInset.top, PullToReload.heldGap, "The gap is held open for the spinner")
        scrollView.contentOffset.y = -scrollView.adjustedContentInset.top // where the bounce settles
        XCTAssertEqual(pull.overlay.frame.height, PullToReload.heldGap, accuracy: 0.5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.topStrip.backgroundColor, orange, "The held gap isn't sampled")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        web.underPageBackgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(red, 1, accuracy: 0.02); XCTAssertEqual(green, 0.4, accuracy: 0.02)

        for _ in 0..<150 where pull.isReloading || pull.spinner.isSpinning { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(pull.isReloading)
        XCTAssertFalse(pull.spinner.isSpinning)
        XCTAssertEqual(scrollView.contentInset.top, 0, "The page slides back up once reloaded")
        XCTAssertEqual(scrollView.contentOffset.y, -scrollView.adjustedContentInset.top, accuracy: 0.5)
        XCTAssertEqual(pull.overlay.frame.height, 0, accuracy: 0.5)
    }

    @MainActor func testBottomBarSpansTheBottomTakesThePageColourAndCollapsesToAStrip() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let bar = browser.bottomBar, bounds = browser.view.bounds, safeBottom = window.safeAreaInsets.bottom
        let open = BottomBar.height(collapsed: false, safeBottom: safeBottom)
        XCTAssertTrue(bar.superview === browser.view)
        XCTAssertEqual(bar.frame, CGRect(x: 0, y: bounds.maxY-open, width: bounds.width, height: open))
        XCTAssertEqual(browser.view.safeAreaInsets.bottom, open, accuracy: 0.5, "Pages scroll clear of the open bar")
        XCTAssertLessThan(bar.tabsButton.frame.maxX, bar.newPageButton.frame.minX)
        XCTAssertEqual(bar.newPageButton.frame.midX, bar.bounds.midX, accuracy: 0.5)
        XCTAssertLessThan(bar.newPageButton.frame.maxX, bar.moreButton.frame.minX)
        XCTAssertNil(bar.moreButton.menu, "More grows the bar rather than showing a menu")
        XCTAssertNil(PeekViewController(url: URL(string: "https://example.com")!) { _, _ in }.browser.bottomBar.superview)

        // The bar keeps its own colour whatever the page's, white, or dark grey rather than black in
        // dark mode, following the system's appearance.
        try await load("<html><body style='margin:0;height:3000px;background:rgb(20,20,60)'></body></html>", in: browser.webView)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(bar.backgroundColor, BottomBar.background)
        XCTAssertEqual(bar.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(BottomBar.background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), .white)
        var white: CGFloat = 0, alpha: CGFloat = 0
        BottomBar.background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getWhite(&white, alpha: &alpha)
        XCTAssertGreaterThan(white, 0.05, "Not black")
        XCTAssertLessThan(white, 0.2)
        XCTAssertNotNil(bar.tabsButton.preview, "The Tabs button previews the page")

        browser.setBottomBarCollapsed(true, animated: false)
        XCTAssertTrue(bar.isCollapsed)
        let strip = BottomBar.height(collapsed: true, safeBottom: safeBottom)
        XCTAssertLessThan(strip, open)
        XCTAssertEqual(bar.frame.height, strip)
        XCTAssertEqual(bar.frame.maxY, bounds.maxY)
        XCTAssertEqual(bar.newPageButton.superview?.alpha, 0, "The strip shows nothing")
        XCTAssertEqual(browser.view.safeAreaInsets.bottom, open, accuracy: 0.5, "The page doesn't resize")
        browser.setBottomBarCollapsed(false, animated: false)
        XCTAssertEqual(bar.frame.height, open)
        XCTAssertEqual(bar.newPageButton.superview?.alpha, 1)

        // Plus grows the bar into a panel with rounded top corners, setting the page back behind it.
        XCTAssertEqual(TabsPreviewButton.cardSize.width, TabsPreviewButton.cardSize.height, "Square cards")
        let original = browser.webView
        bar.newPageButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isPanelOpen)
        XCTAssertTrue(bar.search.field.isFirstResponder, "The search is focused as the panel opens")
        XCTAssertEqual(bar.search.field.placeholder, "Search or enter URL")
        XCTAssertEqual(bar.search.field.text, "")
        // Shaking clears what was typed, rather than offering to undo it.
        XCTAssertFalse(UIApplication.shared.applicationSupportsShakeToEdit)
        bar.search.field.text = "swift"
        bar.search.field.motionEnded(.motionShake, with: nil)
        XCTAssertEqual(bar.search.field.text, "")
        XCTAssertTrue(bar.search.candidates.contains { $0.symbol == "globe" && $0.url != nil }, "An empty field offers learned/recent links")
        XCTAssertEqual(SearchPanel.searchIcon.size, CGSize(width: 16, height: 16))
        try await Task.sleep(for: .milliseconds(600))
        let panel = (bounds.height*BrowserViewController.panelHeightFraction).rounded()
        XCTAssertEqual(bar.frame.height, panel, accuracy: 0.5)
        XCTAssertEqual(bar.frame.maxY, bounds.maxY, accuracy: 0.5)
        XCTAssertLessThan(bar.frame.height, bounds.height*PeekPresentationController.heightFraction)
        XCTAssertEqual(bar.layer.cornerRadius, BottomBar.panelCornerRadius)
        XCTAssertEqual(bar.layer.maskedCorners, [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        XCTAssertEqual(bar.home.alpha, 0, "The bar's buttons give way to the search")
        XCTAssertEqual(bar.search.alpha, 1)
        XCTAssertEqual(bar.search.field.layer.cornerRadius, SearchPanel.cornerRadius, "Rounded, not a capsule")
        XCTAssertEqual(bar.search.field.backgroundColor, SearchPanel.fill)
        XCTAssertEqual(bar.newPageButton.backgroundColor, SearchPanel.fill)
        XCTAssertLessThan(bar.newPageButton.layer.cornerRadius, BottomBar.newPageSize.height/2)
        let font = try XCTUnwrap(bar.search.field.font)
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        XCTAssertEqual(traits?[.weight] as? CGFloat, UIFont.Weight.semibold.rawValue)
        XCTAssertTrue(font.fontName.lowercased().contains("rounded"), font.fontName)
        XCTAssertNil(bar.search.field.leftView?.subviews.first, "No magnifying glass in the field")
        XCTAssertEqual(SearchPanel.font.fontName, UIFont.systemFont(ofSize: 17, weight: .medium).fontName,
                       "Suggestion titles use the standard iOS font")
        XCTAssertEqual(browser.content.transform.a, PageRecede.scale, accuracy: 0.001)
        XCTAssertEqual(browser.content.transform.ty, PageRecede.drop, accuracy: 0.5)
        XCTAssertTrue(browser.webView === original, "Plus doesn't replace the page")
        XCTAssertEqual(browser.preferredStatusBarStyle, .lightContent)

        browser.closePanel()
        XCTAssertFalse(browser.isPanelOpen)
        XCTAssertFalse(bar.search.field.isFirstResponder)
        XCTAssertTrue(UIApplication.shared.applicationSupportsShakeToEdit, "Shake to undo elsewhere, as usual")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(bar.frame.height, open, accuracy: 0.5)
        XCTAssertEqual(bar.layer.cornerRadius, 0)
        XCTAssertEqual(bar.home.alpha, 1)
        XCTAssertEqual(browser.content.transform, .identity)
        XCTAssertEqual(bar.search.alpha, 0)

        // Choosing a suggestion grows the panel to fill the window with a new page searching Google
        // for it, which then becomes the page, in a new tab after the previous one.
        bar.newPageButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(400))
        bar.search.field.text = "swift"
        bar.search.choose("swift concurrency")
        XCTAssertFalse(browser.isPanelOpen)
        XCTAssertFalse(bar.search.field.isFirstResponder)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(bar.frame.height, panel, "The panel grows upwards")
        XCTAssertLessThan(browser.content.transform.a, PageRecede.scale, "The page behind recedes further")
        XCTAssertTrue(browser.webView === original, "The new page arrives inside the panel first")
        try await Task.sleep(for: .milliseconds(600))
        let arrived = browser.webView
        XCTAssertFalse(arrived === original)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(browser.tabs[0].webView === original, "The previous page stays in its tab")
        XCTAssertEqual(browser.tabIndex, 1)
        XCTAssertTrue(browser.previousPages.isEmpty)
        XCTAssertTrue(arrived.superview === browser.content)
        XCTAssertEqual(arrived.frame.minY, browser.topStrip.frame.maxY)
        XCTAssertEqual(arrived.frame.maxY, bounds.maxY)
        XCTAssertEqual(browser.content.transform, .identity)
        XCTAssertEqual(bar.frame.height, open, accuracy: 0.5)
        XCTAssertEqual(bar.layer.cornerRadius, 0)
        XCTAssertTrue(browser.view.isUserInteractionEnabled)
        XCTAssertEqual(bar.home.alpha, 1, accuracy: 0.01)
        let search = try XCTUnwrap(URLComponents(url: try XCTUnwrap(arrived.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(search.host, "www.google.com")
        XCTAssertEqual(search.queryItems?.first { $0.name == "q" }?.value, "swift concurrency")
        bar.newPageButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(bar.search.field.text, "")
        XCTAssertTrue(bar.search.candidates.contains { $0.symbol == "globe" && $0.url != nil }, "An empty field offers learned/recent links")
        browser.closePanel()

        // More grows the bar a little, its buttons swapping for the page's address over large
        // square buttons, with a blurred crossfade.
        try await Task.sleep(for: .milliseconds(700))
        bar.moreButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isPanelOpen)
        XCTAssertFalse(bar.search.field.isFirstResponder, "No keyboard for More")
        XCTAssertTrue(bar.home.subviews.contains { $0 is UIImageView }, "A blurred copy of the buttons")
        XCTAssertTrue(bar.menu.subviews.contains { $0 is UIImageView }, "A blurred copy of the menu")
        try await Task.sleep(for: .milliseconds(60))
        let growing = try XCTUnwrap(bar.menu.layer.presentation()?.affineTransform().a)
        XCTAssertGreaterThan(growing, BlurCrossfade.scale-0.001, "The menu grows in from a little smaller")
        XCTAssertLessThan(growing, 1)
        try await Task.sleep(for: .milliseconds(600))
        let menuHeight = BottomBar.menuHeight(width: bounds.width, safeBottom: safeBottom)
        XCTAssertEqual(bar.frame.height, menuHeight, accuracy: 0.5)
        XCTAssertEqual(bar.frame.maxY, bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(menuHeight/panel, 1.0/3, accuracy: 0.08, "About a third of New Page's panel")
        let travel = menuHeight-open, searchTravel = panel-open
        XCTAssertEqual(browser.content.transform.a, 1-(1-PageRecede.scale)*travel/searchTravel, accuracy: 0.001,
                       "The page recedes less behind the smaller panel, at the same rate as it grows")
        XCTAssertEqual(browser.preferredStatusBarStyle, PageEdgeColor.isDark(try XCTUnwrap(browser.topColor)) ? .lightContent : .darkContent,
                       "The clock stays over the page's top")
        XCTAssertEqual(bar.home.alpha, 0, "The bar's buttons give way to the address")
        let address = bar.menu.address
        let grown = bar.convert(address.frame, from: address.superview)
        XCTAssertEqual(grown.width, bounds.width-2*SearchPanel.inset, accuracy: 0.5)
        XCTAssertEqual(grown.height, SearchPanel.fieldHeight, accuracy: 0.5)
        XCTAssertEqual(grown.minY, BottomBar.searchTop, accuracy: 0.5)
        XCTAssertEqual(address.layer.cornerRadius, SearchPanel.cornerRadius)
        XCTAssertEqual(address.backgroundColor, SearchPanel.fill)
        XCTAssertEqual(bar.menu.alpha, 1)
        var host = try XCTUnwrap(browser.webView.url?.host())
        if host.hasPrefix("www.") { host.removeFirst(4) }
        XCTAssertEqual(address.host.text, host)
        XCTAssertFalse(address.lock.isHidden, "A padlock on HTTPS pages")
        XCTAssertTrue(address.backButton.isHidden, "Nowhere to go back in a new tab")
        XCTAssertTrue(address.forwardButton.isHidden, "Nowhere to go forward")
        XCTAssertEqual(bar.hitTest(CGPoint(x: grown.midX, y: grown.maxY-3), with: nil)?.isDescendant(of: bar.menu.address), true,
                       "Tapping the address doesn't make a new page")
        XCTAssertTrue(bar.hitTest(bar.convert(CGPoint(x: address.bounds.width-22, y: 24), from: address), with: nil)
                      === address.reloadButton)
        XCTAssertEqual(bar.menu.transform, .identity)
        XCTAssertEqual(bar.moreButton.backgroundColor, SearchPanel.fill)
        XCTAssertTrue(bar.menu.tiles.allSatisfy { $0.backgroundColor == SearchPanel.fill })
        bar.menu.summariseTile.sendActions(for: .touchDown)
        XCTAssertEqual(bar.menu.summariseTile.backgroundColor, SearchPanel.pressedFill, "Darker while pressed")
        bar.menu.summariseTile.sendActions(for: .touchUpOutside)
        XCTAssertEqual(bar.menu.summariseTile.backgroundColor, SearchPanel.fill)
        XCTAssertEqual(bar.menu.tiles.map(\.accessibilityLabel), ["Share", "Summarise", "Find on Page", "Copy Link"])
        for tile in bar.menu.tiles {
            let frame = bar.convert(tile.frame, from: tile.superview)
            XCTAssertEqual(frame.width, frame.height, "Square")
            XCTAssertGreaterThan(frame.minY, grown.maxY)
            XCTAssertLessThanOrEqual(frame.maxY, bar.bounds.maxY-safeBottom+0.5)
        }

        // Back and Forward leave it open; Reload closes it, the bar's buttons returning.
        bar.menu.address.forwardButton.sendActions(for: .primaryActionTriggered)
        bar.menu.summariseTile.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isPanelOpen)
        bar.menu.address.reloadButton.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(browser.isPanelOpen)
        try await Task.sleep(for: .milliseconds(60))
        let returning = try XCTUnwrap(bar.home.layer.presentation()?.affineTransform().a)
        XCTAssertLessThan(returning, 1, "The buttons grow back in from a little smaller too")
        XCTAssertLessThan(try XCTUnwrap(bar.menu.layer.presentation()?.affineTransform().a), 1, "as the menu shrinks away")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(bar.frame.height, open, accuracy: 0.5)
        XCTAssertEqual(bar.menu.alpha, 0)
        XCTAssertEqual(bar.home.alpha, 1)
        XCTAssertFalse([bar.home, bar.menu].contains { $0.subviews.contains { $0 is UIImageView } }, "The blurred copies are gone")
        XCTAssertEqual(bar.home.transform, .identity)
        XCTAssertEqual(bar.menu.transform, .identity)
        XCTAssertEqual(browser.content.transform, .identity)
    }

    @MainActor func testSoleHistoryChevronTurnsBetweenBackAndForwardAndKeepsBothActions() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("rise-history-\(UUID().uuidString).html")
        try "<html><body>A local history fixture.</body></html>".write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }
        browser.webView.loadFileURL(fixture, allowingReadAccessTo: fixture.deletingLastPathComponent())
        for _ in 0..<250 where browser.webView.isLoading || browser.webView.url != fixture {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(browser.webView.url, fixture)
        try await browser.webView.evaluateJavaScript("location.hash = 'detail'")
        for _ in 0..<100 where !browser.webView.canGoBack { try await Task.sleep(for: .milliseconds(10)) }
        let address = browser.bottomBar.menu.address
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(address.backButton.isHidden)
        XCTAssertTrue(address.forwardButton.isHidden)
        let slot = address.backButton.center

        address.backButton.sendActions(for: .primaryActionTriggered)
        for _ in 0..<100 where address.forwardButton.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(address.backButton.isHidden)
        XCTAssertFalse(address.forwardButton.isHidden)
        XCTAssertEqual(address.forwardButton.center, slot, "The sole arrow keeps its tap area")
        XCTAssertEqual(address.forwardButton.accessibilityLabel, "Forward")
        try await Task.sleep(for: .milliseconds(40))
        let forwardGlyph = try XCTUnwrap(address.forwardButton.subviews.first { $0 is UIImageView })
        let turningForward = try XCTUnwrap(forwardGlyph.layer.presentation()?.affineTransform())
        XCTAssertGreaterThan(abs(turningForward.b), 0.1, "The glyph turns instead of instantly swapping")

        // Reverse before the first turn has finished: the new Back glyph starts at that angle.
        address.forwardButton.sendActions(for: .primaryActionTriggered)
        for _ in 0..<100 where address.backButton.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(address.backButton.isHidden)
        XCTAssertTrue(address.forwardButton.isHidden)
        XCTAssertEqual(address.backButton.center, slot)
        XCTAssertEqual(address.backButton.accessibilityLabel, "Back")
        try await Task.sleep(for: .milliseconds(40))
        let backGlyph = try XCTUnwrap(address.backButton.subviews.first { $0 is UIImageView })
        XCTAssertGreaterThan(abs(try XCTUnwrap(backGlyph.layer.presentation()?.affineTransform().b)), 0.1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(backGlyph.transform, .identity)
        XCTAssertTrue(browser.isPanelOpen, "History navigation leaves More open")
        XCTAssertTrue(browser.webView.canGoBack)
        XCTAssertFalse(browser.webView.canGoForward)

        // With more history there are still two distinct, correctly directed controls.
        try await browser.webView.evaluateJavaScript("location.hash = 'second'")
        try await Task.sleep(for: .milliseconds(100))
        address.backButton.sendActions(for: .primaryActionTriggered)
        for _ in 0..<100 where address.forwardButton.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(address.backButton.isHidden)
        XCTAssertFalse(address.forwardButton.isHidden)
        XCTAssertEqual(address.forwardButton.center.x-address.backButton.center.x, AddressBar.pairSpacing)
        XCTAssertEqual(backGlyph.transform, .identity)
        XCTAssertEqual(forwardGlyph.transform.a, -1, accuracy: 0.001)

        // Editing temporarily hides both arrows; returning restores the same availability.
        address.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(400))
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(400))
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(address.backButton.isHidden)
        XCTAssertFalse(address.forwardButton.isHidden)
        browser.closePanel()
    }

    @MainActor func testRapidMoreThenSiteSettingsDoesNotLeaveTheCompactBarVisible() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let bar = browser.bottomBar

        for delay in [50, 100] {
            bar.moreButton.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(delay))
            XCTAssertGreaterThan(try XCTUnwrap(bar.home.layer.presentation()?.opacity), 0,
                                 "The second tap interrupts the compact bar's fade")
            bar.menu.siteSettingsButton.sendActions(for: .primaryActionTriggered)
            XCTAssertTrue(bar.shown === bar.siteSettings)
            XCTAssertTrue(bar.siteSettings.isUserInteractionEnabled, "Rapid input stays responsive")
            try await Task.sleep(for: .milliseconds(400))

            XCTAssertEqual(bar.siteSettings.alpha, 1)
            XCTAssertEqual(bar.siteSettings.transform, .identity)
            for inactive in [bar.home, bar.menu, bar.search, bar.find] {
                XCTAssertEqual(inactive.alpha, 0, "Earlier contents must not remain above Site settings")
                XCTAssertEqual(inactive.transform, .identity)
                XCTAssertTrue(inactive.accessibilityElementsHidden)
                XCTAssertFalse(inactive.subviews.contains { $0 is UIImageView }, "No blurred snapshots are left over")
            }

            // Interrupt the return to More as well, without waiting for its crossfade to finish.
            bar.siteSettings.closeButton.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(50))
            bar.menu.siteSettingsButton.sendActions(for: .primaryActionTriggered)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(bar.home.alpha, 0)
            XCTAssertEqual(bar.menu.alpha, 0)
            XCTAssertEqual(bar.siteSettings.alpha, 1)
            browser.closePanel()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(bar.home.alpha, 1)
            XCTAssertEqual(bar.siteSettings.alpha, 0)
        }
    }

    @MainActor func testTabsShrinkIntoCardsUnderTheBarAndASwipeUpDropsThePageIn() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let bar = browser.bottomBar, switcher = browser.tabSwitcher
        // A 2-pixel PNG as the page's icon.
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.base64EncodedString()
        try await load("<html><head><title>One</title><link rel='icon' href='data:image/png;base64,\(icon)'></head><body style='background:#c33'><h1>One</h1></body></html>",
                       in: browser.webView, baseURL: URL(string: "https://example.com/one")!)
        let first = browser.webView
        browser.tabs[0].loadFavicon()
        XCTAssertEqual(bar.tabsButton.count, 1)

        // New Page opens what's chosen in a new tab, after this one.
        bar.newPageButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(400))
        browser.openFromPanel(URL(string: "about:blank")!)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.tabIndex, 1)
        XCTAssertTrue(browser.tabs[0].webView === first)
        XCTAssertNotNil(browser.tabs[0].snapshot, "The previous tab's card shows how it was left")
        XCTAssertEqual(bar.tabsButton.count, 2, "Tabs counts the tabs")
        XCTAssertEqual(bar.tabsButton.countLabel.text, "2")
        XCTAssertNotNil(browser.tabs[0].favicon, "The page's declared icon")
        XCTAssertNil(browser.tabs[1].favicon, "A blank page has none")

        // Tabs shrinks the page into its card over a blur of it, and the bar stays.
        bar.tabsButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isTabSwitcherOpen)
        XCTAssertFalse(switcher.isHidden)
        try await Task.sleep(for: .milliseconds(80))
        let shrinking = try XCTUnwrap(switcher.subviews.last as? TabCard, "The page on its way into its card")
        XCTAssertEqual(switcher.cells[0].caption.alpha, 1, "A stationary card's title is already visible")
        XCTAssertEqual(switcher.cells[0].caption.transform, .identity)
        XCTAssertNil(switcher.cells[0].caption.layer.animation(forKey: "flight.opacity"))
        XCTAssertNotNil(switcher.cells[1].caption.layer.animation(forKey: "flight.opacity"), "Only the moving title reveals")
        XCTAssertLessThan(try XCTUnwrap(shrinking.layer.presentation()).frame.width, browser.view.bounds.width)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(switcher.subviews.contains { $0 is TabCard }, "The page has landed in its card")
        XCTAssertEqual(switcher.cells.count, 2)
        XCTAssertEqual(switcher.grid.alpha, 1)
        XCTAssertEqual(switcher.cells[1].card.alpha, 1)
        XCTAssertEqual(switcher.cells[0].caption.alpha, 1, "The titles show")
        let caption = switcher.cells[0]
        XCTAssertNotNil(caption.favicon.image, "The icon beside the title")
        XCTAssertNil(switcher.cells[1].favicon.image, "A blank square without one")
        XCTAssertEqual(caption.favicon.frame.midY, caption.title.frame.midY, accuracy: 1, "In line with the title")
        XCTAssertLessThan(caption.favicon.frame.maxX, caption.title.frame.minX)
        XCTAssertGreaterThan(caption.favicon.layer.cornerRadius, 0, "Square icons round off a little")
        let left = switcher.cells[0].frame, right = switcher.cells[1].frame
        XCTAssertGreaterThan(left.maxX, right.minX, "The horizontal deck overlaps its cards")
        XCTAssertGreaterThan(right.width, browser.view.bounds.width*0.65, "Large page previews")
        XCTAssertLessThan(caption.caption.frame.maxY, caption.card.frame.minY, "Title above the page")
        XCTAssertTrue(bar.tabsButton.showsSwitcher, "Tabs becomes an empty square")
        XCTAssertEqual(bar.home.alpha, 1, "The bar stays, with New Page and More")
        XCTAssertEqual(bar.moreButton.tintColor, BottomBar.plusTint, "More's dots are as soft as New Page's plus")
        XCTAssertEqual(browser.preferredStatusBarStyle, .default)

        // Tabs can be pressed as quickly as wanted, each press turning the page around where it is.
        bar.tabsButton.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(browser.isTabSwitcherOpen)
        try await Task.sleep(for: .milliseconds(80))
        let growing = try XCTUnwrap(switcher.moving)
        let grown = try XCTUnwrap(growing.layer.presentation()).frame.width
        bar.tabsButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isTabSwitcherOpen, "Tabs again turns it back before it has grown")
        XCTAssertTrue(switcher.moving === growing, "The same page, from where it was")
        // It carries its momentum a little, then heads back into its card.
        try await Task.sleep(for: .milliseconds(60))
        let turning = try XCTUnwrap(growing.layer.presentation()).frame.width
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(try XCTUnwrap(growing.layer.presentation()).frame.width, turning)
        XCTAssertGreaterThan(grown, switcher.cardSize.width, "It was partway grown")
        bar.tabsButton.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(browser.isTabSwitcherOpen)
        bar.tabsButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isTabSwitcherOpen)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(switcher.moving, "Settled in its card")
        XCTAssertFalse(switcher.isHidden)
        XCTAssertEqual(switcher.grid.alpha, 1)

        // Choosing a card grows it back into its page.
        switcher.cells[0].onSelect()
        XCTAssertFalse(browser.isTabSwitcherOpen)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(switcher.isHidden)
        XCTAssertEqual(browser.tabIndex, 0)
        XCTAssertTrue(browser.webView === first)
        XCTAssertTrue(first.superview === browser.content)
        XCTAssertNil(browser.tabs[1].webView.superview)
        XCTAssertFalse(bar.tabsButton.showsSwitcher)

        // A short swipe up the bar springs back; a longer one drops the page into its card.
        browser.beginTabSwipe()
        browser.updateTabSwipe(CGPoint(x: 0, y: -60))
        XCTAssertTrue(browser.isTabSwitcherOpen)
        let following = try XCTUnwrap(switcher.subviews.last as? TabCard)
        XCTAssertLessThan(following.frame.width, browser.view.bounds.width, "The page shrinks with the finger")
        XCTAssertLessThan(following.frame.maxY, browser.view.bounds.maxY)
        browser.endTabSwipe(velocity: .zero)
        XCTAssertFalse(browser.isTabSwitcherOpen)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(switcher.isHidden)
        browser.beginTabSwipe()
        browser.updateTabSwipe(CGPoint(x: 0, y: -300))
        XCTAssertGreaterThan(switcher.swipeProgress, 0.25)
        browser.endTabSwipe(velocity: .zero)
        XCTAssertTrue(browser.isTabSwitcherOpen)

        // A tap on the page as it drops in grows it back, where it shows.
        try await Task.sleep(for: .milliseconds(60))
        let landing = try XCTUnwrap(switcher.moving)
        let shown = try XCTUnwrap(landing.layer.presentation()).frame
        XCTAssertTrue(switcher.hitTest(CGPoint(x: shown.midX, y: shown.midY), with: nil) === landing)
        browser.selectTab(browser.tabIndex)
        XCTAssertFalse(browser.isTabSwitcherOpen)
        XCTAssertTrue(switcher.moving === landing)

        // A swipe up as it grows catches it where it is, and drops it back in.
        try await Task.sleep(for: .milliseconds(80))
        let caughtFrame = try XCTUnwrap(landing.layer.presentation()).frame
        browser.beginTabSwipe()
        XCTAssertTrue(browser.isTabSwitcherOpen)
        browser.updateTabSwipe(.zero)
        XCTAssertEqual(landing.frame.midX, caughtFrame.midX, accuracy: 2, "Caught where it showed")
        XCTAssertEqual(landing.frame.width, caughtFrame.width, accuracy: 2)
        browser.updateTabSwipe(CGPoint(x: 0, y: -200))
        browser.endTabSwipe(velocity: CGPoint(x: 0, y: -800))
        XCTAssertTrue(browser.isTabSwitcherOpen)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(switcher.isHidden)
        XCTAssertEqual(switcher.grid.alpha, 1)
        XCTAssertFalse(switcher.subviews.contains { $0 is TabCard })

        // Closing a card closes its tab; the last one stays.
        switcher.cells[1].onClose()
        XCTAssertEqual(browser.tabs.count, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(switcher.cells.count, 1)
        XCTAssertTrue(switcher.cells[0].closeButton.isHidden)
        browser.selectTab(0)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(switcher.isHidden)
    }

    @MainActor func testMenuAddressExpandsIntactIntoAFocusedSelectedURLAndClearsWithoutReloading() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let keyboardGuide = browser.view.keyboardLayoutGuide
        let url = try XCTUnwrap(URL(string: "https://www.example.test/articles?id=42#section"))
        try await load("<html><body><input value='Keep this form'><script>window.keepMe = 42</script></body></html>",
                       in: browser.webView, baseURL: url)
        let original = browser.webView, bar = browser.bottomBar
        bar.moreButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(500))
        let address = bar.menu.address
        let initialLabelX = address.host.frame.minX
        let initialTop = bar.frame.minY
        let initialAddressFrame = address.frame
        let initialReloadCenter = address.reloadButton.center
        XCTAssertEqual(address.host.text, "example.test")
        XCTAssertFalse(address.lock.isHidden)
        address.sendActions(for: .touchUpInside)
        XCTAssertEqual(bar.panel, .search)
        XCTAssertTrue(bar.shown === bar.search)
        XCTAssertTrue(bar.search.editingAddress === address)
        XCTAssertTrue(address.superview === bar.search)
        XCTAssertTrue(bar.search.field.superview === address)
        XCTAssertEqual(address.frame, initialAddressFrame, "The field surface retains its size and placement in the sheet")
        XCTAssertEqual(address.alpha, 1)
        XCTAssertEqual(address.transform, .identity, "The URL bar never takes the contents' blur/scale morph")
        XCTAssertFalse(address.subviews.contains { $0 is UIImageView && $0 !== address.lock },
                       "No blurred snapshot is laid over the address")
        XCTAssertEqual(address.host.text, url.absoluteString)
        XCTAssertEqual(bar.search.field.text, url.absoluteString)
        XCTAssertEqual(address.reloadButton.symbolName, "xmark")
        XCTAssertEqual(address.reloadButton.center, initialReloadCenter)
        XCTAssertTrue(address.reloadButton.subviews.contains { $0.subviews.contains { $0 is UIImageView } }
                      || UIAccessibility.isReduceMotionEnabled, "The icon uses the Send/Stop blur swap")
        XCTAssertTrue(bar.search.field.isFirstResponder, "The keyboard starts opening in the tap's event, before the spring finishes")
        let immediateSelection = try XCTUnwrap(bar.search.field.selectedTextRange)
        XCTAssertEqual(bar.search.field.offset(from: bar.search.field.beginningOfDocument, to: immediateSelection.start), 0)
        XCTAssertEqual(bar.search.field.offset(from: immediateSelection.start, to: immediateSelection.end), url.absoluteString.utf16.count)
        XCTAssertTrue(bar.menu.subviews.contains { $0 is UIImageView } || UIAccessibility.isReduceMotionEnabled,
                      "Only the removed menu contents use the blurred crossfade")
        if !UIAccessibility.isReduceMotionEnabled {
            // Keyboard startup can delay the first display frame. Observe the first moving
            // frame rather than assuming it has been rendered at exactly 50 ms.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(10))
                if let x = address.host.layer.presentation()?.frame.minX, x < initialLabelX { break }
            }
            let movingX = try XCTUnwrap(address.host.layer.presentation()?.frame.minX)
            XCTAssertLessThan(movingX, initialLabelX)
            XCTAssertGreaterThan(movingX, address.host.frame.minX, "The label travels left over the spring's duration")
            XCTAssertGreaterThan(try XCTUnwrap(bar.layer.presentation()?.frame.minY), bar.frame.minY)
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertLessThan(bar.frame.minY, initialTop)
        XCTAssertEqual(bar.bounds.height, (browser.view.bounds.height*BrowserViewController.panelHeightFraction).rounded(), accuracy: 1)
        XCTAssertEqual(browser.content.transform.a, PageRecede.scale, accuracy: 0.001)
        XCTAssertEqual(browser.content.transform.ty, PageRecede.drop, accuracy: 0.5)
        XCTAssertEqual(address.host.frame.minX, bar.search.field.textRect(forBounds: address.bounds).minX, accuracy: 0.5)
        XCTAssertTrue(address.lock.isHidden)
        XCTAssertTrue(address.backButton.isHidden)
        XCTAssertTrue(address.forwardButton.isHidden)
        XCTAssertEqual(bar.menu.alpha, 0)
        XCTAssertTrue(bar.search.field.isFirstResponder)
        XCTAssertGreaterThan(keyboardGuide.layoutFrame.height, 150)
        let selection = try XCTUnwrap(bar.search.field.selectedTextRange)
        XCTAssertEqual(bar.search.field.offset(from: bar.search.field.beginningOfDocument, to: selection.start), 0)
        XCTAssertEqual(bar.search.field.offset(from: selection.start, to: selection.end), url.absoluteString.utf16.count)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
            _ = browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Expanded URL editor"; attachment.lifetime = .keepAlways; add(attachment)
        address.reloadButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(bar.search.field.text, "")
        XCTAssertTrue(bar.search.candidates.contains { $0.symbol == "globe" && $0.url != nil }, "An empty field offers learned/recent links")
        XCTAssertTrue(bar.search.field.isFirstResponder)
        XCTAssertTrue(browser.webView === original)
        XCTAssertEqual(bar.tabsButton.count, 1)
        let kept = try await original.evaluateJavaScript("window.keepMe") as? Int
        XCTAssertEqual(kept, 42, "X clears the input instead of reloading the page")
        address.reloadButton.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(browser.isPanelOpen, "X on an empty address closes the dialog")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(browser.webView === original)
        let stillKept = try await original.evaluateJavaScript("window.keepMe") as? Int
        XCTAssertEqual(stillKept, 42, "Closing leaves the page as it was")
        XCTAssertFalse(bar.search.field.isFirstResponder)
        bar.moreButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(address.superview === bar.menu)
        XCTAssertFalse(address.isEditingURL)
        XCTAssertEqual(address.host.text, "example.test")
        XCTAssertEqual(address.reloadButton.symbolName, "arrow.clockwise")
        XCTAssertFalse(address.lock.isHidden)
        XCTAssertEqual(address.lock.alpha, 1)
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(600))
        bar.newPageButton.sendActions(for: .primaryActionTriggered)
        XCTAssertNil(bar.search.editingAddress)
        XCTAssertTrue(bar.search.field.superview === bar.search)
        XCTAssertEqual(bar.search.field.text, "")
        XCTAssertEqual(bar.search.field.backgroundColor, SearchPanel.fill)
        // New Page has the address editor's X: it clears what's typed, then closes the sheet.
        let clear = bar.search.clearButton
        XCTAssertEqual(bar.search.field.clearButtonMode, .never)
        XCTAssertFalse(clear.isHidden, "Always there, even empty")
        XCTAssertEqual(clear.symbolName, "xmark")
        XCTAssertEqual(clear.center.x, bar.search.field.frame.maxX-AddressBar.outerCentre, accuracy: 0.5)
        bar.search.field.text = "rise"
        bar.search.field.sendActions(for: .editingChanged)
        clear.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(bar.search.field.text, "")
        XCTAssertTrue(browser.isPanelOpen, "Clearing leaves the sheet open")
        clear.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(browser.isPanelOpen, "X on an empty field closes the sheet")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(browser.webView === original)
    }

    @MainActor func testEditingAnAddressNavigatesItsTabAndAnInterruptedExpansionDoesNotFocusLater() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        try await load("<html><body>A local original page.</body></html>", in: browser.webView,
                       baseURL: URL(string: "https://example.test/original")!)
        let original = browser.webView, bar = browser.bottomBar
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(500))
        bar.menu.address.sendActions(for: .touchUpInside)
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(browser.isPanelOpen)
        XCTAssertFalse(bar.search.field.isFirstResponder, "A canceled spring doesn't bring up the keyboard later")
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(500))
        bar.menu.address.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.search.field.isFirstResponder)
        // Typing before the spring completes must not be reselected by its completion callback.
        bar.search.field.text = "https://example.com/"
        bar.search.field.sendActions(for: .editingChanged)
        bar.search.field.selectedTextRange = bar.search.field.textRange(from: bar.search.field.endOfDocument,
                                                                      to: bar.search.field.endOfDocument)
        try await Task.sleep(for: .milliseconds(700))
        let caret = try XCTUnwrap(bar.search.field.selectedTextRange)
        XCTAssertTrue(caret.isEmpty)
        XCTAssertEqual(bar.search.field.offset(from: bar.search.field.beginningOfDocument, to: caret.start), "https://example.com/".utf16.count)

        XCTAssertFalse(bar.search.textFieldShouldReturn(bar.search.field))
        XCTAssertFalse(browser.isPanelOpen)
        XCTAssertFalse(bar.search.field.isFirstResponder)
        XCTAssertTrue(browser.webView === original, "Go navigates the existing web view, preserving its history")
        XCTAssertEqual(bar.tabsButton.count, 1, "Editing a URL doesn't add a tab")
        original.stopLoading()
    }

    @MainActor func testFindTurnsMoresPanelIntoAFindFieldThatStepsThroughMatchesAndKeepsTheScroll() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let bar = browser.bottomBar, find = bar.find
        let filler = String(repeating: "<p>Nothing to see here, just filler text.</p>", count: 40)
        try await load("<html><body><p>needle one</p>\(filler)<p>needle two</p>\(filler)<p>needle three</p>\(filler)<p>needle four</p></body></html>",
                       in: browser.webView, baseURL: URL(string: "https://example.com/")!)

        // Find swaps More's panel for a focused find field, leaving the page clear and in place.
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(400))
        bar.menu.findTile.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(browser.isPanelOpen, "Find keeps the panel open")
        XCTAssertEqual(bar.panel, .find)
        XCTAssertTrue(bar.shown === find)
        XCTAssertTrue(find.field.isFirstResponder)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(browser.content.transform, .identity, "The page doesn't recede behind Find")
        XCTAssertEqual(find.field.frame.height, SearchPanel.fieldHeight)
        XCTAssertEqual(find.field.backgroundColor, SearchPanel.fill, "Styled as the other fields")
        XCTAssertFalse(find.nextButton.isEnabled, "Nothing to step through yet")
        XCTAssertEqual(find.field.rightViewMode, .always)
        XCTAssertTrue(find.field.rightView === find.askButton.superview, "An empty search offers Ask instead of results")
        XCTAssertFalse(find.askButton.isHidden)
        XCTAssertNil(find.field.accessibilityValue)

        // Typing counts the matches; Next, Return and Previous step through them.
        find.field.text = "needle"
        find.field.sendActions(for: .editingChanged)
        XCTAssertFalse(find.field.rightView === find.askButton.superview, "Ask disappears as soon as typing starts")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(find.count.total, 4)
        XCTAssertEqual(find.count.index, 0)
        XCTAssertTrue(find.nextButton.isEnabled)
        XCTAssertEqual(find.field.rightViewMode, .always)
        find.nextButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(find.count.index, 1)
        XCTAssertFalse(find.textFieldShouldReturn(find.field), "Return keeps the field")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(find.count.index, 2)
        find.nextButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(find.count.index, 3)
        let scrolled = browser.webView.scrollView.contentOffset.y
        XCTAssertGreaterThan(scrolled, 100, "The page scrolls to the match")
        find.previousButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(find.count.index, 2)
        find.field.text = "needle t"
        find.field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(find.count.total, 2)
        find.field.text = "haystack"
        find.field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(find.count.total, 0)
        XCTAssertEqual(find.field.textColor, .systemRed, "No matches, as on the Mac")
        XCTAssertEqual(find.field.accessibilityValue, "No matches")
        XCTAssertFalse(find.nextButton.isEnabled)
        find.field.text = ""
        find.field.sendActions(for: .editingChanged)
        XCTAssertNil(find.count.total, "Clearing immediately removes the previous result")
        XCTAssertTrue(find.field.rightView === find.askButton.superview)
        XCTAssertEqual(find.field.textColor, .label)
        XCTAssertNil(find.field.accessibilityValue)
        try await Task.sleep(for: .milliseconds(300))
        let cleared = try await browser.webView.callAsyncJavaScript(
            "return CSS.highlights.get('rise-find')?.size ?? 0", arguments: [:], in: nil, contentWorld: PageFind.world) as? Int
        XCTAssertEqual(cleared, 0, "An empty query removes the page highlights")
        find.field.text = "needle"
        find.field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(500))
        find.nextButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(600))

        // Closing takes the highlights off and leaves the page where it was.
        let kept = browser.webView.scrollView.contentOffset.y
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(find.field.isFirstResponder)
        XCTAssertEqual(browser.webView.scrollView.contentOffset.y, kept, accuracy: 1, "The scroll stays")
        let highlighted = try await browser.webView.callAsyncJavaScript(
            "return CSS.highlights.get('rise-find')?.size ?? 0", arguments: [:], in: nil, contentWorld: PageFind.world) as? Int
        XCTAssertEqual(highlighted, 0)
    }

    @MainActor func testReturnWithNoMatchesKeepsTheQueryInAskUntilSend() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        try await load("<html><body>A needle in the page.</body></html>", in: browser.webView)
        let find = browser.bottomBar.find
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(500))
        var questions: [String] = []
        let pending = AsyncThrowingStream<String, Error>.makeStream()
        find.answer = { question, _ in questions.append(question); return pending.stream }
        defer { pending.continuation.finish() }
        find.field.text = "Why is this interesting?"
        find.field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(find.count.total, 0)
        // A new query must not inherit the previous query's zero-results Return action.
        find.field.text = "needle"
        find.field.sendActions(for: .editingChanged)
        _ = find.textFieldShouldReturn(find.field)
        XCTAssertEqual(find.mode, .find)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(find.count.total, 1)
        _ = find.textFieldShouldReturn(find.field)
        XCTAssertEqual(find.mode, .find, "Return still steps through a successful search")

        let question = "Why is this interesting?"
        find.field.text = question
        find.field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(find.count.total, 0)
        XCTAssertFalse(find.textFieldShouldReturn(find.field))
        XCTAssertEqual(find.mode, .ask)
        XCTAssertEqual(find.field.text, question)
        XCTAssertEqual(find.field.placeholder, "Ask about the Page")
        XCTAssertEqual(find.field.textColor, .label, "An Ask question is no longer a failed search")
        XCTAssertNil(find.field.accessibilityValue)
        XCTAssertTrue(find.field.isFirstResponder)
        XCTAssertTrue(find.field.rightView === find.modeButton.superview)
        XCTAssertTrue(find.sendButton.isEnabled)
        XCTAssertFalse(find.isAnswering)
        XCTAssertTrue(questions.isEmpty, "The first Return switches modes without sending")
        find.sendButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(questions, [question])
        XCTAssertTrue(find.isAnswering)
        browser.closePanel()
    }

    @MainActor func testAskSheetGrowsWithRevealedLinesInsteadOfQueuedText() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Reduce Motion intentionally reveals words immediately")
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let find = browser.bottomBar.find, bar = browser.bottomBar
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(500))
        find.enterAsk()
        _ = find.field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(500))
        let initialHeight = bar.bounds.height
        // A whole response arrives in one burst, while its words still reveal gradually.
        find.answerView.show("First line.\nSecond line.\nThird line.", finished: true)
        let start = CACurrentMediaTime()
        XCTAssertEqual(find.answerHeight, 0, "Hidden text does not pre-expand the sheet")
        XCTAssertEqual(bar.bounds.height, initialHeight)
        find.answerView.advance(at: start+0.04)
        let firstLine = find.answerHeight
        XCTAssertGreaterThan(firstLine, FindPanel.answerTopPadding+FindPanel.answerBottomPadding)
        XCTAssertEqual(bar.bounds.height, initialHeight+firstLine, accuracy: 1)
        find.answerView.advance(at: start+0.075)
        XCTAssertEqual(find.answerHeight, firstLine, "Another word on the same line doesn't expand the sheet")
        find.answerView.advance(at: start+0.11)
        let secondLine = find.answerHeight
        XCTAssertGreaterThan(secondLine, firstLine)
        XCTAssertEqual(bar.bounds.height, initialHeight+secondLine, accuracy: 1)
        find.answerView.advance(at: start+0.175)
        let thirdLine = find.answerHeight
        XCTAssertGreaterThan(thirdLine, secondLine)
        XCTAssertEqual(bar.bounds.height, initialHeight+thirdLine, accuracy: 1)
        find.answerView.advance(at: start+0.5)
        XCTAssertEqual(find.answerHeight, thirdLine, "Settling token colors doesn't resize the sheet")
        find.maximumAnswerHeight = 25
        XCTAssertEqual(find.answerHeight, FindPanel.answerTopPadding+FindPanel.answerBottomPadding+25,
                       "Long answers remain capped so the answer can scroll")
        browser.closePanel()
    }

    @MainActor func testAskStreamsTheSharedAssistantIntoFindAndHighlightsItsSupportingPassage() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let page = browser.webView, find = browser.bottomBar.find
        let quote = "The release is planned for March 3, 2027."
        try await load("<html><head><title>Release notes</title></head><body><p>\(quote)</p></body></html>",
                       in: page, baseURL: URL(string: "https://example.test/release")!)
        var sse = ""
        for content in ["{\"snippet\":\"\(quote)\"}\n", "It ships ", "**March 3, 2027**."] {
            let chunk: [String: Any] = ["choices": [["delta": ["content": content]]]]
            sse += "data: "+String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)+"\n\n"
        }
        sse += "data: [DONE]\n\n"
        MobileAssistantProtocol.prepare(Data(sse.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileAssistantProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var histories: [[PageAssistant.Turn]] = []
        find.answer = { question, history in
            histories.append(history)
            return PageAssistant.answer(question, history: history,
                page: { try await PageAssistant.snapshot(of: page) },
                highlight: { await PageFind.highlightPassage($0, in: page) }, session: session)
        }
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(find.field.rightView === find.askButton.superview)
        let modeButton = find.modeButton
        let askWidth = modeButton.bounds.width, askX = modeButton.center.x
        find.askButton.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(find.findButton === modeButton, "Ask and Find are the same moving button")
        XCTAssertGreaterThan(modeButton.bounds.width, askWidth)
        XCTAssertLessThan(modeButton.center.x, askX)
        XCTAssertEqual(find.mode, .ask)
        XCTAssertEqual(find.field.placeholder, "Ask about the Page")
        XCTAssertTrue(find.field.isFirstResponder)
        XCTAssertFalse(find.sendButton.isEnabled)
        XCTAssertEqual(find.sendButton.tintColor, .tertiaryLabel, "An empty question greys out Send")
        find.field.text = "When does it ship?"
        find.field.sendActions(for: .editingChanged)
        XCTAssertTrue(find.sendButton.isEnabled)
        XCTAssertEqual(find.sendButton.tintColor, .label)
        XCTAssertFalse(find.textFieldShouldReturn(find.field))
        XCTAssertTrue(find.isAnswering)
        if !UIAccessibility.isReduceMotionEnabled { XCTAssertTrue(find.shimmer.isRunning) }
        XCTAssertFalse(find.field.isFirstResponder)
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(find.isAnswering)
        XCTAssertFalse(find.shimmer.isRunning)
        XCTAssertEqual(find.answerView.answer, "It ships **March 3, 2027**.")
        XCTAssertEqual(find.answerView.text, "It ships March 3, 2027.", "Markdown markers never flash in the answer")
        XCTAssertEqual(find.field.text, "When does it ship?")
        XCTAssertGreaterThan(find.bounds.height, SearchPanel.fieldHeight)
        XCTAssertFalse(find.answerView.isHidden)
        XCTAssertGreaterThan(find.answerView.bounds.height, 10)
        XCTAssertLessThanOrEqual(find.answerView.frame.maxY, find.bounds.height+1)
        let highlighted = try await page.callAsyncJavaScript(
            "return CSS.highlights.get('rise-passage')?.size ?? 0", arguments: [:], in: nil, contentWorld: PageFind.world) as? Int
        XCTAssertEqual(highlighted, 1)
        let body = try XCTUnwrap(MobileAssistantProtocol.lastBody())
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(request["model"] as? String, "openai/gpt-6-luna")
        let messages = try XCTUnwrap(request["messages"] as? [[String: String]])
        XCTAssertTrue(messages.first?["content"]?.contains(quote) == true, "The current page supplies the context")
        XCTAssertFalse(find.answerView.text.contains("gpt-6-luna"))
        XCTAssertTrue(histories[0].isEmpty)
        find.field.text = "Which year?"
        find.field.sendActions(for: .editingChanged)
        find.sendButton.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(histories.last?.count, 1)
        XCTAssertEqual(histories.last?.first?.question, "When does it ship?")
        find.findButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(find.mode, .find)
        XCTAssertEqual(find.field.placeholder, "Find on Page")
        XCTAssertTrue(find.answerView.answer.isEmpty)
        XCTAssertTrue(find.field.rightView === find.askButton.superview)
        XCTAssertEqual(modeButton.bounds.width, askWidth)
        XCTAssertEqual(modeButton.center.x, askX)
        try await Task.sleep(for: .milliseconds(300))
        let cleared = try await page.callAsyncJavaScript(
            "return CSS.highlights.get('rise-passage')?.size ?? 0", arguments: [:], in: nil, contentWorld: PageFind.world) as? Int
        XCTAssertEqual(cleared, 0)
        browser.closePanel()
    }

    @MainActor func testFindCounterStaysCenteredWithAndWithoutTheOnscreenKeyboard() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let keyboardGuide = browser.view.keyboardLayoutGuide
        try await load("<html><body>A local page with no matches.</body></html>", in: browser.webView)
        let find = browser.bottomBar.find
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(400))
        browser.bottomBar.menu.findTile.sendActions(for: .primaryActionTriggered)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(find.field.isFirstResponder)
        XCTAssertGreaterThan(keyboardGuide.layoutFrame.height, 150,
                             "The onscreen keyboard appears, rather than just giving the field focus")
        find.field.text = "missing"
        find.field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(find.count.total, 0)
        _ = find.field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(700))
        let counter = try XCTUnwrap(find.field.rightView?.subviews.first)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: counter.bounds.size, format: format).image { _ in
            _ = counter.drawHierarchy(in: counter.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Find counter with keyboard hidden"; attachment.lifetime = .keepAlways
        add(attachment)
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let ink = (0..<height).filter { y in (0..<width).contains { x in pixels[(y*width+x)*4+3] > 30 } }
        let first = try XCTUnwrap(ink.first), last = try XCTUnwrap(ink.last)
        XCTAssertEqual(Double(first+last)/2, Double(height)/2, accuracy: 3,
                       "The rendered count is centered, even when the field sits in the window's safe area")
        XCTAssertTrue(find.field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(keyboardGuide.layoutFrame.height, 150,
                             "Refocusing brings the onscreen keyboard back")
        browser.closePanel()
    }

    @MainActor func testAskAccessoriesStayAlignedWhileDraggingAndRefocusingAnAnswer() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let bar = browser.bottomBar, find = bar.find
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(find.askButton.backgroundColor, bar.newPageButton.backgroundColor)
        XCTAssertEqual(find.findButton.backgroundColor, bar.newPageButton.backgroundColor)
        XCTAssertLessThan(find.askButton.bounds.height, find.field.bounds.height)
        XCTAssertGreaterThan(find.askButton.layer.cornerRadius, 0)
        find.enterAsk()
        let pending = AsyncThrowingStream<String, Error>.makeStream()
        find.answer = { _, _ in pending.stream }
        find.field.text = "What is the top story on this page?"
        find.submitQuestion()
        XCTAssertEqual(find.sendButton.symbolName, "stop.circle.fill")
        pending.continuation.yield(String(repeating: "A detailed answer about the page. ", count: 12))
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertTrue(find.isAnswering)
        XCTAssertEqual(find.bounds.maxY-find.answerView.frame.maxY, FindPanel.answerBottomPadding, accuracy: 1)

        func assertAccessoriesStayAtTheRight(file: StaticString = #filePath, line: UInt = #line) throws {
            bar.setNeedsLayout(); bar.layoutIfNeeded()
            find.setNeedsLayout(); find.layoutIfNeeded()
            find.field.layoutIfNeeded()
            let accessory = try XCTUnwrap(find.field.rightView, file: file, line: line)
            XCTAssertEqual(accessory.frame.maxX, find.field.bounds.maxX, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThan(accessory.frame.minX, find.field.bounds.midX, file: file, line: line)
            XCTAssertLessThanOrEqual(find.field.textRect(forBounds: find.field.bounds).maxX,
                                     accessory.frame.minX+1, file: file, line: line)
            XCTAssertGreaterThan(find.sendButton.frame.minX, find.findButton.frame.maxX, file: file, line: line)
            XCTAssertEqual(find.sendButton.frame.minX-find.findButton.frame.maxX, 4, accuracy: 0.5, file: file, line: line)
        }
        let restingTop = bar.frame.minY
        for distance: CGFloat in [-20, -60, -160, -320] {
            browser.dragPanel(to: distance)
            try assertAccessoriesStayAtTheRight()
            XCTAssertLessThan(bar.frame.minY, restingTop, "Upward dragging retains resistance")
            XCTAssertGreaterThan(bar.frame.minY, restingTop-41, "Resistance bounds the stretch")
        }
        browser.finishPanelDrag(at: -320)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(bar.frame.minY, restingTop, accuracy: 1)
        try assertAccessoriesStayAtTheRight()

        // Finish the response, then refocus its question without the accessories moving into it.
        pending.continuation.finish()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(find.sendButton.symbolName, "arrow.up.circle.fill")
        XCTAssertEqual(find.sendButton.subviews.compactMap { $0 as? UIImageView }.count, 1,
                       "The outgoing icon is removed after the transition")
        let rect = find.field.textRect(forBounds: find.field.bounds)
        let hit = window.hitTest(find.field.convert(CGPoint(x: rect.midX, y: rect.midY), to: window), with: nil)
        XCTAssertTrue(hit === find.field || hit?.isDescendant(of: find.field) == true,
                      "The answer does not intercept taps into the question")
        XCTAssertTrue(find.field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(find.field.isFirstResponder)
        try assertAccessoriesStayAtTheRight()
        let kept = find.field.text
        find.field.text = "A follow-up question"
        find.field.sendActions(for: .editingChanged)
        XCTAssertNotEqual(find.field.text, kept)
        XCTAssertEqual(find.mode, .ask)
        try assertAccessoriesStayAtTheRight()
        browser.closePanel()
    }

    @MainActor func testClosingAskCancelsLateTokensAndAnErrorCanBeRetried() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let find = browser.bottomBar.find
        let pending = AsyncThrowingStream<String, Error>.makeStream()
        find.answer = { _, _ in pending.stream }
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(400))
        find.enterAsk()
        find.field.text = "What is this page?"
        find.submitQuestion()
        XCTAssertTrue(find.isAnswering)
        browser.closePanel()
        pending.continuation.yield("A late answer must not reopen the sheet.")
        pending.continuation.finish()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(browser.isPanelOpen)
        XCTAssertFalse(find.isAnswering)
        XCTAssertFalse(find.shimmer.isRunning)
        XCTAssertEqual(find.answerView.answer, "")
        XCTAssertEqual(find.mode, .find)
        find.answer = { _, _ in AsyncThrowingStream { $0.finish(throwing: PageAssistant.Failure.service("Try again later.")) } }
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(400))
        find.enterAsk()
        find.field.text = "Try this question"
        find.submitQuestion()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(find.isAnswering)
        XCTAssertEqual(find.answerView.answer, "Try again later.")
        XCTAssertTrue(find.sendButton.isEnabled)
        find.answer = { _, history in
            XCTAssertTrue(history.isEmpty, "Failed requests do not enter the conversation")
            return AsyncThrowingStream { $0.yield("A successful retry."); $0.finish() }
        }
        find.submitQuestion()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(find.answerView.text, "A successful retry.")
        XCTAssertFalse(find.isAnswering)
        browser.closePanel()
    }

    @MainActor func testAnAnsweredQuestionDisablesSendUntilEditedAndIsSelectedOnTap() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let find = browser.bottomBar.find
        var asked = 0
        find.answer = { _, _ in
            asked += 1
            return AsyncThrowingStream { $0.yield("An answer."); $0.finish() }
        }
        browser.openPanel(.find)
        try await Task.sleep(for: .milliseconds(400))
        find.enterAsk()
        find.field.text = "What is this page?"
        find.field.sendActions(for: .editingChanged)
        XCTAssertTrue(find.sendButton.isEnabled)
        find.submitQuestion()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(find.isAnswering)
        XCTAssertEqual(find.sendButton.symbolName, "arrow.up.circle.fill")
        XCTAssertFalse(find.sendButton.isEnabled, "The same question again would repeat the answer")
        XCTAssertFalse(find.textFieldShouldReturn(find.field))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(asked, 1, "Return doesn't send it again either")

        // Tapping the field selects the question, ready to replace.
        XCTAssertTrue(find.field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(100))
        let selected = try XCTUnwrap(find.field.selectedTextRange)
        XCTAssertEqual(find.field.text(in: selected), "What is this page?")

        // Any change makes it sendable again.
        find.field.text = "What is this page about?"
        find.field.sendActions(for: .editingChanged)
        XCTAssertTrue(find.sendButton.isEnabled)
        XCTAssertTrue(find.field.becomeFirstResponder())
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(400))
    }

    @MainActor func testHoldingNewPageShowsAWaveformAndFillsTheSearchWithWhatWasSaid() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let bar = browser.bottomBar, search = bar.search
        XCTAssertTrue(bar.newPageButton.gestureRecognizers?.contains { $0 is UILongPressGestureRecognizer } ?? false)

        // Listening swaps the plus for seven rounded red bars that follow the level.
        var level: Float = 0
        bar.setListening(true) { level }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(bar.waveform.alpha, 1)
        let bars = try XCTUnwrap(bar.waveform.layer.sublayers)
        XCTAssertEqual(bars.count, 7)
        XCTAssertEqual(bars[3].frame.height, VoiceWaveform.barWidth, accuracy: 0.5, "Dots while quiet")
        XCTAssertEqual(bars[0].cornerRadius, VoiceWaveform.barWidth/2)
        level = 1
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(bars[3].frame.height, 12, "The middle bars rise with the voice")
        XCTAssertLessThanOrEqual(bars[3].frame.height, VoiceWaveform.maximumHeight)
        XCTAssertTrue(bar.newPageButton.bounds.contains(bar.waveform.convert(bars[0].frame, to: bar.newPageButton)))
        XCTAssertTrue(bar.newPageButton.bounds.contains(bar.waveform.convert(bars[6].frame, to: bar.newPageButton)))
        bar.setListening(false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(bar.waveform.alpha, 0, "The plus comes back")

        // Letting go opens New Page, a spinner where X would be until the words land in the field.
        browser.finishListening()
        XCTAssertTrue(browser.isPanelOpen)
        let opening = search.beginTranscribing()
        XCTAssertTrue(search.transcribing.isAnimating)
        search.layoutIfNeeded()
        XCTAssertEqual(search.transcribing.center.x, search.clearButton.center.x, accuracy: 1, "Where the X is")
        XCTAssertTrue(search.clearButton.isHidden)
        search.finishTranscribing("swift concurrency", for: opening)
        XCTAssertFalse(search.transcribing.isAnimating)
        XCTAssertEqual(search.field.text, "swift concurrency")
        XCTAssertFalse(search.clearButton.isHidden, "The X comes back")

        // A transcription for an earlier opening doesn't land in a later one.
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(600))
        browser.openPanel()
        let stale = opening
        _ = search.beginTranscribing()
        search.finishTranscribing("late", for: stale)
        XCTAssertEqual(search.field.text, "")
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(600))
    }

    @MainActor func testDarkPagesShowTheDarkSurfaceUntilTheyFirstPaint() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        defer { window.isHidden = true }
        let watcher = PagePaintWatcher.shared

        // A new page in dark mode is see-through until it paints, rather than WebKit's white.
        let page = WKWebView(frame: window.bounds, configuration: WKWebViewConfiguration())
        watcher.install(on: page, dark: true)
        XCTAssertFalse(page.isOpaque)
        XCTAssertEqual(page.backgroundColor, .clear)
        XCTAssertTrue(watcher.isTransparent(page))
        window.addSubview(page)
        defer { page.removeFromSuperview() }
        try await load("<html><body style='background:#111;color:#eee'>Dark page</body></html>", in: page,
                       baseURL: URL(string: "https://example.com/dark")!)
        for _ in 0..<40 where watcher.isTransparent(page) { try await Task.sleep(for: .milliseconds(50)) }
        // The first frame is reported from the page, or, if that's late, when the load finishes,
        // as the browser's navigation delegate does.
        watcher.didFinish(page)
        XCTAssertFalse(watcher.isTransparent(page), "Painted by its first frame or its finished load")
        XCTAssertTrue(page.isOpaque, "Opaque again once painted, so pages without a background get white")
        XCTAssertNotEqual(page.backgroundColor, .clear)

        // In light mode nothing changes.
        let light = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        watcher.install(on: light, dark: false)
        XCTAssertTrue(light.isOpaque)
        XCTAssertFalse(watcher.isTransparent(light))
    }

    func testSearchParsesGoogleSuggestionsAndTellsAddressesFromSearches() throws {
        let data = Data(#"["swi",["swift","swiss cheese","swim"],[],{"google:suggesttype":[]}]"#.utf8)
        XCTAssertEqual(SearchPanel.suggestions(from: data), ["swift", "swiss cheese", "swim"])
        XCTAssertEqual(SearchPanel.suggestions(from: Data("nope".utf8)), [])
        let suggest = try XCTUnwrap(SearchPanel.suggestionsURL(for: "a b&c"))
        XCTAssertEqual(URLComponents(url: suggest, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "a b&c")
        XCTAssertEqual(SearchPanel.destination(for: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(SearchPanel.destination(for: " http://example.com/a ")?.absoluteString, "http://example.com/a")
        XCTAssertEqual(SearchPanel.destination(for: "news.ycombinator.com/item?id=1")?.host, "news.ycombinator.com")
        XCTAssertEqual(SearchPanel.destination(for: "swift concurrency")?.host, "www.google.com")
        XCTAssertEqual(SearchPanel.destination(for: "e.g.")?.host, "www.google.com")
        XCTAssertNil(SearchPanel.destination(for: "  "))
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
            XCTAssertTrue(page.superview === browser.content)
            let statusBar = browser.view.safeAreaInsets.top
            XCTAssertGreaterThan(statusBar, 0)
            XCTAssertEqual(browser.topStrip.frame.height, statusBar)
            XCTAssertEqual(page.frame, CGRect(x: 0, y: statusBar, width: browser.view.bounds.width,
                                              height: browser.view.bounds.height-statusBar),
                           "The page lands below the status bar strip, where the Peek's strip left it")
            XCTAssertEqual(browser.topStrip.backgroundColor, peek.topColor, "The strip keeps the Peek's colour")
            XCTAssertTrue(browser.view.transform.isIdentity)
            XCTAssertEqual(browser.webView.url, current)
            let draft = try await page.evaluateJavaScript("document.getElementById('draft').value") as? String
            XCTAssertEqual(draft, "typed in Peek")

            XCTAssertTrue(browser.previousPages.last === original)
            browser.returnToPreviousPage()
            XCTAssertTrue(browser.webView === original)
            XCTAssertTrue(original.superview === browser.content)
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

/// Exercises the shared SSE transport on iPhone without a network dependency or API spend.
private final class MobileAssistantProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Data()
    nonisolated(unsafe) private static var body: Data?

    static func prepare(_ response: Data) {
        lock.lock(); defer { lock.unlock() }
        self.response = response; body = nil
    }
    static func lastBody() -> Data? {
        lock.lock(); defer { lock.unlock() }; return body
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let data = Self.response
        Self.body = request.httpBody
        if Self.body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            Self.body = body
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
