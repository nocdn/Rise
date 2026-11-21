// Searching rise://settings finds Rise's own settings among Chrome's, in a real Rise window.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumSettingsSearchChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct SettingsSearchMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL settings search timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder+"/chromium", keychain: false) else { exit(1) }
        let run = SettingsSearchRun(folder: URL(fileURLWithPath: folder))
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// Rise has no "You and Google" section, the one Chrome's search falls back on at the top level;
/// without it, a search hid every section and showed nothing at all.
@MainActor final class SettingsSearchRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    var tab: BrowserTab!
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) { print(value ? "PASS" : "FAIL", name); if !value { failures += 1 } }
    let deep = """
    function find(root, selector) {
      return root.querySelector(selector) || [...root.querySelectorAll('*')]
        .map(node => node.shadowRoot && find(node.shadowRoot, selector)).find(Boolean);
    }
    window.__errors = window.__errors || [];
    if (!window.__watching) {
      window.__watching = true;
      addEventListener('error', event => __errors.push(String(event.error?.stack || event.message)));
      addEventListener('unhandledrejection', event => __errors.push(String(event.reason?.stack || event.reason)));
    }
    const main = find(document, 'settings-main');
    """
    func js(_ source: String) async -> Any? {
        try? await tab.page.evaluate(deep+source, arguments: [:], in: nil, world: .page)
    }
    func waitUntil(_ seconds: Double, _ ready: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await ready()), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return await ready()
    }
    /// The sections showing, by id, once a search for `query` has settled.
    func search(_ query: String) async -> [String] {
        _ = await js("find(document, 'cr-toolbar-search-field').setValue(\(String(reflecting: query))); return true")
        _ = await waitUntil(5) { await self.js("return location.search.includes('search=')") as? Bool == true }
        try? await Task.sleep(for: .milliseconds(1200))
        let shown = await js("""
        return [...main.shadowRoot.querySelectorAll('#switcher [slot=view]')]
          .filter(view => getComputedStyle(view).display !== 'none' && ![...view.children].some(child => child.hasAttribute('hidden-by-search')))
          .map(view => view.id).join(',')
        """) as? String ?? ""
        return shown.split(separator: ",").map(String.init)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let suite = "rise-settings-search-\(UUID())"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
            browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            tab = browser.addTab(url: URL(string: "rise://settings")!)
            check(await waitUntil(20) { await self.js("return !!main && !!find(document, 'cr-toolbar-search-field')") as? Bool == true }, "Settings loads")
            try? await Task.sleep(for: .seconds(1))

            let bookmarks = await search("bookmark")
            check(bookmarks.contains("appearance"), "Bookmarks are found in Appearance, among Rise's own rows: \(bookmarks)")
            check(bookmarks.contains("riseShortcuts"), "and in Keyboard shortcuts")
            check(!bookmarks.contains("privacy"), "Sections without it stay hidden")
            let cookies = await search("cookies")
            check(cookies.contains("privacy"), "Chrome's own settings are found too: \(cookies)")
            check(await js("return !main.shadowRoot.querySelector('#noSearchResults').hidden") as? Bool == false, "With results, no 'No results'")
            let nothing = await search("zzzz no such setting")
            check(nothing.isEmpty, "Nothing matches nothing: \(nothing)")
            check(await js("return !main.shadowRoot.querySelector('#noSearchResults').hidden") as? Bool == true, "and says so")
            let cleared = await search("")
            check(await js("return location.pathname") as? String != nil && cleared.count >= 1, "Clearing the search shows a section again: \(cleared)")
            let errors = await js("return __errors") as? [String] ?? []
            check(errors.isEmpty, "No errors in the page: \(errors.map { $0.prefix(120) })")
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
}
