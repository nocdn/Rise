// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumTabArchiveChecks.swift
import AppKit
import RiseChromium
import RiseCore
@testable import Rise

@main @MainActor struct ChromiumTabArchiveMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("FAIL tab archive checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = TabArchiveRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// Tabs that go unused are archived from real pages, including frozen ones, and come back as they
/// were, while those in use in some way stay.
@MainActor final class TabArchiveRun: NSObject, NSApplicationDelegate {
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
    func answer(_ tab: BrowserTab, _ body: String, within seconds: Double = 0.5) async -> Any? {
        await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            var finished = false
            func finish(_ value: Any?) { if !finished { finished = true; done.resume(returning: value) } }
            Task { @MainActor in finish(try? await tab.page.evaluate(body, arguments: [:], in: nil, world: .page)) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); finish(nil) }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await exercise()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func exercise() async {
        let suite = "RiseTabArchiveChecks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let local = "http://localhost:\(port)"
        let write = { (name: String, body: String) in
            try? "<!doctype html><title>\(name)</title><body><h1>\(name)</h1>\(body)".write(to: self.folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        }
        write("Story", ""); write("Form", "<input id=reply value=''>")
        write("Freezer", "<script>document.addEventListener('freeze', () => { sessionStorage.froze = 1; });</script>")
        let sessionURL = folder.appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: sessionURL, restore: false, preferences: preferences)
        browser.stopTabSleep()
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil) }
        browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func open(_ path: String) async -> BrowserTab {
            let tab = browser.addTab(url: URL(string: local + path)!, background: true)
            _ = await waitUntil(15) { tab.page.url?.absoluteString == local + path && !tab.isLoading }
            return tab
        }
        func address(_ tab: BrowserTab) -> String { tab.url?.absoluteString ?? tab.requestedURL?.absoluteString ?? "" }

        let shown = browser.addTab(url: URL(string: local + "/Story.html?shown")!)
        let plain = await open("/Story.html?plain")
        plain.load(URL(string: local + "/Story.html?plain2")!)
        _ = await waitUntil(15) { plain.page.url?.absoluteString == local + "/Story.html?plain2" && !plain.isLoading }
        let form = await open("/Form.html")
        _ = await answer(form, "document.getElementById('reply').value = 'Still writing'; return true", within: 5)
        let left = await open("/Form.html?left")
        browser.select(left.id)
        _ = await waitUntil(5) { await self.answer(left, "return document.visibilityState") as? String == "visible" }
        _ = await answer(left, "document.getElementById('reply').value = 'Written, then left'; return true", within: 5)
        browser.select(shown.id)
        let pinned = await open("/Story.html?pinned"); pinned.pinned = true
        let renamed = await open("/Story.html?renamed"); renamed.rename("Keep this")
        _ = await open("/Story.html?other")
        let fresh = await open("/Story.html?fresh")
        var freezers: [BrowserTab] = []
        for number in 1...6 { freezers.append(await open("/Freezer.html?\(number)")) }
        // Pages at localhost are developer mode tabs, which get a week at the 48 hour limit.
        let old = TabUse(lastUsed: Date().addingTimeInterval(-200*3600))
        for tab in browser.tabs where tab !== fresh && tab !== shown { tab.use = old }
        // Longest unused first, so that those with forms come before the ten that always stay can save them.
        for (hours, tab) in [(400.0, form), (390, left), (380, plain), (370, freezers[1])] {
            tab.use = TabUse(lastUsed: Date().addingTimeInterval(-hours*3600))
        }
        check(browser.tabs.count >= 13, "The tabs load, one shown and the rest in the background")

        // Chrome freezes background pages, which then can't answer whether they hold a form part-filled.
        let frozen = await waitUntil(45) {
            let state = await self.answer(freezers[1], "return Number(sessionStorage.froze || 0)")
            return state == nil || (state as? Int ?? 0) > 0
        }
        check(frozen, "Chrome freezes pages in the background")
        check(left.leftWithEdits, "A page left part-filled is noted as such")

        let opened = browser.tabs.count
        let started = Date()
        await browser.archiveUnusedTabs()
        print("OBSERVED archiving took", Int(Date().timeIntervalSince(started)*1000), "ms")
        let open = Set(browser.tabs.map(\.id)), kept = browser.archivedTabs.entries
        check(!open.contains(plain.id) && kept.contains { $0.id == plain.id }, "An unused tab is archived")
        check(open.contains(form.id), "One with a form part-filled stays")
        check(open.contains(left.id), "As does one left part-filled, even frozen")
        check(open.contains(pinned.id), "A pinned tab stays")
        check(open.contains(renamed.id), "A renamed tab stays")
        check(open.contains(fresh.id), "A tab used recently stays")
        check(open.contains(shown.id) && browser.selectedID == shown.id, "The shown tab stays, and stays chosen")
        check(!open.contains(freezers[1].id), "A frozen page with nothing part-filled is archived")
        check(kept.count == 2 && browser.tabs.count == opened-2, "Those two are all that go, as ten stay open and the rest were next (\(browser.tabs.count) of \(opened))")
        check(browser.closedTabs.isEmpty, "⌘⇧T's list is left to tabs closed by hand")
        check(browser.selectedBar.notice?.text.contains("Archived") == true, "The address bar says so")

        // The list.
        browser.showArchivedTabs()
        check(await waitUntil(3) { browser.archivedTabsPopover.isShown }, "Archived Tabs opens")
        let list = browser.archivedTabsPopover.contentViewController as? ArchivedTabsController
        check(list?.shown.count == kept.count, "Listing each of them")
        try? await Task.sleep(for: .seconds(0.4))
        if let number = list?.view.window?.windowNumber,
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(number), [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("archived-tabs.png"))
        }
        browser.archivedTabsPopover.performClose(nil)
        _ = await waitUntil(3) { !browser.archivedTabsPopover.isShown }

        // Reopened, it comes back with its history.
        browser.reopenArchivedTab(plain.id)
        let back = browser.selectedTab
        check(back.map(address) == local + "/Story.html?plain2", "Reopened, it's the same page")
        let loaded = await waitUntil(15) { back?.page.url?.absoluteString == local + "/Story.html?plain2" && back?.isLoading == false }
        check(loaded && back?.page.canGoBack == true, "And it loads with its history")
        check(back.map { $0.use.lastUsed > Date().addingTimeInterval(-60) } == true, "And its time starts over")
        check(!browser.archivedTabs.entries.contains { $0.id == plain.id }, "And it's out of the list")
        browser.select(shown.id)

        // Everything survives relaunching.
        browser.saveNow(); browser.archivedTabs.flush()
        let remaining = browser.archivedTabs.entries.count
        let relaunched = BrowserController(sessionURL: sessionURL, restore: true, preferences: preferences)
        relaunched.stopTabSleep()
        defer { relaunched.saveWork?.cancel(); relaunched.window?.orderOut(nil) }
        check(relaunched.archivedTabs.entries.count == remaining && remaining > 0, "The archive survives relaunching (\(remaining))")
        check(relaunched.tabs.first { $0.id == pinned.id }?.use.lastUsed == pinned.use.lastUsed, "As do the times tabs were last used")
    }
}
