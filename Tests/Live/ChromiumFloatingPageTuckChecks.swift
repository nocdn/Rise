// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumFloatingPageTuckChecks.swift
import AppKit
import RiseChromium
import RiseCore
@testable import Rise

@main @MainActor struct ChromiumFloatingPageTuckMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL floating page tuck checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = FloatingPageTuckRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// A page's own floating window (Document Picture-in-Picture, as Meet's call uses), flicked off the
/// screen's side by two fingers on its title bar, tucks away under Rise's blurred veil, which shows
/// a chevron under the pointer and brings it back out.
@MainActor final class FloatingPageTuckRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func waitUntil(_ seconds: Double, poll: Int = 50, _ ready: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await ready()), Date() < deadline { try? await Task.sleep(for: .milliseconds(poll)) }
        return await ready()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        FloatingPageGestures.shared.install()
        Task { await run() }
    }
    func run() async {
        let defaults = UserDefaults(suiteName: "Rise.FloatingPageTuck.\(UUID())")!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        try? "<!doctype html><title>Call</title><h1>Call</h1>".write(to: folder.appendingPathComponent("call.html"), atomically: true, encoding: .utf8)
        let tab = browser.addTab(url: URL(string: "http://localhost:\(port)/call.html")!)
        _ = await waitUntil(10) { (try? await tab.page.evaluate("return location.pathname + ' ' + document.readyState", arguments: [:], in: nil, world: .page)) as? String == "/call.html complete" }
        let opened: Any?
        do { opened = try await tab.page.evaluate("""
            const w = await documentPictureInPicture.requestWindow({width: 420, height: 260});
            w.document.body.style.cssText = 'margin:0;background:linear-gradient(90deg,#e33,#33e)';
            w.document.body.innerHTML = '<h1 style="color:white;font:bold 40px system-ui">In the call</h1>';
            return true
            """, arguments: [:], in: nil, world: .page) } catch { opened = "\(error)" }
        check(opened as? Bool == true, "The page opens its floating window (\(opened ?? "nil"))")
        var found: NSWindow?
        check(await waitUntil(8) {
            found = NSApp.windows.first { $0.isVisible && FloatingPageGestures.isFloatingPage($0) }
            return found != nil
        }, "It's Chrome's floating page window")
        guard let window = found, let screen = window.screen else { finish(); return }
        try? await Task.sleep(for: .milliseconds(800))
        let area = FloatingVideoMotion.placementArea(visibleFrame: screen.visibleFrame, browserFrame: browser.window?.frame)
        let bar = NSPoint(x: window.frame.width/2, y: window.frame.height-10)
        let gestures = FloatingPageGestures.shared
        func move(by delta: CGVector, steps: Int, at time: Double, in target: NSWindow = window, at point: NSPoint? = nil) {
            let point = point ?? bar
            _ = gestures.route(.init(phase: .began, timestamp: time), in: target, at: point)
            for step in 1...steps {
                _ = gestures.route(.init(phase: .changed, translation: delta, timestamp: time+Double(step)/120), in: target, at: point)
            }
            _ = gestures.route(.init(phase: .ended, timestamp: time+Double(steps)/120), in: target, at: point)
        }
        let tuck = FloatingPageTuck.shared

        // Flicked off the right side.
        let distance = area.maxX-window.frame.maxX
        move(by: CGVector(dx: distance/4+20, dy: 0), steps: 4, at: 10)
        var midway = false
        let tucked = await waitUntil(3, poll: 8) {
            let progress = FloatingVideoMotion.tuckProgress(content: window.frame, visibleFrame: area)
            if progress > 0.1, progress < 0.9, tuck.veil(of: window)?.pageIsBlurred == true { midway = true }
            return tuck.edge(of: window) == .right && progress > 0.999
        }
        check(tucked, "A quick flick off the right side tucks it")
        check(midway, "It blurs on its way")
        let showing = window.frame.intersection(area).width
        check(abs(showing-window.frame.width*FloatingVideoMotion.tuckedShowing) < 1.5, "A tenth of it stays on the screen (\(showing) of \(window.frame.width))")
        guard let veil = tuck.veil(of: window) else { check(false, "It has its veil"); finish(); return }
        check(veil.frame == window.frame && !veil.ignoresMouseEvents, "The veil covers it and takes its clicks")
        check(veil.pageIsBlurred, "Its page is blurred")
        await pause("tucked", window.frame)
        veil.handle.setHovered(true)
        check(veil.handle.isShowingChevron, "Under the pointer it shows the chevron")
        veil.handle.layoutSubtreeIfNeeded()
        let part = window.frame.intersection(screen.frame).offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        let center = veil.handle.chevronCenter
        check(abs(center.x-part.midX) <= 0.5 && abs(center.y-part.midY) <= 0.5,
              "The chevron sits in the middle of the part showing (\(center) in \(part))")
        await pause("chevron", window.frame)

        // Two fingers anywhere on the veil move it, and a nudge leaves it tucked.
        move(by: CGVector(dx: -2, dy: 0), steps: 6, at: 20, in: veil, at: NSPoint(x: 20, y: 40))
        _ = await waitUntil(2) { tuck.edge(of: window) == .right && FloatingVideoMotion.tuckProgress(content: window.frame, visibleFrame: area) > 0.999 }
        check(tuck.edge(of: window) == .right, "A nudge on the veil leaves it tucked")

        _ = veil.handle.accessibilityPerformPress()
        check(!veil.handle.isShowingChevron, "The chevron brings it out, and goes")
        var unveiling = false
        let back = await waitUntil(3, poll: 8) {
            let progress = FloatingVideoMotion.tuckProgress(content: window.frame, visibleFrame: area)
            if progress > 0.1, progress < 0.9 { unveiling = true }
            return progress == 0 && tuck.veil(of: window) == nil
        }
        check(back && unveiling && area.contains(window.frame) && window.contentView?.layer?.filters?.isEmpty != false,
              "It comes back onto the screen, unblurring as it does")

        // Stopped on its way out, it turns round.
        move(by: CGVector(dx: (area.maxX-window.frame.maxX)/4+20, dy: 0), steps: 4, at: 30)
        try? await Task.sleep(for: .milliseconds(60))
        let partway = FloatingVideoMotion.tuckProgress(content: window.frame, visibleFrame: area)
        gestures.untuck(window)
        check(await waitUntil(3) { tuck.veil(of: window) == nil && area.contains(window.frame) } && partway < 0.95,
              "Brought back on its way out, it turns round (at \(partway))")
        finish()
    }
    /// With RISE_TUCK_PAUSE set, says where `rect` is (screen points from the top left) and waits,
    /// so the screen can be photographed from outside, which sees Chromium's drawing.
    func pause(_ name: String, _ rect: NSRect) async {
        guard ProcessInfo.processInfo.environment["RISE_TUCK_PAUSE"] != nil, let top = NSScreen.screens.first?.frame.maxY else { return }
        let r = rect.insetBy(dx: -30, dy: -30)
        print("SHOT \(name) \(Int(r.minX)),\(Int(top-r.maxY)),\(Int(r.width)),\(Int(r.height))")
        try? await Task.sleep(for: .seconds(2.5))
    }
    func finish() {
        print(failures == 0 ? "PASS floating page tuck checks" : "FAIL \(failures) floating page tuck checks")
        exit(failures == 0 ? 0 : 1)
    }
}
