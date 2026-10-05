import XCTest
import AppKit
import WebKit
@testable import Rise

final class SiteControlsTests: XCTestCase {
    @MainActor func testOriginPermissionsPersistWithoutLeakingAcrossPortsSchemesOrSites() {
        let suite = "Rise.PermissionTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SitePermissions(preferences: defaults)
        let origin = SitePermissions.origin(URL(string: "https://EXAMPLE.com/some/path"))!
        XCTAssertEqual(origin, "https://example.com:443")
        XCTAssertEqual(origin, SitePermissions.origin(URL(string: "https://example.com:443/other")))
        XCTAssertEqual(store.permission(.camera, origin: origin), .ask)
        store.set(.allow, for: .camera, origin: origin)
        XCTAssertEqual(SitePermissions(preferences: defaults).permission(.camera, origin: origin), .allow)
        for url in ["http://example.com", "https://example.com:8443", "https://other.example.com"] {
            XCTAssertEqual(store.permission(.camera, origin: SitePermissions.origin(URL(string: url))), .ask)
        }
        XCTAssertNil(SitePermissions.origin(URL(string: "file:///tmp/example.html")))
        XCTAssertEqual(store.permission(.microphone, origin: origin), .ask)
        store.setAutomaticPictureInPicture(false, origin: origin)
        XCTAssertFalse(SitePermissions(preferences: defaults).automaticPictureInPicture(origin: origin))
    }
    @MainActor func testNativeSettingsUseOneMaterialAndKeepActionsWithoutRedundantControls() throws {
        _ = NSApplication.shared
        let suite = "Rise.SettingsTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer { browser.siteControlsPopover.animates = false; browser.siteControlsPopover.close(); browser.saveWork?.cancel(); browser.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com")
        browser.showWindow(nil); browser.update()
        browser.siteMenu()
        XCTAssertTrue(browser.siteControlsPopover.isShown)
        XCTAssertEqual(browser.siteControlsPopover.behavior, .transient)
        let content = try XCTUnwrap(browser.siteControlsPopover.contentViewController as? SiteControlsController)
        XCTAssertEqual(content.view.frame.width, 240)
        XCTAssertEqual(content.quickActions.count, 4)
        XCTAssertEqual(content.quickActions.map(\.toolTip), ["Share Page", "Save Page Screenshot", "Copy Text from Page Image", "More Site Controls"])
        XCTAssertFalse(content.view.subviews.contains { $0 is NSVisualEffectView })
        XCTAssertEqual(content.extensionsButton.layer?.cornerRadius, content.quickActions[0].layer?.cornerRadius)
        XCTAssertFalse(content.view.subviews.contains { ($0 as? NSButton)?.title == "Secure" || ($0 as? NSButton)?.title == "Not Secure" })
        XCTAssertTrue(content.rows.values.allSatisfy { $0.subviews.filter { $0 is NSImageView }.count == 1 }, "Each row has only its status icon")
        XCTAssertEqual(content.view.frame.height, 374)
        XCTAssertEqual(browser.makeMoreSiteMenu().items.filter { !$0.isSeparatorItem }.map(\.title), ["Copy URL", "Site Information", "Save Page Screenshot…", "Split View", "Search Engine", "Clear Browsing History…", "Camera Permissions…", "Microphone Permissions…", "Location Permissions…"])
        XCTAssertEqual(content.rows["Block Ads & Trackers"]?.state, .on)
        XCTAssertEqual(content.rows["Preload Links"]?.state, .off)
        content.rows["Preload Links"]?.performClick(nil)
        XCTAssertTrue(browser.linkPreloader.enabled)
        let updated = try XCTUnwrap(browser.siteControlsPopover.contentViewController as? SiteControlsController)
        XCTAssertEqual(updated.rows["Preload Links"]?.state, .on)
        updated.rows["Developer Mode"]?.performClick(nil)
        XCTAssertTrue(tab.developer)
        XCTAssertEqual((browser.siteControlsPopover.contentViewController as? SiteControlsController)?.rows["Developer Mode"]?.detail.stringValue, "On")
        browser.siteControlsPopover.animates = false
        browser.siteMenu(); XCTAssertFalse(browser.siteControlsPopover.isShown)
    }
    @MainActor func testPermissionPopoverDismissalReversalAndAllowCompleteOnlyOnce() throws {
        _ = NSApplication.shared
        let suite = "Rise.PromptTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer { browser.permissionCoordinator.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com")
        browser.showWindow(nil); browser.update()
        let origin = SitePermissions.origin(tab.url)!
        var replies: [Bool] = []
        browser.permissionCoordinator.request(in: tab.webView, origin: origin, capabilities: [.camera]) { replies.append($0) }
        XCTAssertTrue(browser.permissionCoordinator.popover.isShown)
        let prompt = try XCTUnwrap(browser.permissionCoordinator.popover.contentViewController as? PermissionPromptController)
        XCTAssertEqual(prompt.message, "Allow example.com to use your camera?")
        prompt.notNowButton.performClick(nil)
        browser.permissionCoordinator.cancel()
        XCTAssertEqual(replies, [false]); XCTAssertEqual(browser.sitePermissions.permission(.camera, origin: origin), .ask)
        browser.permissionCoordinator.request(in: tab.webView, origin: origin, capabilities: [.camera]) { replies.append($0) }
        (browser.permissionCoordinator.popover.contentViewController as? PermissionPromptController)?.allowButton.performClick(nil)
        XCTAssertEqual(replies, [false, true]); XCTAssertEqual(browser.sitePermissions.permission(.camera, origin: origin), .allow)
        browser.permissionCoordinator.request(in: tab.webView, origin: origin, capabilities: [.camera, .microphone]) { replies.append($0) }
        browser.permissionCoordinator.cancel(for: tab.webView); browser.permissionCoordinator.resolve(true)
        XCTAssertEqual(replies, [false, true, false]); XCTAssertEqual(browser.sitePermissions.permission(.microphone, origin: origin), .ask)
        browser.sitePermissions.set(.block, for: .camera, origin: origin)
        browser.permissionCoordinator.request(in: tab.webView, origin: origin, capabilities: [.camera]) { replies.append($0) }
        XCTAssertEqual(replies.last, false); XCTAssertFalse(browser.permissionCoordinator.popover.isShown)
        let hidden = WKWebView()
        browser.permissionCoordinator.request(in: hidden, origin: origin, capabilities: [.microphone]) { replies.append($0) }
        XCTAssertEqual(replies.last, false)
    }
}
