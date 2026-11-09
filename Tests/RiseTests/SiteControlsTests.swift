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
        XCTAssertEqual(content.quickActions.map(\.toolTip), ["Share Page", "Capture Whole Page", "Block Ads", "More Site Controls"])
        let adBlock = try XCTUnwrap(content.quickActions[2] as? AdBlockButton)
        XCTAssertFalse(adBlock.showsSlash)
        XCTAssertEqual(adBlock.title, "", "Only the symbol shows on it")
        adBlock.performClick(nil)
        XCTAssertTrue(browser.adBlocker.enabled, "It's only this site")
        XCTAssertFalse(browser.adBlocker.isBlocking(on: tab.url))
        XCTAssertTrue(browser.adBlocker.isBlocking(on: URL(string: "https://example.org")))
        XCTAssertTrue(adBlock.showsSlash)
        XCTAssertEqual(adBlock.accessibilityValue() as? String, "Off")
        XCTAssertTrue(browser.siteControlsPopover.isShown, "It stays open to show the change")
        adBlock.performClick(nil)
        XCTAssertTrue(browser.adBlocker.isBlocking(on: tab.url))
        XCTAssertFalse(adBlock.showsSlash)
        XCTAssertFalse(content.view.subviews.contains { $0 is NSVisualEffectView })
        XCTAssertEqual(content.extensionsButton.layer?.cornerRadius, content.quickActions[0].layer?.cornerRadius)
        XCTAssertFalse(content.view.subviews.contains { ($0 as? NSButton)?.title == "Secure" || ($0 as? NSButton)?.title == "Not Secure" })
        XCTAssertTrue(content.rows.values.allSatisfy { $0.subviews.filter { $0 is NSImageView }.count == 1 }, "Each row has only its status icon")
        XCTAssertTrue(content.rows.isEmpty, "The Settings heading and all four toggles have moved out of the popover")
        XCTAssertFalse(content.view.subviews.contains { ($0 as? NSTextField)?.stringValue == "Settings" })
        XCTAssertLessThan(content.view.frame.height, 180, "The popover ends below its extension tiles")
        XCTAssertEqual(browser.makeMoreSiteMenu().items.filter { !$0.isSeparatorItem }.map(\.title), ["Copy URL", "Site Information", "Save Page Screenshot…", "Split View", "Search Engine", "Theme", "AI Provider", "Gmail Preview Category", "Hide Notification Counts", "Show Repository Under Pull and Merge Request Tabs", "Live Page While Expanding Peek", "Animate Developer Tools", "Simulated Full Screen", "Clear Browsing History…", "Camera Permissions…", "Microphone Permissions…", "Location Permissions…"])
        XCTAssertFalse(browser.cookieConsent.isEnabled(for: tab.url))
        let privacy = browser.riseSettingRows("privacy")
        XCTAssertEqual(privacy.first?["key"] as? String, "notificationPermission")
        browser.setRiseSetting("notificationPermission", "block")
        XCTAssertEqual(browser.sitePermissions.permission(.notifications, origin: SitePermissions.origin(tab.url)), .block)
        browser.setRiseSetting("permission|notifications|https://example.com:443", "ask")
        XCTAssertEqual(browser.sitePermissions.permission(.notifications, origin: SitePermissions.origin(tab.url)), .ask)
        browser.refreshSiteControls()
        XCTAssertTrue(browser.siteControlsPopover.contentViewController === content)
        browser.siteControlsPopover.animates = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        browser.siteControlsPopover.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(browser.siteControlsPopover.isShown)
        XCTAssertFalse(browser.navBar.settingsButton.holdsHover, "Closed, the bar follows the pointer again")
    }
    @MainActor func testAdBlockingIsLeftOffBySite() {
        let suite = "Rise.AdBlockSiteTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let blocker = AdBlocker(preferences: defaults)
        XCTAssertEqual(AdBlocker.site(of: URL(string: "https://www.Example.com:8443/a?b#c")), "example.com")
        XCTAssertNil(AdBlocker.site(of: URL(string: "file:///a.html")))
        XCTAssertNil(AdBlocker.site(of: URL(string: "rise://settings")))
        blocker.setAllowed(true, site: "example.com")
        for page in ["https://example.com/a", "https://www.example.com/b", "http://mail.example.com/c"] {
            XCTAssertFalse(blocker.isBlocking(on: URL(string: page)), page)
        }
        XCTAssertEqual(blocker.allowedSite(for: URL(string: "https://mail.example.com")), "example.com")
        for page in ["https://example.org", "https://notexample.com", "https://example.com.evil.net"] {
            XCTAssertTrue(blocker.isBlocking(on: URL(string: page)), page)
        }
        XCTAssertEqual(AdBlocker(preferences: defaults).allowedSites, ["example.com"], "It's remembered")
    }
    @MainActor func testReloadingAPageAgainOffersToLeaveItsSiteUnblocked() throws {
        _ = NSApplication.shared
        let suite = "Rise.AdBlockPromptTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite) }
        browser.showWindow(nil)
        let tab = browser.addTab(url: URL(string: "https://example.com/a#one")!)
        let prompt = browser.adBlockPrompt, start = Date()
        prompt.noteReload(at: start); prompt.noteReload(at: start+5)
        XCTAssertFalse(prompt.panel.isPresented, "Twice is nothing to go on")
        prompt.noteReload(at: start+30)
        XCTAssertFalse(prompt.panel.isPresented, "Nor are reloads far apart")
        prompt.noteReload(at: start+35); prompt.noteReload(at: start+40)
        XCTAssertTrue(prompt.panel.isPresented)
        XCTAssertFalse(prompt.panel.allowButton.isHidden || prompt.panel.denyButton.isHidden)
        XCTAssertTrue(prompt.panel.revertButton.isHidden)
        XCTAssertEqual(prompt.panel.notice?.message, "Disable ad-blocking on this site?")
        let text = AdBlockPrompt.text(theme: .neutral, font: .systemFont(ofSize: 13))
        let word = (text.string as NSString).range(of: "ad-blocking")
        XCTAssertEqual(text.attribute(.foregroundColor, at: word.location, effectiveRange: nil) as? NSColor, SiteCapability.notifications.accent(.neutral))
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, RiseTheme.neutral.text)
        // Declined, it doesn't ask about that site again.
        prompt.panel.denyButton.performClick(nil)
        XCTAssertFalse(prompt.panel.isPresented)
        for offset in 0..<3 { prompt.noteReload(at: start+50+Double(offset)) }
        XCTAssertFalse(prompt.panel.isPresented)
        XCTAssertTrue(browser.adBlocker.isBlocking(on: tab.page.url))
        // Another site asks, and yes leaves that site alone and no other.
        tab.page.load(URL(string: "https://example.org/b")!)
        for offset in 0..<3 { prompt.noteReload(at: start+60+Double(offset)) }
        XCTAssertTrue(prompt.panel.isPresented)
        prompt.panel.allowButton.performClick(nil)
        XCTAssertFalse(prompt.panel.isPresented)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(browser.selectedBar.notice?.text, "Ad-blocking disabled on this site")
        XCTAssertTrue(browser.selectedBar.notice?.subviews.contains { ($0 as? NSImageView)?.image === AdBlockPrompt.noticeIcon } == true, "With its icon")
        XCTAssertEqual(browser.selectedBar.notice?.nudge, AdBlockPrompt.noticeNudge)
        XCTAssertEqual(browser.selectedBar.notice?.dottedWords, "disabled")
        XCTAssertNil(browser.selectedBar.notice?.linkLabel, "It's not a link: nothing to click")
        XCTAssertFalse(browser.adBlocker.isBlocking(on: URL(string: "https://example.org/c")))
        XCTAssertTrue(browser.adBlocker.isBlocking(on: URL(string: "https://example.com/a")))
        XCTAssertTrue(browser.adBlocker.enabled)
        // The shield then blocks it again.
        browser.toggleAdBlockingHere()
        XCTAssertTrue(browser.adBlocker.isBlocking(on: tab.page.url))
        // Off everywhere, it turns blocking back on.
        browser.toggleAdBlocking()
        XCTAssertFalse(browser.adBlocker.enabled)
        browser.toggleAdBlockingHere()
        XCTAssertTrue(browser.adBlocker.enabled)
        // Pages a developer reloads all day don't ask.
        tab.developer = true
        for offset in 0..<3 { prompt.noteReload(at: start+70+Double(offset)) }
        XCTAssertFalse(prompt.panel.isPresented)
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
