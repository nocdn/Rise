import AppKit
import RiseChromium
@testable import Rise

/// This build's half of the upgrade check (scripts/test-chromium-live.py upgrade): it opens the
/// profile the previous release made, with its engine and code (ChromiumUpgradeSeed.swift), in
/// RISE_PEEK_OUT/previous, and finds what that release kept there: its cookie, and the extension
/// it installed, still installed, with its files.
///
/// Chromium 158 marked the key older Chromiums encrypt with as unavailable for any profile outside
/// its default folder, as Rise's is, then dropped every cookie it couldn't read, and every
/// extension whose signed settings it couldn't check, files and all (patch 0055).
@main @MainActor struct ChromiumUpgradeMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+180) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/previous/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumUpgradeChecks(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumUpgradeChecks: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let suite = "RiseUpgradeCheck-\(UUID().uuidString)"
    let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").last.map(String.init)!
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: .page)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await checks()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func checks() async {
        let previous = folder.appendingPathComponent("previous")
        let version = (try? String(contentsOf: previous.appendingPathComponent("version"), encoding: .utf8)) ?? "?"
        guard let data = try? Data(contentsOf: previous.appendingPathComponent("seed.json")),
              let seed = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let cookie = seed["cookie"], let id = seed["extension"], let name = seed["name"] else {
            check(false, "Rise \(version) left what it made in seed.json"); return
        }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The extension Rise <version> installed is still installed, with its files.
        _ = await waitUntil("\(name), which Rise \(version) installed, loads", 20) { self.browser.isExtensionInstalled(id) }
        check(browser.isExtensionInstalled(id), "\(name), which Rise \(version) installed from the Web Store, is still installed")
        let files = previous.appendingPathComponent("chromium/Default/Extensions/\(id)")
        check(!((try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? []).isEmpty, "And its files are still in the profile")

        // Its cookie, on the same site (a cookie is the host's, whatever the port).
        try? "<!doctype html><title>Check</title><h1>Check</h1>".write(to: folder.appendingPathComponent("check.html"), atomically: true, encoding: .utf8)
        let url = URL(string: "http://localhost:\(port)/check.html")!
        let tab = browser.addTab(url: url)
        browser.select(tab.id)
        _ = await waitUntil("The check's page loads", 20) { tab.page.url == url && !tab.page.isLoading }
        let cookies = await value("return document.cookie", in: tab.page) as? String ?? ""
        check(cookies.contains(cookie), "The cookie Rise \(version) set is still there: \(cookies.isEmpty ? "no cookies" : cookies)")

        // Still there after Chromium has had time to tidy up what it thinks is gone.
        try? await Task.sleep(for: .seconds(35))
        check(browser.isExtensionInstalled(id) && !((try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? []).isEmpty,
              "\(name) and its files are still there half a minute on")
    }
}
