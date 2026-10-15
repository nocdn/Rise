// Rise sharing the app with Chrome: Rise's own menu bar, Dock menu and reopening, links from other
// apps and other devices, quitting after the last window, and quitting itself, which saves Rise's
// tabs before Chrome closes them and then ends the app.
// Run with python3 scripts/test-chromium-live.py app; with RISE_QUIT_BY_CLOSING=1, it quits by
// closing Rise's last window instead.
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumAppMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumAppRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumAppRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    var opened: [URL] = [], reopened = 0, tabCount = 0
    let quitsByClosing = ProcessInfo.processInfo.environment["RISE_QUIT_BY_CLOSING"] != nil
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }
    /// Windows Chrome made itself, not Rise's.
    var chromeWindows: [NSWindow] { NSApp.windows.filter { $0.isVisible && !($0.windowController is BrowserController) } }

    // What Rise's app delegate answers.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(); menu.addItem(withTitle: "Rise's Dock menu", action: nil, keyEquivalent: ""); return menu
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { reopened += 1; return false }
    func application(_ application: NSApplication, open urls: [URL]) { opened += urls }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await checks() } catch { check(false, "\(error)") }
            if failures > 0 { print("\(failures) FAILED"); exit(1) }
            // Quitting, as ⌘Q does, or closing the last window; applicationWillTerminate reports the rest.
            if quitsByClosing { browser.window?.performClose(nil) } else { NSApp.terminate(nil) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if quitsByClosing {
            check(browser.window?.isVisible == false, "Closing Rise's last window quits it")
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            if failures > 0 { exit(1) }
            return
        }
        check(tabCount >= 2 && browser.tabs.count == tabCount, "Rise hears it's quitting while its tabs are still there: \(browser.tabs.count)")
        browser.saveNow()
        let saved = (try? Data(contentsOf: folder.appendingPathComponent("session.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        check("\(saved ?? "")".components(separatedBy: "other.html").count > 1, "And saves them")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        // Chrome then closes its windows and ends the app; a failure ends it now.
        if failures > 0 { exit(1) }
    }

    func checks() async throws {
        let chromeMenus: Set = ["History", "Bookmarks", "Profiles", "Tab"]
        let titles = NSApp.mainMenu?.items.map(\.title) ?? []
        check(chromeMenus.isDisjoint(with: titles), "Chrome builds no menu bar of its own: \(titles)")

        let delegate = NSApp.delegate
        check(delegate?.applicationDockMenu?(NSApp)?.items.first?.title == "Rise's Dock menu", "The Dock menu is Rise's")
        let reopen = delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        check(reopen == false && reopened == 1, "Clicking the Dock icon asks Rise")
        let url = URL(string: "https://example.com/from-another-app")!
        delegate?.application?(NSApp, open: [url])
        check(opened == [url], "A link from another app opens in Rise")
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://example.com/from-another-device")!
        let continued = delegate?.application?(NSApp, continue: activity, restorationHandler: { _ in })
        check(continued == true && opened.last == activity.webpageURL, "And a page handed off from another device")
        check(delegate?.applicationShouldTerminateAfterLastWindowClosed?(NSApp) == true, "Rise quits after its last window, as it says")
        try await Task.sleep(for: .milliseconds(500))
        check(chromeWindows.isEmpty, "Chrome opens no window of its own: \(chromeWindows.map { "\(type(of: $0))" })")

        // Two tabs, to quit with.
        try "<!doctype html><title>Other</title><p>Other".write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setContentSize(NSSize(width: 1000, height: 700)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let first = browser.addTab(url: folder.appendingPathComponent("other.html"))
        let second = browser.addTab(url: URL(string: "about:blank")!)
        _ = await waitUntil("Both tabs load") { first.page.title == "Other" && !second.page.isLoading }
        tabCount = browser.tabs.count
        check(tabCount >= 2 && chromeWindows.isEmpty, "Rise's window, with no window of Chrome's")
    }
}
