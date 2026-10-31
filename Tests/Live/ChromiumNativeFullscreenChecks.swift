// Native fullscreen's temporary window must close after its page returns, including
// exits during entry and tab switches while macOS is restoring the window.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumNativeFullscreenChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct NativeFullscreenMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+150) { print("FAIL fullscreen check timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = NativeFullscreenRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class NativeFullscreenRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    func wait(_ description: String, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(12)
        while !(await condition()), Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        let valid = await condition(); check(valid, description)
        if !valid { throw NSError(domain: description, code: 1) }
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        await page.evaluate(script, arguments: [:], world: nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.saveWork?.cancel(); browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let suite = "Rise.NativeFullscreen.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: PageFullscreen.simulatedKey)
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setContentSize(NSSize(width: 1100, height: 720)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
        let url = URL(string: "http://localhost:\(ports[0])/fullscreen.html")!
        try """
        <!doctype html><title>Native fullscreen</title><video id=video src=clip.mp4 controls muted loop style='width:600px;height:360px'></video>
        <script>window.events=[];document.addEventListener('fullscreenchange',()=>events.push(!!document.fullscreenElement));</script>
        """.write(to: folder.appendingPathComponent("fullscreen.html"), atomically: true, encoding: .utf8)
        let other = browser.addTab(url: url), tab = browser.addTab(url: url), page = tab.page
        try await wait("The video is ready") { await self.value("return document.querySelector('video')?.readyState >= 2", in: page) as? Bool == true }
        for mode in ["page", "Escape", "window", "close button", "during entry"] {
            browser.select(tab.id)
            _ = await value("document.querySelector('video').requestFullscreen();return 0", in: page)
            try await wait("\(mode): the native window receives the page") { page.isInNativeFullscreen && page.view.window is ChromiumFullscreenWindow }
            let window = page.view.window as! ChromiumFullscreenWindow
            var closes = 0
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { closes += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            if mode != "during entry" {
                try await wait("\(mode): macOS completes entry") { window.styleMask.contains(.fullScreen) }
                try await Task.sleep(for: .milliseconds(850))
            }
            switch mode {
            case "Escape":
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                window.sendEvent(event)
            case "window": window.toggleFullScreen(nil)
            case "close button": window.performClose(nil)
            default: _ = await value("document.exitFullscreen();return 0", in: page)
            }
            // An engine callback and Escape can both request exit in one turn.
            // Repeated requests must not toggle macOS back into fullscreen.
            window.leave(); window.leave()
            try await wait("\(mode): the page returns to its tab") { !page.isInNativeFullscreen && page.view.window === self.browser.window }
            browser.select(other.id)
            try await Task.sleep(for: .milliseconds(600))
            check(!window.isVisible, "\(mode): no blank window remains after switching tabs")
            check(closes == 1, "\(mode): the temporary window actually closes exactly once")
            browser.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(120))
            check(!window.isVisible, "\(mode): reactivating Rise does not resurrect the window")
        }
        check(NSApp.windows.filter { $0 is ChromiumFullscreenWindow && $0.isVisible }.isEmpty, "No fullscreen shells survive repeated transitions")
    }
}
