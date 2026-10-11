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
        XCTAssertEqual(bar.search.suggestions, [])
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
        XCTAssertEqual(SearchPanel.font.fontName, "OpenRunde-Medium", "The suggestions are in Open Runde")
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
        // for it, which then becomes the page, the previous one held for Back.
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
        XCTAssertTrue(browser.previousPages.last === original, "held for Back")
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
        XCTAssertEqual(bar.search.suggestions, [])
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
        XCTAssertFalse(address.backButton.isHidden, "Back to the page it replaced")
        XCTAssertTrue(address.forwardButton.isHidden, "Nowhere to go forward")
        XCTAssertEqual(bar.hitTest(CGPoint(x: grown.midX, y: grown.maxY-3), with: nil)?.isDescendant(of: bar.menu.address), true,
                       "Tapping the address doesn't make a new page")
        XCTAssertTrue(bar.hitTest(bar.convert(CGPoint(x: 20, y: 24), from: address), with: nil) === bar.menu.address.backButton)
        XCTAssertEqual(bar.menu.transform, .identity)
        XCTAssertEqual(bar.moreButton.backgroundColor, SearchPanel.fill)
        XCTAssertTrue(bar.menu.tiles.allSatisfy { $0.backgroundColor == SearchPanel.fill })
        bar.menu.pinTile.sendActions(for: .touchDown)
        XCTAssertEqual(bar.menu.pinTile.backgroundColor, SearchPanel.pressedFill, "Darker while pressed")
        bar.menu.pinTile.sendActions(for: .touchUpOutside)
        XCTAssertEqual(bar.menu.pinTile.backgroundColor, SearchPanel.fill)
        XCTAssertEqual(bar.menu.tiles.map(\.accessibilityLabel), ["Share", "Pin", "Find on Page", "Copy Link"])
        for tile in bar.menu.tiles {
            let frame = bar.convert(tile.frame, from: tile.superview)
            XCTAssertEqual(frame.width, frame.height, "Square")
            XCTAssertGreaterThan(frame.minY, grown.maxY)
            XCTAssertLessThanOrEqual(frame.maxY, bar.bounds.maxY-safeBottom+0.5)
        }

        // Back and Forward leave it open; Reload closes it, the bar's buttons returning.
        bar.menu.address.forwardButton.sendActions(for: .primaryActionTriggered)
        bar.menu.pinTile.sendActions(for: .primaryActionTriggered)
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
