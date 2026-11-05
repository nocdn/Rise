// Stash Peek in New Tab (⌥⌘P) on actual Chromium pages: the Peek closes as one with nowhere to go
// back to, and its live page carries on in a background tab right above the tab it was over.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumPeekStashChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumPeekStashMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL Peek stash checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumPeekStashRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumPeekStashRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    func wait(_ description: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(12)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        check(condition(), description)
        if !condition() { throw NSError(domain: description, code: 1) }
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        await page.evaluate(script, arguments: [:], world: nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
        let sourceURL = URL(string: "http://localhost:\(ports[0])/source.html")!
        let peekURL = URL(string: "http://127.0.0.1:\(ports[1])/stash.html")!
        try "<title>Source</title><a id=peek href='\(peekURL)'>Open Peek</a>".write(to: folder.appendingPathComponent("source.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Stashed</title><body style='min-height:4000px'><input id=note></body>"
            .write(to: folder.appendingPathComponent("stash.html"), atomically: true, encoding: .utf8)
        let prefs = UserDefaults(suiteName: "rise-peek-stash-\(UUID())")!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.window?.setContentSize(NSSize(width: 1100, height: 760)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        let stashItem = NSApp.mainMenu!.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == #selector(BrowserController.stashPeekInNewTab) }
        check(stashItem?.title == "Stash Peek in New Tab" && stashItem?.keyEquivalent == "p"
              && stashItem?.keyEquivalentModifierMask == [.command, .option], "The Tabs menu has Stash Peek in New Tab, ⌥⌘P")

        // Two tabs, so the new one has a place between them.
        let below = browser.addTab(url: sourceURL), source = browser.addTab(url: sourceURL)
        try await wait("The source pages load") { source.page.title == "Source" && below.page.title == "Source" }
        browser.select(source.id)
        check(stashItem.map { browser.validateMenuItem($0) } == false, "Without a Peek, there's nothing to stash")
        _ = await value("document.querySelector('#peek').focus(); return true", in: source.page)
        browser.showPeek(url: peekURL, from: source.page.view)
        try await wait("Peek opens with its live page") {
            self.browser.peekTab?.page.title == "Stashed" && self.browser.peekCard?.alphaValue == 1 && self.browser.peekGhosts.isEmpty
        }
        check(stashItem.map { browser.validateMenuItem($0) } == true, "With a Peek open, it can be stashed")
        let peek = browser.peekTab!, page = peek.page
        _ = await value("window.stashToken = Math.random(); document.querySelector('#note').value = 'Draft'; scrollTo(0, 600); return true", in: page)
        try await Task.sleep(for: .milliseconds(80))
        let token = await value("return stashToken", in: page) as? Double
        let count = browser.tabs.count

        let optionCommandP = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: "π", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
        check(NSApp.mainMenu!.performKeyEquivalent(with: optionCommandP), "⌥⌘P stashes the Peek")
        try await wait("The Peek closes") { self.browser.peekTab == nil && self.browser.peekCard == nil }
        check(browser.peekGhosts.contains { $0.phase == .closing } && browser.peekGhosts.allSatisfy { $0.link.alphaValue == 0 },
              "It closes as a Peek with nowhere to go back to: fading as it shrinks, not into its link")
        check(browser.peekGhosts.contains { $0.pageImage != nil }, "Showing a picture of its page as it goes, not a blank card")
        check(browser.tabs.count == count+1 && browser.tabs.contains { $0 === peek }, "Its page is now a tab of its own")
        let index = browser.tabs.firstIndex { $0 === peek }, sourceIndex = browser.tabs.firstIndex { $0 === source }
        check(index != nil && sourceIndex == index!+1, "Right above the tab it was over, as a ⌘-clicked link's tab goes")
        check(browser.selectedID == source.id && browser.selectedTab === source, "In the background: the tab it was over stays in front")
        check(peek.page === page && page.view.superview == nil, "The same page, off screen")
        try await wait("The close finishes") { self.browser.peekGhosts.isEmpty }
        let kept = await value("return stashToken", in: page) as? Double
        let draft = await value("return document.querySelector('#note').value", in: page) as? String
        let scroll = (await value("return scrollY", in: page) as? NSNumber)?.doubleValue ?? 0
        check(token != nil && kept == token && draft == "Draft" && scroll > 500, "Without loading again: its script, form and scroll carry on")

        browser.select(peek.id)
        try await wait("Selected, the stashed tab shows its page") { page.view.window === self.browser.window && !page.view.isHiddenOrHasHiddenAncestor }
        check(page.title == "Stashed" && browser.peekTab == nil, "As an ordinary tab")

        // ⌘Z puts it back in the Peek, as it does after a Peek grows into a tab.
        browser.select(source.id)
        browser.showPeek(url: peekURL, from: source.page.view)
        try await wait("Another Peek opens") { self.browser.peekTab?.page.title == "Stashed" && self.browser.peekGhosts.isEmpty }
        let second = browser.peekTab!
        browser.stashPeekInNewTab()
        try await wait("Stashed again") { self.browser.peekTab == nil && self.browser.tabs.contains { $0 === second } }
        check(browser.undoPeekPromotion(), "⌘Z undoes the stash")
        try await wait("The page is back in its Peek, out of the tabs") { self.browser.peekTab === second && !self.browser.tabs.contains { $0 === second } }
    }
}
