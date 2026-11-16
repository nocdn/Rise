// python3 scripts/test-chromium-live.py Tests/Live/ChromiumHistoryMenuChecks.swift
import AppKit
@testable import Rise
import RiseChromium

/// Right-clicking Back or Forward lists the page's history that way by title, nearest first, and
/// choosing one goes straight there, several pages at once.
@main @MainActor struct HistoryMenuChecksMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = HistoryMenuChecksRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class HistoryMenuChecksRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ valid: Bool, _ text: String) { print(valid ? "PASS" : "FAIL", text); if !valid { failures += 1 } }
    func wait(_ text: String, seconds: TimeInterval = 10, _ predicate: () -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < until { try await Task.sleep(for: .milliseconds(50)) }
        check(predicate(), text)
        if !predicate() { throw NSError(domain: text, code: 1) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.saveWork?.cancel(); browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let suite = "Rise.HistoryMenu.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName(""); browser.window?.setContentSize(NSSize(width: 1200, height: 800))
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let site = "http://localhost:\(ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0])"
        let names = ["One", "Two", "Three", "Four"]
        for name in names {
            try "<!doctype html><title>Page \(name)</title><h1>\(name)</h1>".write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        }
        let urls = names.map { URL(string: "\(site)/\($0).html")! }
        let tab = browser.addTab(url: urls[0]), page = tab.page
        browser.hidePalette()
        try await wait("The first page loads") { page.url == urls[0] && !page.isLoading && page.title == "Page One" }
        let arrows = browser.toolbarButtons.compactMap { $0 as? HistoryArrowButton }
        let back = arrows.first { $0.direction == .back }!, forward = arrows.first { $0.direction == .forward }!
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        browser.update()
        check(!back.isEnabled && back.menu(for: click) == nil, "With nothing behind, Back is off and has no menu")
        for (url, name) in zip(urls, names).dropFirst() {
            page.load(url)
            try await wait("\(name) loads") { page.url == url && !page.isLoading && page.title == "Page \(name)" }
        }
        browser.update()
        let titles = back.menu(for: click)?.items.map(\.title) ?? []
        check(titles == ["Page Three", "Page Two", "Page One"], "Back's menu lists the pages behind by title, nearest first: \(titles)")
        check(forward.menu(for: click) == nil, "With nothing ahead, Forward has no menu")

        let menu = back.menu(for: click)!
        menu.performActionForItem(at: 2)
        try await wait("Choosing Page One goes three pages back at once") { page.url == urls[0] && !page.isLoading }
        browser.update()
        check(back.menu(for: click) == nil, "Back has no menu at the start")
        let ahead = forward.menu(for: click)?.items.map(\.title) ?? []
        check(ahead == ["Page Two", "Page Three", "Page Four"], "Forward's menu lists the pages ahead: \(ahead)")
        forward.menu(for: click)!.performActionForItem(at: 1)
        try await wait("Choosing Page Three goes two forward") { page.url == urls[2] && !page.isLoading }
        browser.update()
        check(back.menu(for: click)?.items.map(\.title) == ["Page Two", "Page One"] && forward.menu(for: click)?.items.map(\.title) == ["Page Four"],
              "Both menus follow where it is now")
    }
}
