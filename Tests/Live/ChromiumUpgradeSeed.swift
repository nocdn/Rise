import AppKit
import RiseChromium
@testable import Rise

/// The previous release's half of the upgrade check (scripts/test-chromium-live.py upgrade): built
/// from that release's tag and run with its engine, it makes a profile in RISE_PEEK_OUT/chromium,
/// as anyone using it would: a lasting cookie, and an extension from the Chrome Web Store, added
/// through Rise's sheet. It then quits as Rise quits, so Chromium writes everything down, and
/// leaves what it made in seed.json for this build's half (ChromiumUpgradeChecks.swift).
///
/// Old releases build it, so it keeps to what Rise has long had (Rise 0.1.1's API).
@main @MainActor struct ChromiumUpgradeSeedMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+300) { print("FAIL the seed stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumUpgradeSeed(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// An extension that's small, long-lived and opens nothing as it installs.
enum UpgradeExtension {
    static let id = "bcjindcccaagfpapjjmafapmmgkkhgoa", name = "JSON Formatter"
}

@MainActor final class ChromiumUpgradeSeed: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    let suite = "RiseUpgradeSeed-\(UUID().uuidString)"
    let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").first.map(String.init)!
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

    func fail(_ message: String) -> Never { print("FAIL", message); exit(1) }
    func waitUntil(_ what: String, _ timeout: TimeInterval, _ condition: () async -> Bool) async {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { fail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: .page)
    }
    func open(_ url: URL) async -> BrowserTab {
        let tab = browser.addTab(url: url)
        browser.select(tab.id)
        await waitUntil("\(url) loads", 30) { !tab.page.isLoading && tab.page.url?.host != nil }
        return tab
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
            browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)

            // A cookie that lasts a year, on a page of the check's own site.
            let cookie = "rise_upgrade=\(UUID().uuidString)"
            try? "<!doctype html><title>Seed</title><h1>Seed</h1>".write(to: folder.appendingPathComponent("seed.html"), atomically: true, encoding: .utf8)
            let page = await open(URL(string: "http://localhost:\(port)/seed.html")!)
            _ = await value("document.cookie = '\(cookie); max-age=31536000; path=/'; return 0", in: page.page)
            guard (await value("return document.cookie", in: page.page) as? String)?.contains(cookie) == true else { fail("The cookie wasn't kept") }
            print("PASS The previous release keeps a cookie")

            // An extension from the Web Store, as its listing's Add to Rise adds it, through Rise's sheet.
            browser.addFromWebStore(UpgradeExtension.id)
            var accept: NSButton?
            await waitUntil("Rise's install sheet asks", 90) {
                accept = self.browser.window?.attachedSheet?.contentView.flatMap { Self.buttons(in: $0) }?.first { $0.title != "Cancel" }
                return accept != nil
            }
            accept?.performClick(nil)
            await waitUntil("\(UpgradeExtension.name) installs", 90) { self.browser.isExtensionInstalled(UpgradeExtension.id) }
            print("PASS The previous release installs \(UpgradeExtension.name) from the Web Store")

            let seed: [String: Any] = ["cookie": cookie, "extension": UpgradeExtension.id, "name": UpgradeExtension.name]
            try? JSONSerialization.data(withJSONObject: seed).write(to: folder.appendingPathComponent("seed.json"))
            // Settled, then quit as Rise does, so Chromium writes its cookies and settings down.
            try? await Task.sleep(for: .seconds(3))
            print("ALL PASSED")
            NSApp.terminate(nil)
        }
    }

    static func buttons(in view: NSView) -> [NSButton] {
        var found = view.subviews.flatMap { buttons(in: $0) }
        if let button = view as? NSButton { found.insert(button, at: 0) }
        return found
    }
}
