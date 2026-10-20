// Real NavigationController restoration, including the portable list imported from WebKit.
// Run with python3 scripts/test-chromium-live.py Tests/Live/ChromiumNavigationHistoryChecks.swift.
import AppKit
import RiseCore
import RiseChromium
@testable import Rise

@main @MainActor struct NavigationHistoryMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL navigation checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder+"/chromium", keychain: false) else { print("FAIL engine startup"); exit(1) }
        let run = NavigationHistoryRun(folder: URL(fileURLWithPath: folder))
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class NavigationHistoryRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures: [String] = []
    let suite = "RiseNavigationHistory-\(UUID())"
    let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name); if !value { failures.append(name) }
    }
    func wait(_ page: WebPage, at url: URL) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if page.url == url, !page.isLoading {
                try? await Task.sleep(for: .milliseconds(75)); return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check(false, "Navigation to \(url), actual \(String(describing: page.url))")
    }
    func page(_ name: String, otherSite: Bool = false) throws -> URL {
        try "<!doctype html><title>\(name)</title><h1>\(name)</h1>".write(to: folder.appendingPathComponent(name+".html"), atomically: true, encoding: .utf8)
        return URL(string: "http://\(otherSite ? "127.0.0.1" : "localhost"):\(ports[otherSite ? 1 : 0])/\(name).html")!
    }
    func requests(_ file: String, server: Int) -> Int {
        let log = (try? String(contentsOf: folder.appendingPathComponent("server-\(server).log"), encoding: .utf8)) ?? ""
        return log.components(separatedBy: "\"GET /\(file).html ").count-1
    }
    func insert(_ saved: SavedTab) -> BrowserTab {
        let tab = browser.configure(BrowserTab(saved: saved)); browser.tabs.append(tab); browser.select(tab.id)
        return tab
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await exercise() } catch { check(false, String(describing: error)) }
            browser?.saveWork?.cancel(); browser?.syncedTabMetadata?.cancel()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? JSONSerialization.data(withJSONObject: ["failures": failures], options: [.prettyPrinted]).write(to: folder.appendingPathComponent("results.json"))
            print(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED"); exit(failures.isEmpty ? 0 : 1)
        }
    }
    func exercise() async throws {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.makeKeyAndOrderFront(nil)
        let a = try page("history-a"), b = try page("history-b", otherSite: true), c = try page("history-c")
        let addresses = [a,b,c].map(\.absoluteString)
        let tab = browser.addTab(url: a); await wait(tab.page, at: a)
        for url in [b,c] { tab.load(url); await wait(tab.page, at: url) }
        tab.page.goBack(); await wait(tab.page, at: b)
        check(tab.navigationHistory?.entries.map(\.url) == addresses && tab.navigationHistory?.index == 1, "Exports both directions and the committed cursor across origins")
        let saved = tab.saved
        check(saved.sessionState != nil, "A native local archive is saved")
        let local = insert(saved.withNewIdentity())
        await wait(local.page, at: b)
        check(local.page.canGoBack && local.page.canGoForward, "Local archive restores both directions")
        local.page.goBack(); await wait(local.page, at: a)
        local.page.goForward(); await wait(local.page, at: b)
        local.page.goForward(); await wait(local.page, at: c)
        check(local.navigationHistory?.index == 2, "Native archive traverses Forward to the last entry")

        let beforeA = requests("history-a", server: 0), beforeC = requests("history-c", server: 0)
        let history = TabNavigationHistory(entries: addresses.enumerated().map { .init(url: $0.element, title: "Page \($0.offset)") }, index: 1)
        let imported = insert(SavedTab(url: b.absoluteString, title: "B", navigationHistory: history))
        await wait(imported.page, at: b)
        check(imported.page.canGoBack && imported.page.canGoForward, "Portable import restores native Back and Forward")
        check(requests("history-a", server: 0) == beforeA && requests("history-c", server: 0) == beforeC, "Portable restoration loads only the selected website")
        check(imported.navigationHistory?.entries.map(\.url) == addresses && imported.navigationHistory?.index == 1, "Portable import preserves entries and cursor")
        _ = try await imported.page.evaluate("history.back(); return true", arguments: [:], in: nil, world: .page)
        await wait(imported.page, at: a)
        imported.page.goForward(); await wait(imported.page, at: b)
        imported.page.goForward(); await wait(imported.page, at: c)
        check(imported.navigationHistory?.index == 2, "Native and script traversal use the imported list")
        imported.page.goBack(); await wait(imported.page, at: b)
        let oldCount = imported.navigationHistory?.entries.count ?? 0
        _ = try await imported.page.evaluate("history.pushState({step:1}, '', location.href); history.pushState({step:2}, '', location.href); history.replaceState({step:3}, '', location.href); return true", arguments: [:], in: nil, world: .page)
        try await Task.sleep(for: .milliseconds(100))
        check(imported.navigationHistory?.entries.count == oldCount+1 && imported.navigationHistory?.index == 3, "Repeated same-URL pushes stay distinct and replaceState adds no entry")
        check(!imported.page.canGoForward, "A new branch discards Forward")
        let repeated = insert(imported.saved.withNewIdentity())
        await wait(repeated.page, at: b)
        repeated.page.goBack(); try await Task.sleep(for: .milliseconds(100))
        check(repeated.navigationHistory?.index == 2 && repeated.page.canGoForward, "Same-URL cursor changes survive local restoration")

        let held = browser.addTab(url: a); await wait(held.page, at: a)
        var chain = [a]
        for index in 0..<4 {
            let url = try page("peek-\(index)"); chain.append(url)
            let peek = browser.configure(BrowserTab()); peek.load(url); await wait(peek.page, at: url)
            browser.handOff(peek, into: held)
        }
        check(held.backPages.count == BrowserController.heldPageLimit && held.sessionState == nil, "Only bounded Peek pages stay live; persistence uses the flattened list")
        for expected in chain.dropLast().reversed() { browser.navigate(held.page, .back); await wait(held.page, at: expected) }
        check(held.navigationHistory?.entries.map(\.url) == chain.map(\.absoluteString) && held.navigationHistory?.index == 0, "Back still reaches the evicted Peek history")
        held.page.goForward(); await wait(held.page, at: chain[1])
        check(held.navigationHistory?.index == 1, "Forward works after restoring an evicted page")
    }
}

private extension SavedTab {
    func withNewIdentity() -> Self {
        SavedTab(url: url, title: title, sessionState: sessionState, navigationHistory: navigationHistory)
    }
}
