// Peek on Chromium pages, in a real Rise window: opening out of the clicked link, closing back
// into it, expanding into the tab and ⌘Z, a split and ⌘Z, and a swipe dismissing it. Every frame
// is recorded for checking by eye. Run with python3 scripts/test-chromium-live.py peek.
import AppKit
@testable import Rise
import RiseChromium

typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

@main @MainActor struct ChromiumPeekMain {
    static func main() {
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumPeekRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumPeekRun: NSObject, NSApplicationDelegate {
    let folder: String
    var browser: BrowserController!
    var failures = 0
    init(folder: String) { self.folder = folder }
    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { throw NSError(domain: "Timed out", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    /// Records the window for `duration` from now, at about 60 frames a second, into `name`/.
    /// What each frame shows of the Peek: its stand-in card's picture, the live card and its page.
    var peekState: String {
        let ghost = browser.peekGhosts.last
        return "ghost \(ghost == nil ? "-" : ghost!.pageLive != nil ? "live" : ghost!.pageImage == nil ? "blank" : "picture") card \(browser.peekCard.map { String(format: "%.2f", $0.alphaValue) } ?? "-") page \(browser.peekTab.map { $0.page.isLoading ? "loading" : ($0.page.title ?? "untitled") } ?? "-")"
    }
    func record(_ name: String, for duration: TimeInterval) async {
        let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Capture.self)
        var frames: [(TimeInterval, CGImage)] = [], states: [String] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime()-start < duration {
            if let image = capture(.null, 8, UInt32(browser.window!.windowNumber), 1|16)?.takeRetainedValue() {
                frames.append((CACurrentMediaTime()-start, image))
                let state = peekState
                if states.last?.hasSuffix(state) != true { states.append(String(format: "  %.3f %@", CACurrentMediaTime()-start, state)) }
            }
            try? await Task.sleep(for: .milliseconds(12))
        }
        if ProcessInfo.processInfo.environment["PEEK_STATES"] != nil { states.forEach { print($0) } }
        let directory = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, frame) in frames.enumerated() {
            let data = NSBitmapImageRep(cgImage: frame.1).representation(using: .png, properties: [:])!
            try? data.write(to: directory.appendingPathComponent(String(format: "%03d-%.3f.png", index, frame.0)))
        }
        print("recorded", name, frames.count, "frames")
    }
    /// Records while `action` runs, starting a frame ahead of it.
    func recording(_ name: String, for duration: TimeInterval, _ action: @escaping () -> Void) async {
        async let frames: Void = record(name, for: duration)
        try? await Task.sleep(for: .milliseconds(30))
        action()
        await frames
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { print("FAIL", error) ; failures += 1 }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func run() async throws {
        let dir = URL(fileURLWithPath: folder)
        let target = dir.appendingPathComponent("target.html"), source = dir.appendingPathComponent("source.html")
        try """
        <!doctype html><title>Target</title><body style="margin:0;font:28px -apple-system;background:linear-gradient(135deg,#2563eb,#9333ea);color:white;min-height:100vh">
        <h1 style="margin:0;padding:48px">Peeked page</h1><p style="padding:0 48px">Drawn by Chromium inside Rise's Peek card.</p>
        <p style="padding:0 48px"><a href="other.html" style="color:white">A link inside the Peek</a></p></body>
        """.write(to: target, atomically: true, encoding: .utf8)
        try "<!doctype html><title>Other</title><h1>Other</h1>".write(to: dir.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><title>Source</title><body style="margin:0;font:18px -apple-system;padding:40px 60px;background:#fafafa">
        <h1>Source page</h1>\((1...6).map { "<p>Paragraph \($0) with some text to read.</p>" }.joined())
        <p>Open <a id="peek" href="target.html" style="background:#fde68a;padding:2px 6px;border-radius:4px">this link in a Peek</a> to see it grow.</p>
        \((7...12).map { "<p>Paragraph \($0) with some more text.</p>" }.joined())</body>
        """.write(to: source, atomically: true, encoding: .utf8)

        browser = BrowserController(sessionURL: dir.appendingPathComponent("session.json"), restore: false)
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = browser.addTab(url: source)
        check(tab.page is ChromiumPage, "New tabs open in Chromium")
        try await waitUntil { tab.page.title == "Source" && !tab.page.isLoading }
        try await Task.sleep(for: .milliseconds(600))

        // The engine calls Peek leans on, timed.
        for _ in 0..<3 {
            var start = CACurrentMediaTime()
            let found = await tab.page.evaluate("return document.title", arguments: [:], world: nil) as? String
            let script = CACurrentMediaTime()-start; start = CACurrentMediaTime()
            let image = await tab.page.snapshot(width: nil)
            print(String(format: "script %.1f ms (%@), snapshot %.1f ms (%@)", script*1000, found ?? "nil", (CACurrentMediaTime()-start)*1000,
                         image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"))
        }
        // Peek finds the link under the pointer, or failing that the focused one.
        _ = await tab.page.evaluate("document.querySelector('#peek').focus()", arguments: [:], world: nil)
        let origin = await browser.peekLink(in: tab.page, locate: true)
        check((origin?.image != nil || tab.page.showsLiveLayers) && (origin?.rect.width ?? 0) > 100,
              "Peek finds the link, and a picture of it unless the page shows live: \(origin.map { "\($0.rect)" } ?? "nil")")

        // 1. Open, growing out of the link, cold: a Peek nobody hovered first.
        await recording("1-open", for: 1.0) { self.browser.showPeek(url: target, from: tab.page.view) }
        browser.closePeek(); try await Task.sleep(for: .milliseconds(400))
        // As usual, after a Shift-hover has rendered the page out of sight.
        browser.renderPeekStandby(target)
        try await waitUntil { self.browser.peekStandby?.tab.page.title == "Target" }
        try await Task.sleep(for: .milliseconds(700))
        await recording("1-open-standby", for: 1.0) { self.browser.showPeek(url: target, from: tab.page.view) }
        check(browser.peekStandby == nil, "The Peek takes the page the Shift-hover rendered")
        check(browser.peekTab?.page is ChromiumPage, "The Peek is a Chromium page, as the one it opened from")
        check(browser.peekOrigin?.page === tab.page, "The Peek remembers the link it grew out of")
        try await waitUntil { self.browser.peekTab?.page.title == "Target" }
        check(browser.peekCard?.alphaValue == 1, "The live card shows once the stand-in has landed")

        // 2. Close, shrinking back into the link.
        await recording("2-close", for: 0.8) { self.browser.closePeek(animated: true) }
        check(browser.peekTab == nil, "The Peek is closed")

        // 3. Expand into the tab, then ⌘Z puts it back.
        browser.showPeek(url: target, from: tab.page.view)
        try await waitUntil { self.browser.peekTab?.page.title == "Target" && self.browser.peekCard?.alphaValue == 1 }
        try await Task.sleep(for: .milliseconds(400))
        let peekPage = browser.peekTab!.page
        await recording("3-expand", for: 0.7) { self.browser.expandPeek(modifiers: []) }
        check(tab.page === peekPage, "Expanding hands the Peek's own live page to the tab")
        await recording("4-undo", for: 0.8) { _ = self.browser.undoPeekPromotion() }
        check(browser.peekTab?.page === peekPage && tab.page.title == "Source", "⌘Z puts the same page back in the Peek over the source")

        // 4. Into a split, then ⌘Z.
        try await Task.sleep(for: .milliseconds(500))
        await recording("5-split", for: 0.7) { self.browser.splitPeek() }
        check(browser.activeSplitGroup != nil, "The Peek became the split's right page")
        // Dragging the split's handle resizes both pages live, there and back.
        try await Task.sleep(for: .milliseconds(400))
        await recording("5b-drag", for: 1.1) {
            Task { @MainActor in
                let steps = 30
                for step in 0...steps {
                    let t = Double(step)/Double(steps)
                    self.browser.splitHandle.onDrag?(CGFloat(-220*sin(t*Double.pi)))
                    try? await Task.sleep(for: .milliseconds(28))
                }
                self.browser.splitHandle.onDragEnd?()
            }
        }
        check(abs((browser.activeSplitGroup?.fraction ?? 0)-0.5) < 0.01, "The split is back in the middle after the drag")
        try await Task.sleep(for: .milliseconds(300))
        await recording("6-unsplit", for: 0.8) { _ = self.browser.undoPeekPromotion() }
        check(browser.activeSplitGroup == nil && browser.peekTab != nil, "⌘Z puts it back in the Peek")
        // Chromium's frames sit in a flipped layer of its own, which must keep the page's size
        // through all the resizing, or the page shows offset with a blank band.
        func content(in layer: CALayer) -> CALayer? {
            if layer.isGeometryFlipped, layer.anchorPoint == .zero { return layer }
            return layer.sublayers?.lazy.compactMap(content).first
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = browser.peekTab!.page.view, frames = content(in: view.layer!)
        check(frames.map { abs($0.bounds.width-view.bounds.width) < 1 && abs($0.bounds.height-view.bounds.height) < 1 } == true,
              "Chromium's picture fills the Peek's page after the resizes: \(frames.map { "\($0.bounds.size)" } ?? "none") in \(view.bounds.size)")

        // 5. A two-finger swipe right dismisses it.
        try await Task.sleep(for: .milliseconds(500))
        let peekView = browser.peekTab!.page.view
        let center = peekView.convert(NSPoint(x: peekView.bounds.midX, y: peekView.bounds.midY), to: nil)
        func swipe(_ phase: NSEvent.Phase, _ x: Int32) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -x, wheel3: 0)!
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase == .began ? 1 : phase == .changed ? 2 : 4)
            // Without a window, an event's window location is its screen location.
            cg.location = NSPoint(x: center.x, y: NSScreen.screens[0].frame.maxY-center.y)
            return NSEvent(cgEvent: cg)!
        }
        // Swipes only steer the key window's pages.
        NSApp.activate(ignoringOtherApps: true); browser.window?.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        if !browser.window!.isKeyWindow {
            // macOS can refuse to bring a background program forward while the Mac is in use; the
            // check's own window then counts as key, as it would be for someone swiping.
            let getter = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!
            let window = browser.window!, original = unsafeBitCast(method_getImplementation(getter), to: (@convention(c) (NSWindow, Selector) -> Bool).self)
            let replacement: @convention(block) (NSWindow) -> Bool = { $0 === window || original($0, #selector(getter: NSWindow.isKeyWindow)) }
            method_setImplementation(getter, imp_implementationWithBlock(replacement))
        }
        print("swipe: key", browser.window!.isKeyWindow, "page under", browser.historyPage(at: swipe(.began, 30)).map { $0 === browser.peekTab?.page ? "peek" : "other" } ?? "none")
        await recording("7-swipe", for: 1.2) {
            Task {
                print("swipe began taken", self.browser.historySwipe.handle(swipe(.began, 30)))
                try? await Task.sleep(for: .milliseconds(320))
                let gesture = self.browser.historySwipe.gesture
                print("after probe: tracking", gesture.isTracking, "armed", gesture.isArmed)
                for _ in 0..<8 { _ = self.browser.historySwipe.handle(swipe(.changed, 40)); try? await Task.sleep(for: .milliseconds(16)) }
                print("after pull: armed", self.browser.historySwipe.gesture.isArmed, "pull", self.browser.historySwipe.gesture.arrowPull)
                _ = self.browser.historySwipe.handle(swipe(.ended, 0))
            }
        }
        check(browser.peekTab == nil, "Swiping right dismissed the Peek")
    }
}
