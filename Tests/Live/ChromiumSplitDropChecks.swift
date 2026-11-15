// Dragging a tab from the sidebar onto the page to split it, in a real Rise window, frame by frame:
// the targets as the drag begins, opens out over the page, nears each side and comes back to the
// sidebar, then a drop on the left target and the page sliding into the right half. Each frame's
// targets, the dragged page's picture, the dropped card and the page are written to
// split-drop-frames.txt in RISE_PEEK_OUT, to compare with Dia's (the same path, measured there).
// Run with scripts/test-chromium-live.py Tests/Live/ChromiumSplitDropChecks.swift.
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumSplitDropMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        _ = RCEngine.start(withCachePath: folder + "/chromium", keychain: false)
        let run = SplitDropRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class SplitDropRun: NSObject, NSApplicationDelegate {
    let folder: URL; var browser: BrowserController!
    var failures = 0
    var lines: [String] = []
    var link: CADisplayLink?
    var start = CACurrentMediaTime()
    var current: BrowserTab!, dragged: BrowserTab!
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    func check(_ ok: Bool, _ message: String) { print("\(ok ? "PASS" : "FAIL") \(message)"); if !ok { failures += 1 } }
    func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }
    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func page(_ u: CGFloat, _ v: CGFloat = 0.5) -> NSPoint {
        let body = browser.pageClip.convert(browser.pageBody, to: browser.root)
        return browser.root.convert(NSPoint(x: body.minX+body.width*u, y: body.minY+body.height*v), to: nil)
    }
    var pointer = NSPoint.zero
    /// Moves the drag to `to` over `seconds`, at 120 a second.
    func drag(to: NSPoint, over seconds: Double) async {
        let from = pointer, steps = max(1, Int(seconds*120))
        for i in 1...steps {
            let t = CGFloat(i)/CGFloat(steps)
            pointer = NSPoint(x: from.x+(to.x-from.x)*t, y: from.y+(to.y-from.y)*t)
            browser.sidebar.moveTabDrag(event(.leftMouseDragged, at: pointer))
            try? await Task.sleep(for: .microseconds(8333))
        }
    }
    func hold(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds*1000))) }
    func mark(_ text: String) { lines.append(String(format: "%.4f MARK %@", CACurrentMediaTime()-start, text)); print("MARK", text) }

    /// Each frame: where everything is, in the window's points from its top left.
    @objc func tick(_ link: CADisplayLink) {
        let drop = browser.splitDrop, root = browser.root
        func top(_ rect: NSRect) -> String {
            let r = root.convert(rect, to: nil), h = browser.window!.contentView!.bounds.height
            return String(format: "%.1f,%.1f,%.1f,%.1f", r.minX, h-r.maxY, r.width, r.height)
        }
        let host = drop.host
        let l = drop.left, r = drop.right
        var parts = [String(format: "%.4f", link.targetTimestamp-start), "phase=\(drop.phase)", "lit=\(drop.lit.map { "\($0)" } ?? "-")"]
        parts.append("L=" + top(root.convert(host.convert(l.shownFrame, to: nil), from: nil)) + String(format: ",%.2f", l.opacity.value))
        parts.append("R=" + top(root.convert(host.convert(r.shownFrame, to: nil), from: nil)) + String(format: ",%.2f", r.opacity.value))
        if let card = dragged.page.view.superview?.superview, card.superview === root {
            parts.append("card=" + top(card.frame) + String(format: ",%.2f", card.alphaValue))
        }
        if let pageView = current.page.view.superview.map({ _ in current.page.view }) {
            parts.append("page=" + top(root.convert(pageView.convert(pageView.bounds, to: nil), from: nil)))
        }
        lines.append(parts.joined(separator: " "))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
            try "<!doctype html><title>Green</title><style>html,body{margin:0;height:100%;background:#00a050}</style>".write(to: folder.appendingPathComponent("green.html"), atomically: true, encoding: .utf8)
            try "<!doctype html><title>Magenta</title><style>html,body{margin:0;height:100%;background:#e0007a}</style>".write(to: folder.appendingPathComponent("magenta.html"), atomically: true, encoding: .utf8)
            let suite = "rise-split-drop-\(ProcessInfo.processInfo.processIdentifier)"
            let prefs = UserDefaults(suiteName: suite)!
            browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
            browser.window?.setFrame(NSRect(x: 8, y: 0, width: 1496, height: 944), display: true)
            browser.window?.setFrameTopLeftPoint(NSPoint(x: 8, y: (NSScreen.main?.frame.maxY ?? 982)-37))
            browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
            dragged = browser.addTab(url: URL(string: "http://localhost:\(port)/magenta.html")!)
            _ = await waitUntil(15) { self.dragged.page.url?.lastPathComponent == "magenta.html" && !self.dragged.page.isLoading }
            await hold(0.8)
            current = browser.addTab(url: URL(string: "http://localhost:\(port)/green.html")!)
            _ = await waitUntil(15) { self.current.page.url?.lastPathComponent == "green.html" && !self.current.page.isLoading }
            browser.select(current.id)
            _ = await waitUntil(3) { self.dragged.thumbnail != nil }
            await hold(1.0)
            print("INFO window \(browser.window!.frame) page \(browser.pageClip.convert(browser.pageBody, to: browser.root))")
            print("READY"); await hold(1.5)

            start = CACurrentMediaTime()
            link = browser.root.displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
            let row = browser.sidebar.rows[dragged.id]!
            pointer = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            mark("press")
            browser.sidebar.beginTabDrag(dragged.id, event: event(.leftMouseDown, at: pointer))
            await drag(to: NSPoint(x: pointer.x+40, y: pointer.y-10), over: 0.3)
            mark("to page"); await drag(to: page(0.5), over: 0.6); await hold(0.6)
            mark("to left"); await drag(to: page(0.15), over: 2.0); await hold(0.5)
            check(browser.splitDrop.lit == .left, "The left target lights near the left")
            mark("to middle"); await drag(to: page(0.5), over: 1.0); await hold(0.4)
            check(browser.splitDrop.lit == nil, "Neither in the middle")
            mark("to right"); await drag(to: page(0.85), over: 1.5); await hold(0.4)
            check(browser.splitDrop.lit == .right, "The right target lights near the right")
            mark("to sidebar"); await drag(to: NSPoint(x: pointer.x < 0 ? 100 : 100, y: page(0.5).y), over: 0.6); await hold(0.6)
            check(browser.splitDrop.phase == .waiting, "Over the sidebar, they wait")
            mark("to left again"); await drag(to: page(0.2), over: 0.7); await hold(0.5)
            mark("drop")
            browser.sidebar.endTabDrag(at: pointer)
            await hold(1.2)
            mark("end")
            link?.invalidate()
            let group = browser.splitGroups.first
            check(group?.leftID == dragged.id && group?.rightID == current.id, "Let go on the left, the tab takes the left half")
            check(browser.selectedID == current.id, "The page that was there stays chosen")
            check(browser.splitDrop.phase == .hidden, "The targets are gone")
            check(dragged.page.view.superview === browser.pageClip, "The tab's page is in the page")
            try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("split-drop-frames.txt"), atomically: true, encoding: .utf8)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
