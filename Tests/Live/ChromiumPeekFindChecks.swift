// Find shortcuts on an actual Chromium Peek, independent of the background page's search.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumPeekFindChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumPeekFindMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+60) { print("FAIL Peek Find checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumPeekFindRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumPeekFindRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    func wait(_ description: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
        check(condition(), description)
        if !condition() { throw NSError(domain: description, code: 1) }
    }
    func command(_ key: String, code: UInt16, shift: Bool = false) {
        let characters = shift ? key.uppercased() : key
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command,
                                    timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        check(NSApp.mainMenu!.performKeyEquivalent(with: event), "The menu handles \(shift ? "⇧" : "")⌘\(key.uppercased())")
    }
    func search(_ query: String) {
        browser.findBar.input.stringValue = query
        browser.findBar.run(.restart)
    }
    func highlights(in page: WebPage) async -> Int {
        await page.evaluate("return (CSS.highlights.get('rise-find')?.size ?? 0) + (CSS.highlights.get('rise-find-current')?.size ?? 0)",
                            arguments: [:], world: PageFind.worldName) as? Int ?? -1
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
        try "<!doctype html><title>Source</title><p>backgroundneedle backgroundneedle</p>".write(to: folder.appendingPathComponent("source.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Peek</title><p>peekneedle peekneedle peekneedle</p>".write(to: folder.appendingPathComponent("peek.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Next</title><p>peekneedle</p>".write(to: folder.appendingPathComponent("next.html"), atomically: true, encoding: .utf8)
        let prefs = UserDefaults(suiteName: "rise-peek-find-\(UUID())")!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        browser.window?.setContentSize(NSSize(width: 1100, height: 760)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let source = browser.addTab(url: sourceURL), other = browser.addTab(url: sourceURL)
        try await wait("Source pages load") { source.page.title == "Source" && other.page.title == "Source" }
        browser.select(source.id)
        command("f", code: 3); search("backgroundneedle")
        let background = browser.findBar
        try await wait("Background Find has its own two matches") { background.count.stringValue == "1/2" }
        browser.showPeek(url: peekURL, from: source.page.view)
        try await wait("The live Peek finishes opening") {
            self.browser.peekTab?.page.title == "Peek" && self.browser.peekCard?.alphaValue == 1 && self.browser.peekGhosts.isEmpty
        }
        let peek = browser.peekTab!, page = peek.page
        command("f", code: 3)
        let bar = browser.findBar
        check(bar !== background && bar.superview === browser.peekCard?.subviews.first, "⌘F mounts a separate Find inside Peek")
        check(browser.window?.firstResponder === bar.input.currentEditor(), "Peek Find receives keyboard focus")
        search("peekneedle")
        try await wait("Find searches Peek's three matches") { bar.count.stringValue == "1/3" }
        command("g", code: 5)
        try await wait("⌘G advances the Peek match") { bar.count.stringValue == "2/3" }
        command("g", code: 5, shift: true)
        try await wait("⇧⌘G returns to the previous Peek match") { bar.count.stringValue == "1/3" }
        command("f", code: 3)
        check((bar.input.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 10), "Repeated ⌘F selects the Peek query")
        try await Task.sleep(for: .milliseconds(250))
        bar.layoutSubtreeIfNeeded()
        check(abs(bar.panel.frame.minY-FindBar.top) < 0.1 && abs(bar.bounds.maxX-bar.panel.frame.maxX-FindBar.margin) < 0.1,
              "The settled Peek panel uses the normal eight-point insets")
        check(await highlights(in: source.page) == 2, "Peek searching preserves the background page's highlights")

        browser.select(other.id)
        check(bar.superview == nil && browser.findBar !== bar, "A retained Peek's Find stays off the other tab")
        browser.select(source.id)
        try await wait("Returning restores the same Peek Find query and match") {
            self.browser.findBar === bar && bar.input.stringValue == "peekneedle" && bar.count.stringValue == "1/3"
        }
        peek.load(peekURL.deletingLastPathComponent().appendingPathComponent("next.html"))
        try await wait("Navigation refreshes Find against the new Peek page") { page.title == "Next" && bar.count.stringValue == "1/1" }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: browser.window!.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        browser.window?.sendEvent(escape)
        try await wait("Escape closes Find while leaving Peek open") { !bar.isPresented && self.browser.peekTab === peek }
        try await Task.sleep(for: .milliseconds(120))
        check(browser.window?.firstResponder === pageFocusTarget(page.view), "Escape restores focus to the Peek page")
        check(await highlights(in: page) == 0, "Closing Find clears the Peek highlights")
        check(await highlights(in: source.page) == 2, "Closing Peek Find leaves background matches untouched")
        browser.closePeek()
        check(browser.findBar === background && background.isPresented && background.superview === browser.root,
              "Closing Peek restores the background Find")
        check(browser.findBars[peek.id] == nil && bar.superview == nil, "Closing Peek releases its Find overlay")
        withExtendedLifetime(menus) {}
    }
}
