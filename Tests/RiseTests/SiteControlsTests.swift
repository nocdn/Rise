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
        store.defaultNotifications = .block
        XCTAssertEqual(store.permission(.notifications, origin: origin), .block)
        store.set(.allow, for: .notifications, origin: origin)
        XCTAssertEqual(SitePermissions(preferences: defaults).permission(.notifications, origin: origin), .allow)
        XCTAssertEqual(store.permission(.notifications, origin: "https://other.example:443"), .block)
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
        XCTAssertTrue(browser.selectedBar.isHovered, "The address stays as if hovered while its controls show")
        XCTAssertTrue(browser.selectedBar.settingsButton.allowsInteraction && browser.selectedBar.settingsButton.hover == false && browser.selectedBar.settingsButton.holdsHover)
        let content = try XCTUnwrap(browser.siteControlsPopover.contentViewController as? SiteControlsController)
        XCTAssertEqual(content.view.frame.width, 240)
        XCTAssertEqual(content.quickActions.count, 4)
        XCTAssertEqual(content.quickActions.map(\.toolTip), ["Share Page", "Capture Whole Page", "Copy Text from Page Image", "More Site Controls"])
        XCTAssertFalse(content.view.subviews.contains { $0 is NSVisualEffectView })
        XCTAssertEqual(content.extensionsButton.layer?.cornerRadius, content.quickActions[0].layer?.cornerRadius)
        XCTAssertFalse(content.view.subviews.contains { ($0 as? NSButton)?.title == "Secure" || ($0 as? NSButton)?.title == "Not Secure" })
        XCTAssertTrue(content.rows.values.allSatisfy { $0.subviews.filter { $0 is NSImageView }.count == 1 }, "Each row has only its status icon")
        XCTAssertEqual(content.rows.values.sorted { $0.frame.minY < $1.frame.minY }.map(\.name.stringValue),
                       ["Developer Mode", "Dismiss Cookies", "Picture in Picture", "Preload Links"], "No Block Ads: uBlock Origin takes that")
        XCTAssertTrue(content.rows.values.allSatisfy { $0.toggle.superview === $0 }, "Each is a native switch")
        XCTAssertEqual(browser.makeMoreSiteMenu().items.filter { !$0.isSeparatorItem }.map(\.title), ["Copy URL", "Site Information", "Save Page Screenshot…", "Split View", "Search Engine", "Theme", "AI Provider", "Gmail Preview Category", "Hide Notification Counts", "Show Repository Under Merge Request Tabs", "Live Page While Expanding Peek", "Animate Developer Tools", "Simulated Full Screen", "Clear Browsing History…", "Camera Permissions…", "Microphone Permissions…", "Location Permissions…"])
        XCTAssertNil(content.rows["Notifications"])
        XCTAssertEqual(content.rows["Dismiss Cookies"]?.state, .on)
        XCTAssertNotNil(content.rows["Dismiss Cookies"]?.icon.image)
        content.rows["Dismiss Cookies"]?.performClick(nil)
        XCTAssertFalse(browser.cookieConsent.isEnabled(for: tab.url))
        browser.pageStartedLoading(tab.page.view)
        XCTAssertTrue(browser.siteControlsPopover.isShown, "The reload the switch asked for leaves the controls open")
        XCTAssertTrue(browser.cookieConsent.isEnabled(for: URL(string: "https://other.example")))
        let privacy = browser.riseSettingRows("privacy")
        XCTAssertEqual(privacy.first?["key"] as? String, "notificationPermission")
        browser.setRiseSetting("notificationPermission", "block")
        XCTAssertEqual(browser.sitePermissions.permission(.notifications, origin: SitePermissions.origin(tab.url)), .block)
        browser.setRiseSetting("permission|notifications|https://example.com:443", "ask")
        XCTAssertEqual(browser.sitePermissions.permission(.notifications, origin: SitePermissions.origin(tab.url)), .ask)
        XCTAssertEqual(content.rows["Preload Links"]?.state, .off)
        content.rows["Preload Links"]?.performClick(nil)
        XCTAssertTrue(browser.linkPreloader.enabled)
        XCTAssertEqual(content.rows["Preload Links"]?.toggle.state, .on)
        browser.refreshSiteControls()
        XCTAssertTrue(browser.siteControlsPopover.contentViewController === content, "Only states changed: the switches stay, mid-slide")
        browser.siteControlsPopover.animates = false
        // A popover still opening ignores being closed, and one open closes on the next turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        content.rows["Developer Mode"]?.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(tab.developer)
        XCTAssertFalse(browser.siteControlsPopover.isShown, "Only developer mode closes the controls")
        XCTAssertFalse(browser.navBar.settingsButton.holdsHover, "Closed, the bar follows the pointer again")
    }
    @MainActor func testPermissionPanelDismissalReversalAndAllowCompleteOnlyOnce() throws {
        _ = NSApplication.shared
        let suite = "Rise.PromptTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer { browser.permissionCoordinator.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite) }
        browser.window?.setContentSize(NSSize(width: 900, height: 650)); browser.window?.center()
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com")
        browser.showWindow(nil); browser.update()
        let origin = SitePermissions.origin(tab.url)!
        let coordinator = browser.permissionCoordinator, panel = coordinator.panel
        var replies: [Bool] = []
        func wait(_ done: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera]) { replies.append($0) }
        // Its icon grows in, then Find's panel comes down from under the bar with the question.
        wait { coordinator.isShowingPrompt }
        XCTAssertTrue(coordinator.isShowingPrompt)
        let question = try XCTUnwrap(panel.question)
        XCTAssertEqual(question.heading, "Camera permissions"); XCTAssertEqual(question.message, "Let example.com use your camera?")
        let bar = browser.selectedBar
        XCTAssertFalse(bar.permissionButton.isHidden); XCTAssertTrue(bar.permissionButton.frame.maxX <= bar.settingsButton.frame.minX)
        XCTAssertTrue(panel.superview === browser.root); XCTAssertEqual(panel.frame.maxX, browser.pageShadow.frame.maxX, accuracy: 1)
        wait { !panel.isMoving }
        XCTAssertEqual(panel.panel.frame.minY, PlainNavBar.Metrics.height+FindBar.top, accuracy: 1, "It rests where Find's does")
        XCTAssertEqual(panel.panel.frame.height, FindBar.rowHeight)
        // As Find's chevrons and close: 26 by 28, a point apart, 8 from the edge.
        XCTAssertEqual(panel.allowButton.frame.size, NSSize(width: 26, height: 28)); XCTAssertEqual(panel.denyButton.frame.minX-panel.allowButton.frame.maxX, 1)
        XCTAssertEqual(panel.panel.frame.width-panel.denyButton.frame.maxX, 8)
        // Its icon puts it away unanswered, its icon staying, and brings it back.
        coordinator.togglePrompt()
        XCTAssertFalse(coordinator.isShowingPrompt); XCTAssertEqual(replies, []); XCTAssertNotNil(bar.requestedPermission)
        wait { !panel.isLeaving }
        coordinator.togglePrompt()
        XCTAssertTrue(coordinator.isShowingPrompt); XCTAssertEqual(replies, [])
        // Put away, the page asking the same again brings it back down, and both hear the answer.
        coordinator.togglePrompt(); wait { !panel.isLeaving }
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera]) { replies.append($0) }
        XCTAssertTrue(coordinator.isShowingPrompt); XCTAssertEqual(replies, [])
        panel.denyButton.performClick(nil)
        XCTAssertEqual(replies, [false, false], "The page hears at once")
        replies = [false]
        coordinator.cancel()
        wait { bar.requestedPermission == nil }
        XCTAssertNil(bar.requestedPermission, "Answered, its icon goes once the panel has")
        XCTAssertEqual(replies, [false]); XCTAssertEqual(browser.sitePermissions.permission(.camera, origin: origin), .ask)
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera]) { replies.append($0) }
        // Asked again while the last goes, it comes down once that one has gone.
        wait { coordinator.isShowingPrompt }
        panel.allowButton.performClick(nil)
        XCTAssertEqual(replies, [false, true]); XCTAssertEqual(browser.sitePermissions.permission(.camera, origin: origin), .allow)
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera, .microphone]) { replies.append($0) }
        coordinator.cancel(for: tab.page.view); coordinator.resolve(true)
        XCTAssertEqual(replies, [false, true, false]); XCTAssertEqual(browser.sitePermissions.permission(.microphone, origin: origin), .ask)
        browser.sitePermissions.set(.block, for: .camera, origin: origin)
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera]) { replies.append($0) }
        XCTAssertEqual(replies.last, false); XCTAssertFalse(coordinator.isShowingPrompt)
        let hidden = WKWebView()
        coordinator.request(in: hidden, origin: origin, capabilities: [.microphone]) { replies.append($0) }
        XCTAssertEqual(replies.last, false)
    }
    @MainActor func testPermissionQuestionsAreShortQuestions() {
        let cases: [([SiteCapability], String)] = [([.notifications], "Let a.com send notifications?"), ([.location], "Let a.com use your location?"),
                                                   ([.camera, .microphone], "Let a.com use your camera and mic?"), ([.camera], "Let a.com use your camera?"),
                                                   ([.microphone], "Let a.com use your microphone?")]
        let suite = "Rise.ResetTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let permissions = SitePermissions(preferences: defaults), origin = "https://a.com:443"
        permissions.set(.allow, for: .camera, origin: origin); permissions.set(.block, for: .location, origin: origin)
        permissions.setAutomaticPictureInPicture(false, origin: origin); permissions.set(.allow, for: .camera, origin: "https://b.com:443")
        permissions.reset(origin: origin)
        XCTAssertEqual(permissions.permission(.camera, origin: origin), .ask); XCTAssertEqual(permissions.permission(.location, origin: origin), .ask)
        XCTAssertFalse(permissions.automaticPictureInPicture(origin: origin), "Its other settings stay")
        XCTAssertEqual(permissions.permission(.camera, origin: "https://b.com:443"), .allow, "Other sites keep theirs")
        XCTAssertEqual(SitePermissions(preferences: defaults).permission(.camera, origin: origin), .ask, "And it's saved")
        for (capabilities, message) in cases { XCTAssertEqual(PermissionQuestion(host: "a.com", capabilities: capabilities).message, message) }
        let text = PermissionQuestion(host: "a.com", capabilities: [.camera]).text(theme: .neutral, font: .systemFont(ofSize: 13))
        XCTAssertEqual(text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, SiteCapability.camera.accent(.neutral), "The site is in the camera's colour")
    }
}
