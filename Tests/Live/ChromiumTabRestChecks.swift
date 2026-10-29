// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumTabRestChecks.swift
import AppKit
import RiseChromium
import RiseCore
@testable import Rise

@main @MainActor struct ChromiumTabRestMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+150) { print("FAIL tab rest checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = TabRestRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// Background tabs rest: Chrome freezes them, those left long enough sleep and come back as they
/// were, and their switcher pictures are kept for the next launch.
@MainActor final class TabRestRun: NSObject, NSApplicationDelegate {
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
    /// What `work` answers within `seconds`, or nil.
    func withTimeout(seconds: Double, _ work: @escaping @MainActor () async -> Any?) async -> Any? {
        await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            var finished = false
            func finish(_ value: Any?) { if !finished { finished = true; done.resume(returning: value) } }
            Task { @MainActor in finish(await work()) }
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
        let suite = "RiseTabRestChecks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let local = "http://localhost:\(port)"
        let page = { (title: String, body: String) in
            "<!doctype html><title>\(title)</title><body style='margin:0'><h1>\(title)</h1>\(body)<div style='height:4000px;background:linear-gradient(#fff,#36c)'></div>"
        }
        try? page("Story", "").write(to: folder.appendingPathComponent("story.html"), atomically: true, encoding: .utf8)
        try? page("Form", "<input id=reply value=''>").write(to: folder.appendingPathComponent("form.html"), atomically: true, encoding: .utf8)
        try? page("Freezer", """
            <script>
            window.froze = 0;
            document.addEventListener('freeze', () => { window.froze++; sessionStorage.froze = window.froze; });
            </script>
            """).write(to: folder.appendingPathComponent("freezer.html"), atomically: true, encoding: .utf8)
        let sessionURL = folder.appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: sessionURL, restore: false, preferences: preferences)
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil) }
        browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func loaded(_ tab: BrowserTab, _ url: String) async -> Bool {
            await waitUntil(15) { tab.page.url?.absoluteString == url && !tab.isLoading }
        }
        func script(_ tab: BrowserTab, _ body: String) async -> Any? { try? await tab.page.evaluate(body, arguments: [:], in: nil, world: .page) }

        let shown = browser.addTab(url: URL(string: local + "/story.html?shown")!)
        let story = browser.addTab(url: URL(string: local + "/story.html?first")!, background: true)
        _ = await loaded(story, local + "/story.html?first")
        story.load(URL(string: local + "/story.html?second")!)
        let storyLoaded = await loaded(story, local + "/story.html?second")
        _ = await script(story, "scrollTo(0, 1500); return scrollY")
        let form = browser.addTab(url: URL(string: local + "/form.html")!, background: true)
        _ = await loaded(form, local + "/form.html")
        _ = await script(form, "document.getElementById('reply').value = 'A reply I am still writing'; return true")
        let pinned = browser.addTab(url: URL(string: local + "/story.html?pinned")!, background: true)
        pinned.pinned = true
        let freezers = (1...6).map { browser.addTab(url: URL(string: local + "/freezer.html?\($0)")!, background: true) }
        for (index, tab) in freezers.enumerated() { _ = await loaded(tab, local + "/freezer.html?\(index+1)") }
        check(storyLoaded && browser.selectedID == shown.id, "The tabs load, one shown and the rest in the background")

        // Chrome's tab freezing: a background tab is hidden to its page, and freezes.
        // Chrome's tab freezing: background tabs are hidden to their pages, whether shown before or not.
        check(await script(form, "return document.visibilityState") as? String == "hidden", "A tab opened in the background is hidden to its page")
        browser.select(story.id)
        let storyShown = await waitUntil(3) { await script(story, "return document.visibilityState") as? String == "visible" }
        browser.select(shown.id)
        let storyLeft = await waitUntil(3) { await script(story, "return document.visibilityState") as? String == "hidden" }
        check(storyShown && storyLeft, "A tab shown and left is hidden to its page")
        check(await script(shown, "return document.visibilityState") as? String == "visible", "And the shown tab is visible")
        // A frozen page doesn't answer until it's shown or briefly woken; it notes its freezing first.
        let froze = await waitUntil(40) {
            let answer = await self.withTimeout(seconds: 0.5) { try? await freezers[1].page.evaluate("return Number(sessionStorage.froze || 0)", arguments: [:], in: nil, world: .page) }
            return answer == nil || (answer as? Int ?? 0) > 0
        }
        check(froze, "Chrome freezes tabs left in the background")
        let thawStart = Date()
        browser.select(freezers[1].id)
        let thawed = await waitUntil(5) { await script(freezers[1], "return document.visibilityState") as? String == "visible" }
        print("OBSERVED frozen tab answered after showing it in", Int(Date().timeIntervalSince(thawStart)*1000), "ms")
        let frozeCount = await script(freezers[1], "return Number(sessionStorage.froze || 0)") as? Int ?? 0
        check(thawed && frozeCount > 0,
              "Shown again, it runs at once, having been frozen")
        browser.select(shown.id)

        // Sleeping: a tab left out of sight a while lets its page go, once other tabs have been used since.
        browser.recentTabIDs.removeAll { $0 == story.id }
        let storyTitle = story.title, storyPicture = story.thumbnail, storyIcon = story.favicon
        weak var awakePage = story.page as AnyObject
        browser.sleepIdleTabs(now: Date().addingTimeInterval(3600))
        let slept = await waitUntil(70) { story.page.url == nil }
        check(slept, "A tab left in the background a while sleeps")
        check(await waitUntil(5) { awakePage == nil }, "And its page is let go")
        check(story.title == storyTitle && story.thumbnail === storyPicture && story.favicon === storyIcon && browser.tabs.contains { $0 === story }
              && story.url?.absoluteString == local + "/story.html?second", "Asleep, it keeps its place, title, picture, icon and address")
        try? await Task.sleep(for: .seconds(2))
        check(form.page.url != nil, "A tab with a part-filled form stays awake")
        check(pinned.page.url != nil, "A pinned tab stays awake")
        check(shown.page.url != nil && shown.page.view.window != nil, "The shown tab stays awake")
        browser.saveNow()
        let saved = SessionStorage.read(from: sessionURL)?.tabs.first { $0.id == story.id }
        check(saved?.url == local + "/story.html?second" && saved?.sessionState != nil, "Asleep, it's saved with its history")

        // Shown again, it comes back where it was, with its history.
        let woken = Date()
        browser.select(story.id)
        let back = await loaded(story, local + "/story.html?second")
        print("OBSERVED slept tab loaded again in", Int(Date().timeIntervalSince(woken)*1000), "ms")
        let scroll = await waitUntil(3) { (await script(story, "return scrollY") as? Double ?? 0) > 1000 }
        check(back && story.page.canGoBack, "Shown again, it loads back with its history")
        check(scroll, "And where it was scrolled to")
        check(story.page.view.window != nil, "And shows")
        browser.select(shown.id)

        // Switcher pictures are kept for the next launch.
        let pictured = browser.tabs.filter { $0.thumbnail != nil && $0.url != nil }
        try? await Task.sleep(for: .seconds(2))
        let store = TabPictureStore(folder: folder.appendingPathComponent("Tab Pictures"))
        let kept = pictured.filter { store.picture(for: $0) != nil }
        check(!pictured.isEmpty && kept.count == pictured.count, "Switcher pictures are kept on disk (\(kept.count) of \(pictured.count))")
        browser.saveNow()
        let relaunched = BrowserController(sessionURL: sessionURL, restore: true, preferences: preferences)
        defer { relaunched.saveWork?.cancel(); relaunched.window?.orderOut(nil); relaunched.stopTabSleep() }
        let restoredPictures = relaunched.tabs.filter { $0.thumbnail != nil }
        let unloaded = relaunched.tabs.filter { $0.id != relaunched.selectedID && $0.page.url == nil }
        check(restoredPictures.count >= kept.count, "At the next launch, tabs have their pictures without loading (\(restoredPictures.count))")
        try? await Task.sleep(for: .seconds(3))
        check(!unloaded.isEmpty && unloaded.allSatisfy { $0.page.url == nil && !$0.hasAttemptedNavigation },
              "And background tabs aren't loaded to take pictures (\(unloaded.count) stayed unloaded)")
    }
}
