// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumCompanionRestChecks.swift
import AppKit
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumCompanionRestMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+60) { print("FAIL companion checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = CompanionRestRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// A hover card's companion page rests as a background tab between reads, and is a page on
/// screen while it's read.
@MainActor final class CompanionRestRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func wait(_ name: String, until ready: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !(await ready()), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(await ready(), name)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await exercise() } catch { check(false, String(describing: error)) }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func exercise() async throws {
        let suite = "RiseCompanionChecks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
        try """
        <!doctype html><title>Companion</title><ul id=list></ul>
        <script>
        window.frames_ = 0; window.ticks = 0;
        const frame = () => { window.frames_++; requestAnimationFrame(frame); }; requestAnimationFrame(frame);
        setInterval(() => window.ticks++, 20);
        </script>
        """.write(to: folder.appendingPathComponent("companion.html"), atomically: true, encoding: .utf8)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil) }
        browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let page = GmailPageReader.makeCompanion(in: browser.window!.contentView!)
        defer { GmailPageReader.close(page) }
        func value(_ body: String) async -> Any? { try? await page.evaluate(body, arguments: [:], in: nil, world: .page) }
        func counts() async -> (frames: Int, ticks: Int) {
            let both = await value("return [window.frames_, window.ticks]") as? [Int] ?? [0, 0]
            return (both[0], both[1])
        }
        // Its first load, as a reader's, is read with it shown.
        let url = URL(string: "http://localhost:\(ports[0])/companion.html")!
        try await HiddenAccessibilityView.reading(page) {
            page.load(url)
            try await wait("It loads while it's read") { page.url == url && !page.isLoading }
            check(await value("return document.visibilityState") as? String == "visible", "While read, it's a page on screen")
        }
        try await wait("Between reads, it's a background page") { await value("return document.visibilityState") as? String == "hidden" }
        try await Task.sleep(for: .seconds(1))
        let resting = await counts()
        try await Task.sleep(for: .seconds(3))
        let rested = await counts()
        print("OBSERVED resting 3 s: frames", rested.frames-resting.frames, "timer ticks", rested.ticks-resting.ticks, "(150 if running freely)")
        check(rested.frames == resting.frames, "Resting, it draws nothing")
        check(rested.ticks-resting.ticks <= 10, "Resting, its timers are slowed")
        // Shown for a read, it draws again at once.
        let shown = Date()
        try await HiddenAccessibilityView.reading(page) {
            let before = await counts().frames
            try await wait("Read again, it draws") { await counts().frames > before }
            print("OBSERVED first frame after showing:", Int(Date().timeIntervalSince(shown)*1000), "ms")
            check(await value("return document.visibilityState") as? String == "visible", "And is a page on screen again")
        }
        try await wait("And rests again after") { await value("return document.visibilityState") as? String == "hidden" }
    }
}
