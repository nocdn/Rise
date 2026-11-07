// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumAdBlockButtonChecks.swift
import AppKit
import RiseChromium
import RiseCore
@testable import Rise

@main @MainActor struct ChromiumAdBlockButtonMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("FAIL ad block button checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = AdBlockButtonRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// The site controls' shield, and reloading a page again, leave its site alone and every other site
/// blocked, in an open popover, on pages uBlock Origin blocks.
@MainActor final class AdBlockButtonRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func waitUntil(_ seconds: Double, _ ready: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await ready()), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return await ready()
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func run() async {
        let defaults = UserDefaults(suiteName: "Rise.AdBlockButton.\(UUID())")!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        for name in ["ads", "more"] {
            try? "<title>Page</title><div class=ADBAR id=slot>Ad</div><p>Text</p>".write(to: folder.appendingPathComponent(name+".html"), atomically: true, encoding: .utf8)
        }
        func kept() -> [String] { defaults.stringArray(forKey: AdBlocker.allowedSitesKey) ?? [] }
        let tab = browser.addTab(url: URL(string: "http://rise-check.test:\(port)/ads.html")!)
        func hidden(_ page: WebPage? = nil) async -> Bool? {
            (try? await (page ?? tab.page).evaluate("return getComputedStyle(document.getElementById('slot')).display === 'none'", arguments: [:], in: nil, world: .page)) as? Bool
        }
        func loaded() async -> Bool { !tab.page.isLoading && tab.page.url != nil }
        /// Whether its ad shows, for good: uBlock Origin hides it a moment after a page loads.
        func showsAd(_ page: WebPage? = nil) async -> Bool {
            try? await Task.sleep(for: .milliseconds(1200))
            return await hidden(page) == false
        }
        check(await waitUntil(30) { await hidden() == true }, "uBlock Origin hides the page's ad")

        // Reloading again and again offers to leave this site alone.
        let prompt = browser.adBlockPrompt
        for time in 1...3 {
            _ = await waitUntil(10) { await loaded() }
            check(!prompt.panel.isPresented, "Not yet, before reload \(time)")
            browser.reload()
            try? await Task.sleep(for: .milliseconds(300))
        }
        check(prompt.panel.isPresented, "The third reload brings the panel down")
        check(await waitUntil(10) { await loaded() } && prompt.panel.isPresented, "It stays through that reload")
        check(await waitUntil(5) { await hidden() == true }, "Asking changes nothing yet")
        prompt.panel.allowButton.performClick(nil)
        check(!prompt.panel.isPresented, "Answered, it goes")
        func says(_ words: String) async -> Bool { await waitUntil(3) { browser.selectedBar.notice?.text == words } }
        check(await says("Ad-blocking disabled on this site"), "The bar says so")
        check(kept() == ["rise-check.test"], "The site is kept: \(kept())")
        check(browser.adBlocker.enabled && RCAdBlock.enabled, "Blocking stays on everywhere else")
        try? await Task.sleep(for: .milliseconds(800))
        _ = await waitUntil(15) { await loaded() }
        check(await showsAd(), "Yes reloads the page with its ad showing")

        let sameSite = browser.addTab(url: URL(string: "http://rise-check.test:\(port)/more.html")!)
        _ = await waitUntil(15) { await hidden(sameSite.page) != nil }
        check(await showsAd(sameSite.page), "Another page on the site shows its ad too")
        let elsewhere = browser.addTab(url: URL(string: "http://other-check.test:\(port)/ads.html")!)
        check(await waitUntil(15) { await hidden(elsewhere.page) == true }, "Another site is still blocked")
        browser.select(tab.id); browser.update()
        try? await Task.sleep(for: .milliseconds(300))

        // Off and on everywhere, the site stays as it was left.
        browser.toggleAdBlocking()
        _ = await waitUntil(15) { RCAdBlock.enabled == false }
        try? await Task.sleep(for: .milliseconds(800))
        browser.toggleAdBlocking()
        _ = await waitUntil(15) { RCAdBlock.enabled == true && !tab.page.isLoading }
        elsewhere.page.reload()
        check(await waitUntil(20) { await hidden(elsewhere.page) == true }, "Blocking back on hides ads elsewhere")
        tab.page.reload()
        _ = await waitUntil(10) { await loaded() }
        check(await showsAd(), "But not on the site left alone, as uBlock Origin keeps its list")

        // On that site the shield shows the slash, and blocks it again.
        browser.selectedBar.layoutSubtreeIfNeeded(); browser.update()
        browser.siteMenu()
        guard let content = browser.siteControlsPopover.contentViewController as? SiteControlsController,
              let button = content.quickActions[2] as? AdBlockButton else { check(false, "The popover has the button"); exit(1) }
        try? await Task.sleep(for: .milliseconds(500))
        check(button.showsSlash, "The shield is slashed on the site left alone")
        button.performClick(nil)
        check(!button.showsSlash, "Clicked, it's whole again")
        check(await says("Ad-blocking enabled on this site"), "The bar says it's enabled")
        check(await waitUntil(15) { await hidden() == true }, "And the page's ad is hidden after its reload")
        check(browser.siteControlsPopover.isShown && browser.siteControlsPopover.contentViewController === content, "The popover stays through it")
        check(kept() == [], "And the site is off the list")
        let tiles = browser.extensionActions.count

        // From whole, it's this site only, and the popover stays through the reload.
        let start = Date(), popoverFrame = button.window?.frame ?? .zero
        button.performClick(nil)
        check(button.showsSlash && kept() == ["rise-check.test"], "Clicked, this site is left alone")
        check(await says("Ad-blocking disabled on this site"), "The bar says it's disabled")
        try? await Task.sleep(for: .milliseconds(250))
        check(browser.selectedBar.notice?.text == "Ad-blocking disabled on this site", "Through the page's reload")
        check(browser.adBlocker.enabled && RCAdBlock.enabled, "With uBlock Origin still on")
        var moved = false
        while Date().timeIntervalSince(start) < 1.6 {
            if button.window?.frame != popoverFrame { moved = true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check(!moved && browser.siteControlsPopover.isShown, "The popover stays open where it was")
        _ = await waitUntil(15) { await loaded() }
        check(await showsAd(), "The page reloads with its ad")
        check(browser.extensionActions.count == tiles, "Its extension tiles don't change")
        browser.refreshSiteControls()
        check(browser.siteControlsPopover.contentViewController === content, "A refresh keeps the popover")
        // With this site left alone, a page showing on another site is still blocked.
        browser.siteControlsPopover.close()
        browser.select(elsewhere.id); browser.update()
        elsewhere.page.reload()
        _ = await waitUntil(10) { !elsewhere.page.isLoading }
        check(await waitUntil(15) { await hidden(elsewhere.page) == true }, "And elsewhere stays blocked")
        browser.select(tab.id); browser.update()
        try? await Task.sleep(for: .milliseconds(300))
        browser.siteMenu()
        let again = (browser.siteControlsPopover.contentViewController as? SiteControlsController)?.quickActions[2] as? AdBlockButton
        again?.performClick(nil)
        check(again?.showsSlash == false && kept() == [], "Clicked again, the shield is whole")
        check(await waitUntil(15) { await hidden() == true }, "The page reloads without its ad")

        // Off everywhere, as a setting can leave it, the shield is the way back.
        browser.siteControlsPopover.close()
        browser.toggleAdBlocking()
        _ = await waitUntil(15) { RCAdBlock.enabled == false }
        let off = SiteControlsController(browser: browser); off.loadViewIfNeeded()
        let offButton = off.quickActions[2] as? AdBlockButton
        check(offButton?.showsSlash == true, "Off everywhere it's slashed")
        offButton?.performClick(nil)
        check(browser.adBlocker.enabled, "And turns it back on")
        _ = await waitUntil(15) { RCAdBlock.enabled == true }
        check(await waitUntil(20) { await hidden() == true }, "Its page's ad hidden again")
        let next = SiteControlsController(browser: browser); next.loadViewIfNeeded()
        check((next.quickActions[2] as? AdBlockButton)?.showsSlash == false, "Opened afresh it shows the state")

        // Reloading as people do: real ⌘R, and real clicks on the button, quicker than pages load.
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        func press() {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: browser.window!.windowNumber, context: nil, characters: "r",
                                                 charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!)
            }
        }
        browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        browser.window?.makeFirstResponder(tab.page.view)
        try? await Task.sleep(for: .milliseconds(500))
        for _ in 1...3 { press(); try? await Task.sleep(for: .milliseconds(150)) }
        check(await waitUntil(3) { prompt.panel.isPresented }, "Three quick ⌘Rs bring the panel down")
        prompt.panel.denyButton.performClick(nil)
        browser.select(elsewhere.id); browser.update()
        _ = await waitUntil(10) { !elsewhere.page.isLoading }
        try? await Task.sleep(for: .milliseconds(500))
        let reloadButton = browser.selectedReloadButton
        for _ in 1...3 { reloadButton?.performClick(nil); try? await Task.sleep(for: .milliseconds(120)) }
        check(await waitUntil(3) { prompt.panel.isPresented }, "Three quick clicks on Reload do too")
        prompt.panel.denyButton.performClick(nil)
        print(failures == 0 ? "PASS ad block button checks" : "FAIL \(failures) ad block button checks")
        exit(failures == 0 ? 0 : 1)
    }
}
