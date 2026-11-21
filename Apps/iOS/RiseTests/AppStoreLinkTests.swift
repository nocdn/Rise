import UIKit
import WebKit
import XCTest
@testable import RiseiOS

final class AppStoreLinkTests: XCTestCase {
    private static let listing = URL(string: "https://apps.apple.com/uk/app/gov-uk-one-login/id6737119425?pt=123&ct=qr")!
    private static let external = URL(string: "itms-apps://apps.apple.com/uk/app/gov-uk-one-login/id6737119425?pt=123&ct=qr")!

    func testOnlyAppleAppListingsBecomeStoreLinksAndKeepTheirRegionAndParameters() throws {
        let link = try XCTUnwrap(AppStoreLink(Self.listing))
        XCTAssertEqual(link.appID, "6737119425")
        XCTAssertEqual(link.webURL, Self.listing)
        XCTAssertEqual(link.externalURL, Self.external)
        for value in ["https://itunes.apple.com/gb/app/example/id123", "https://apps.apple.com/app/id123",
                      "ITMS-APPSS://APPS.APPLE.COM/uk/app/gov-uk-one-login/id6737119425?pt=123&ct=qr"] {
            XCTAssertNotNil(AppStoreLink(URL(string: value)!), value)
        }
        for value in ["https://apps.apple.com/", "https://apps.apple.com/uk/developer/example/id123",
                      "https://itunes.apple.com/gb/album/example/id123", "https://apps.apple.com/uk/app/idno",
                      "https://apps.apple.com.evil.example/uk/app/id123", "https://apps.apple.com@evil.example/app/id123",
                      "https://user@apps.apple.com/app/id123", "https://apps.apple.com:8080/app/id123",
                      "some-app://apps.apple.com/app/id123", "https://example.com/app/id123"] {
            XCTAssertNil(AppStoreLink(URL(string: value)!), value)
        }
    }

    @MainActor private func host(_ browser: BrowserViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true; previous?.makeKey() }
        return window
    }

    @MainActor func testEmptyHTTPStoreRedirectOffersClickableToastWithoutAutomaticallyLaunchingAnApp() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let browser = BrowserViewController(startURL: fixture.url.appendingPathComponent("app-store/redirect"))
        var opened: [URL] = []
        browser.openExternalURL = { url, completion in opened.append(url); completion(true) }
        let window = try host(browser)
        for _ in 0..<500 {
            if browser.toast is AppStoreToast, !browser.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let toast = try XCTUnwrap(browser.toast as? AppStoreToast)
        XCTAssertEqual(toast.label.text, "Open App Store")
        XCTAssertEqual(toast.link.webURL, Self.listing)
        XCTAssertTrue(opened.isEmpty, "A server redirect isn't a user tap")
        XCTAssertTrue(browser.navigationStatus.isHidden, "An intentional store handoff isn't a page-load error")
        XCTAssertFalse(browser.navigationStatus.spinner.isAnimating)
        window.layoutIfNeeded(); browser.view.layoutIfNeeded(); toast.layoutIfNeeded()
        XCTAssertEqual(browser.webView.frame.minY, browser.view.safeAreaInsets.top, accuracy: 0.5, "The toast must not reserve space above the page")
        XCTAssertLessThan(toast.frame.maxY, browser.bottomBar.frame.minY)
        XCTAssertEqual(toast.trailingIcon.tintColor, toast.symbol.tintColor)
        XCTAssertNotNil(toast.trailingIcon.image)
        XCTAssertEqual(toast.trailingIcon.image?.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(browser.tabs.count, 1)
        toast.activate()
        XCTAssertEqual(opened, [Self.external])
        XCTAssertEqual(browser.tabs.count, 1, "Opening the store must not create another blank tab")

        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: browser.view.bounds).image { context in
            browser.view.layer.render(in: context.cgContext)
        })
        attachment.name = "Open App Store toast after empty redirect"; attachment.lifetime = .keepAlways
        add(attachment)
        toast.beginDrag(); toast.trackDrag(CGPoint(x: 0, y: 90)); toast.endDrag(velocity: CGPoint(x: 0, y: 1800))
        browser.updateAddress()
        XCTAssertTrue(toast.dismissed)
        XCTAssertTrue(browser.appStoreLinks.isDismissed(for: browser.webView))
        XCTAssertEqual(opened, [Self.external], "Swiping dismisses without opening the store")
    }

    @MainActor func testDismissalAndNavigationStayWithTheirOwnTabIncludingPrivatePages() {
        let links = AppStoreLinks()
        let first = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        let second = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        XCTAssertNotNil(links.link(for: first, address: Self.listing), "A restored listing offers Open before it loads")
        links.dismiss(for: first)
        links.noteNavigation(to: Self.external, in: first)
        XCTAssertTrue(links.isDismissed(for: first), "Reloads and redirects of the same app respect dismissal")
        XCTAssertNotNil(links.link(for: second, address: Self.listing))
        XCTAssertFalse(links.isDismissed(for: second), "Dismissal in another tab doesn't hide this one")
        links.noteNavigation(to: URL(string: "https://example.com/article")!, in: first)
        XCTAssertNil(links.link(for: first, address: Self.listing), "The preceding address must not resurrect a toast during navigation")
        links.noteNavigation(to: Self.listing, in: first)
        XCTAssertNotNil(links.link(for: first, address: nil))
        XCTAssertFalse(links.isDismissed(for: first))
    }

    @MainActor func testFailedOpenShowsAnErrorAndThenOffersRetry() async throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        browser.appStoreLinks.noteNavigation(to: Self.listing, in: browser.webView)
        browser.updatePageToast()
        var attempts = 0
        browser.openExternalURL = { url, completion in
            XCTAssertEqual(url, Self.external); attempts += 1; completion(false)
        }
        try XCTUnwrap(browser.toast as? AppStoreToast).activate()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(browser.toast?.accessibilityLabel, "Couldn't open the App Store")
        browser.toast?.dismiss(animated: false)
        for _ in 0..<100 where !(browser.toast is AppStoreToast) { try await Task.sleep(for: .milliseconds(10)) }
        try XCTUnwrap(browser.toast as? AppStoreToast).activate()
        XCTAssertEqual(attempts, 2)
        withExtendedLifetime(window) {}
    }

    @MainActor func testDownwardSwipeDismissesWithoutOpeningAndDoesNotReappear() throws {
        let browser = BrowserViewController(startURL: nil)
        let window = try host(browser)
        browser.appStoreLinks.noteNavigation(to: Self.listing, in: browser.webView)
        browser.updatePageToast()
        var opened = false
        browser.openExternalURL = { _, completion in opened = true; completion(true) }
        let toast = try XCTUnwrap(browser.toast as? AppStoreToast)
        toast.beginDrag(); toast.trackDrag(CGPoint(x: 0, y: 90)); toast.endDrag(velocity: CGPoint(x: 0, y: 1800))
        XCTAssertTrue(toast.dismissed)
        XCTAssertTrue(browser.appStoreLinks.isDismissed(for: browser.webView))
        XCTAssertFalse(opened)
        toast.dismiss(animated: false)
        browser.updatePageToast()
        XCTAssertFalse((browser.toast as? AppStoreToast).map { !$0.dismissed } ?? false)
        withExtendedLifetime(window) {}
    }

    @MainActor func testWholeToastIncludingArtworkCanOpenAndAccessibilityCanDismiss() throws {
        let page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        let toast = AppStoreToast(link: try XCTUnwrap(AppStoreLink(Self.listing)), page: page, artwork: { _ in nil })
        toast.place(above: 700, in: CGRect(x: 0, y: 0, width: 320, height: 800), safeTop: 59)
        toast.layoutIfNeeded()
        XCTAssertTrue(toast.symbol.isHidden, "The former X is gone")
        XCTAssertFalse(toast.appIcon.isUserInteractionEnabled, "The artwork doesn't intercept the toast's tap")
        for x in [20, toast.bounds.midX, toast.bounds.width-20] {
            XCTAssertTrue(toast.hitTest(CGPoint(x: x, y: 27), with: nil) === toast.pressButton,
                          "Artwork, text and the trailing icon all activate the same button")
        }
        XCTAssertEqual(toast.appIcon.bounds.size, CGSize(width: 24, height: 24))
        XCTAssertNotNil(toast.appIcon.image)
        var opened = 0, dismissed = 0
        toast.onActivate = { opened += 1 }; toast.onUserDismiss = { dismissed += 1 }
        XCTAssertTrue(toast.accessibilityActivate())
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(try XCTUnwrap(toast.accessibilityCustomActions?.first).name, "Dismiss")
        toast.beginDrag(); toast.trackDrag(CGPoint(x: 0, y: 90)); toast.endDrag(velocity: CGPoint(x: 0, y: 1800))
        XCTAssertEqual(dismissed, 1)
        toast.activate()
        XCTAssertEqual(opened, 1, "A dismissed toast cannot open the store")
    }

    @MainActor func testOnlyAppStoreToastShrinksAndClicksAndCancelledPressDoesNotOpen() throws {
        let page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        let toast = AppStoreToast(link: try XCTUnwrap(AppStoreLink(Self.listing)), page: page, artwork: { _ in nil })
        toast.place(above: 700, in: CGRect(x: 0, y: 0, width: 320, height: 800), safeTop: 59)
        toast.layoutIfNeeded()
        var opened = 0
        toast.onActivate = { opened += 1 }
        toast.pressButton.sendActions(for: .touchDown)
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertEqual(toast.pressButton.transform.a, SearchPanel.pressedScale, accuracy: 0.001)
        }
        XCTAssertTrue(CATransform3DIsIdentity(toast.layer.transform), "Pressing must not change the swipe layer")
        toast.pressButton.sendActions(for: .touchCancel)
        XCTAssertTrue(toast.pressButton.transform.isIdentity)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(toast.activationFeedbackCount, 0)
        toast.pressButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(toast.activationFeedbackCount, 1)
        let ordinary = Toast(message: "Unchanged", glyph: nil, name: "ordinary")
        XCTAssertFalse(ordinary.subviews.contains { $0 is UIButton && $0 !== ordinary.symbol },
                       "Other toasts keep their existing interaction")
    }
}
