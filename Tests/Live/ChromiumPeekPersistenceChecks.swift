// Retained Peeks on actual Chromium pages: forms, scroll, history and declared favicons.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumPeekPersistenceChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumPeekPersistenceMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL Peek checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumPeekPersistenceRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumPeekPersistenceRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    func wait(_ description: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(12)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
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
        let peekURL = URL(string: "http://127.0.0.1:\(ports[1])/peek.html")!
        try "<title>Source</title><a id=peek href='\(peekURL)'>Open Peek</a>".write(to: folder.appendingPathComponent("source.html"), atomically: true, encoding: .utf8)
        let html = """
        <!doctype html><title>Retained Peek</title><link rel=icon href='/peek.png'>
        <body style='min-height:4000px'><input id=note><a href='/next.html'>Next</a></body>
        """
        try html.write(to: folder.appendingPathComponent("peek.html"), atomically: true, encoding: .utf8)
        try "<title>Next</title><h1>Next</h1>".write(to: folder.appendingPathComponent("next.html"), atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appendingPathComponent("peek.png"))
        let prefs = UserDefaults(suiteName: "rise-peek-persistence-\(UUID())")!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.window?.setContentSize(NSSize(width: 1100, height: 760)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let source = browser.addTab(url: sourceURL), other = browser.addTab(url: sourceURL)
        try await wait("The source pages load") { source.page.title == "Source" && other.page.title == "Source" }
        browser.select(source.id)
        _ = await value("document.querySelector('#peek').focus(); return true", in: source.page)
        browser.showPeek(url: peekURL, from: source.page.view)
        try await wait("Peek opens with its live page") {
            self.browser.peekTab?.page.title == "Retained Peek" && self.browser.peekCard?.alphaValue == 1 && self.browser.peekGhosts.isEmpty
        }
        let peek = browser.peekTab!, page = peek.page
        _ = await value("window.retentionToken = Math.random(); document.querySelector('#note').value = 'Keep my draft'; scrollTo(0, 700); return true", in: page)
        try await Task.sleep(for: .milliseconds(80))
        let token = await value("return retentionToken", in: page) as? Double
        let scroll = (await value("return scrollY", in: page) as? NSNumber)?.doubleValue ?? 0
        try await wait("The indicator receives the page's declared favicon") { peek.favicon != nil }
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[source.id]!
        check(row.showsPeek && row.peekIndicator.favicon.image === peek.favicon, "The source tab shows the actual Peek favicon")
        row.mouseExited(with: NSEvent()); row.layoutSubtreeIfNeeded()
        let indicator = row.peekIndicator.frame
        check(indicator.minX == row.close.frame.maxX+2, "The X sits to the left of the Peek indicator")
        row.mouseEntered(with: NSEvent()); row.layoutSubtreeIfNeeded()
        check(!row.close.isHidden && row.peekIndicator.frame == indicator,
              "Hover reveals the X without moving the favicon")
        check(row.peekIndicator.layer?.animation(forKey: TabListMotion.slideKey) == nil, "The favicon stays fixed")
        browser.select(other.id)
        check(browser.peekTab == nil && browser.peek(for: source.id) === peek && row.showsPeek, "Switching away retains the live page and its indicator")
        check(CATransform3DIsIdentity(browser.pageShadow.layer!.transform), "The other tab has no recede or Peek overlay")
        browser.showPeek(url: peekURL, from: other.page.view)
        let otherPeek = browser.peekTab!
        try await wait("The other tab can open its own Peek") { otherPeek.page.title == "Retained Peek" }
        browser.select(source.id)
        check(browser.peekTab === peek && browser.peekCard?.alphaValue == 1 && browser.peekGhosts.isEmpty,
              "Returning restores the same page immediately without another opening animation")
        let restoredToken = await value("return retentionToken", in: page) as? Double
        let draft = await value("return document.querySelector('#note').value", in: page) as? String
        let restoredScroll = (await value("return scrollY", in: page) as? NSNumber)?.doubleValue ?? 0
        check(restoredToken == token && draft == "Keep my draft", "JavaScript and the unfinished form survive without reloading")
        check(scroll > 600 && abs(restoredScroll-scroll) < 1, "The page keeps its scroll position")
        peek.load(URL(string: peekURL.deletingLastPathComponent().absoluteString + "next.html")!)
        try await wait("Peek navigation works after restoration") { page.title == "Next" && page.canGoBack }
        browser.select(other.id); browser.select(source.id); browser.goBack()
        try await wait("Peek history also survives another switch") { page.title == "Retained Peek" }
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        let commandW = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        check(NSApp.mainMenu!.performKeyEquivalent(with: commandW), "⌘W closes the restored Peek")
        check(browser.peek(for: source.id) == nil && browser.tabs.contains { $0 === source } && !row.showsPeek,
              "Its indicator disappears while the source tab stays open")
        browser.select(other.id)
        check(browser.peekTab === otherPeek, "The other tab's Peek remains independent")
        browser.closeTab(other.id)
        check(browser.peek(for: other.id) == nil && browser.suspendedPeeks.isEmpty, "Closing the source tab releases its Peek")
    }
}
