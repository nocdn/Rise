// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumFloatingPageDialogChecks.swift
import AppKit
import RiseChromium
import RiseCore
@testable import Rise

@main @MainActor struct ChromiumFloatingPageDialogMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL floating page dialog checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = FloatingPageDialogRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// A dialog over the page (here Chrome's print preview) leaves the page's floating window (Meet's
/// call) floating where it is: the engine made Chrome's windows without a parent the page's
/// dialogs, Meet's included, which took its level, two fingers' moves, and put it back at the top
/// of the page whenever the page's dialogs were placed again.
@MainActor final class FloatingPageDialogRun: NSObject, NSApplicationDelegate {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        FloatingPageGestures.shared.install()
        Task {
            await run()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async {
        let defaults = UserDefaults(suiteName: "Rise.FloatingPageDialog.\(UUID())")!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil) }
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        try? "<!doctype html><title>Call</title><h1>Call</h1>".write(to: folder.appendingPathComponent("call.html"), atomically: true, encoding: .utf8)
        let tab = browser.addTab(url: URL(string: "http://localhost:\(port)/call.html")!)
        guard let page = tab.page as? ChromiumPage else { check(false, "The tab is a Chromium page"); return }
        _ = await waitUntil(10) { (try? await page.evaluate("return document.readyState", arguments: [:], in: nil, world: .page)) as? String == "complete" }
        let opened = try? await page.evaluate("await documentPictureInPicture.requestWindow({width: 420, height: 260}); return true",
                                              arguments: [:], in: nil, world: .page)
        check(opened as? Bool == true, "The page opens its floating window")
        var found: NSWindow?
        guard await waitUntil(8, {
            found = NSApp.windows.first { $0.isVisible && FloatingPageGestures.isFloatingPage($0) }
            return found != nil
        }), let window = found else { check(false, "It's Chrome's floating page window"); return }
        try? await Task.sleep(for: .milliseconds(800))
        let before = window.frame

        browser.printPage()
        check(await waitUntil(10) { !page.browserView.canPrint }, "Chrome's print preview opens over the page")
        try? await Task.sleep(for: .seconds(2))
        check(window.parent == nil && window.level.rawValue >= NSWindow.Level.floating.rawValue,
              "The floating window stays floating, no one's child (level \(window.level.rawValue), parent \(window.parent.map { "#\($0.windowNumber)" } ?? "none"))")
        check(window.frame == before, "It stays where it was (\(window.frame) from \(before))")
        check(FloatingPageGestures.isFloatingPage(window), "Two fingers can still take it")

        // Moved by two fingers on its bar, it stays where it's left, with the preview still open.
        let gestures = FloatingPageGestures.shared, bar = NSPoint(x: window.frame.width/2, y: window.frame.height-10)
        _ = gestures.route(.init(phase: .began, timestamp: 10), in: window, at: bar)
        for step in 1...30 { _ = gestures.route(.init(phase: .changed, translation: CGVector(dx: -4, dy: -3), timestamp: 10+Double(step)/60), in: window, at: bar) }
        _ = gestures.route(.init(phase: .ended, timestamp: 10.6), in: window, at: bar)
        try? await Task.sleep(for: .seconds(1.5))
        let moved = window.frame
        check(moved.origin != before.origin, "Two fingers move it (\(moved) from \(before))")
        browser.window?.setFrame(browser.window!.frame.insetBy(dx: 20, dy: 0), display: true)
        try? await Task.sleep(for: .seconds(1))
        check(window.frame == moved && window.parent == nil, "Resizing the browser, which places the page's dialogs again, leaves it there (\(window.frame))")
        page.reload()
    }
}
