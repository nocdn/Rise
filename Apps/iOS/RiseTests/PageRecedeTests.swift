import UIKit
import XCTest
@testable import RiseiOS

final class PageRecedeTests: XCTestCase {
    @MainActor func testDeviceCornerGeometrySurvivesScalingAndPanelsRestoreThePage() async throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Public concentric corners require iOS 26") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let browser = InteractionAudit.makeBrowser()
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let probe = UIView(frame: window.bounds)
        probe.isUserInteractionEnabled = false
        probe.alpha = 0
        probe.cornerConfiguration = .uniformCorners(radius: .containerConcentric(minimum: 0))
        window.insertSubview(probe, at: 0)
        probe.layoutIfNeeded()
        let expected = probe.effectiveRadius(corner: .allCorners)
        print("PUBLIC CORNERS radius=\(expected) bounds=\(window.bounds)")
        let page = browser.content
        XCTAssertEqual(PageRecede.screenCornerRadius(of: page), expected, accuracy: 0.01)
        let count = window.subviews.count
        for amount: CGFloat in [0.001, 0.05, 0.25, 1, 1.25, 0.25] {
            PageRecede.apply(amount, to: page)
            XCTAssertEqual(PageRecede.screenCornerRadius(of: page), expected, accuracy: 0.01,
                           "The shrinking page must not change its screen reference")
            XCTAssertEqual(window.subviews.count, count, "Reusing the geometry must not accumulate views")
            XCTAssertGreaterThan(page.layer.cornerRadius, 0)
            if expected > 0, amount == 0.001 {
                XCTAssertEqual(page.layer.cornerRadius*page.transform.a, expected, accuracy: 0.1,
                               "The first moving frame already has the screen's full rounding")
            }
        }
        PageRecede.apply(0, to: page)
        XCTAssertEqual(page.transform, .identity)
        XCTAssertEqual(page.layer.cornerRadius, 0, "Full-size content must not retain extra clipping")
        probe.removeFromSuperview()

        browser.webView.loadHTMLString("<meta name='viewport' content='width=device-width'><style>body{margin:0;background:#f8f8fb;font:18px system-ui}header{background:#5856d6;color:white;padding:70px 24px 30px}p{margin:25px}</style><header><h1>Rise corner check</h1></header><p>The page keeps the device's rounded corners as it recedes behind this panel.</p>", baseURL: nil)
        for _ in 0..<100 where browser.webView.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        let folder = URL.cachesDirectory.appending(path: "PageRecedeCapture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            browser.openPanel(.menu)
            try await Task.sleep(for: .milliseconds(550))
            XCTAssertGreaterThan(page.layer.cornerRadius, 0)
            XCTAssertEqual(page.layer.cornerCurve, .continuous)
            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appending(path: style == .light ? "menu-light.png" : "menu-dark.png"))
            browser.closePanel()
            // UIKit's spring can keep settling beyond its nominal duration. The corners
            // intentionally stay rounded until completion, including the return's tail.
            for _ in 0..<100 {
                if page.layer.cornerRadius == 0 && (page.layer.animationKeys() ?? []).isEmpty { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(page.transform, .identity)
            XCTAssertEqual(page.layer.cornerRadius, 0)
        }
        browser.openPanel(.search)
        try await Task.sleep(for: .milliseconds(550))
        let close = browser.bottomBar.search.clearButton
        let closePoint = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: window)
        let target = try XCTUnwrap(window.hitTest(closePoint, with: nil))
        XCTAssertTrue(target.isDescendant(of: close), "The geometry view must not intercept panel controls")
        let outside = CGPoint(x: window.bounds.midX, y: browser.bottomBar.frame.minY-20)
        XCTAssertFalse(window.hitTest(outside, with: nil) === page,
                       "The page's dismissal overlay must still receive outside taps")
        browser.closePanel()
    }

    @MainActor func testTabDeckKeepsEarlyRoundingAndInterruptedFlights() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let browser = InteractionAudit.makeBrowser()
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        browser.view.layoutIfNeeded()
        let folder = URL.cachesDirectory.appending(path: "PageRecedeCapture/deck")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await TabDeckAudit.exercise(browser, folder: folder)
    }

    @MainActor func testDetachedViewsUseTheFallbackWithoutAScreenLookup() {
        XCTAssertEqual(PageRecede.screenCornerRadius(of: UIView()), PageRecede.cornerRadius)
    }

    /// Searching a site from its own search: Return puts the keyboard away, the panel's height
    /// follows it, and the page behind was set back 26 times over, its scale crossing zero, so it
    /// spun away to the top right as the result grew in.
    @MainActor func testASiteSearchsResultGrowsInWithoutFlippingThePageBehind() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let browser = InteractionAudit.makeBrowser()
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        browser.openPanel()
        try await Task.sleep(for: .milliseconds(500))
        let search = browser.bottomBar.search
        search.field.text = "youtube.com"
        search.field.sendActions(for: .editingChanged)
        for _ in 0..<100 where search.offeredSite == nil { try await Task.sleep(for: .milliseconds(10)) }
        search.enterSiteSearch()
        try await Task.sleep(for: .milliseconds(500))
        let before = browser.content.transform.a
        browser.openFromPanel(URL(string: "about:blank")!)
        XCTAssertGreaterThanOrEqual(browser.content.transform.a, 1-(1-PageRecede.scale)*PageRecede.maximumAmount,
                                    "The page behind recedes further, never past half its size (was \(before))")
        XCTAssertLessThanOrEqual(browser.content.transform.a, before, "The page behind carries on receding")
        for _ in 0..<40 {
            let shown = browser.content.layer.presentation()?.transform ?? browser.content.layer.transform
            XCTAssertGreaterThan(shown.m11, 0, "The page behind never flips")
            XCTAssertEqual(shown.m12, 0, accuracy: 0.001, "The page behind never turns")
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    @MainActor func testRecedingFarPastASheetStopsAtHalfSize() {
        let page = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        PageRecede.apply(26, to: page)
        XCTAssertEqual(page.transform.a, 0.5, accuracy: 0.001)
        XCTAssertEqual(page.transform.d, 0.5, accuracy: 0.001)
    }
}
