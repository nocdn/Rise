import AppKit
import WebKit
@testable import Rise

@main @MainActor struct SidebarFloatBenchmarks {
    static func main() {
        let app = NSApplication.shared
        let delegate = SidebarFloatVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class SidebarFloatVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false)
                let window = browser.window!
                window.setFrameAutosaveName(""); window.setContentSize(NSSize(width: 1100, height: 760))
                browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
                for title in ["Floating fixture", "Second tab", "Third tab"] {
                    let tab = browser.addTab()
                    tab.webView.loadHTMLString("<title>\(title)</title><style>body{background:#f4f2e9;padding:60px;font:24px -apple-system;color:#354039}h1{font:60px Georgia}</style><h1>\(title)</h1><p>The page stays where it is.</p>", baseURL: URL(string: "https://example.com"))
                    try await wait { tab.webView.title == title }
                }
                let dockedLights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)!.convert(NSPoint.zero, to: nil) }
                browser.toggleSidebar()
                try await wait { window.isKeyWindow && self.browser.sidebar.isHidden }
                // Hold it out by keeping the real pointer over where the sidebar lands.
                placeWindow(pointerAt: 60)
                try await Task.sleep(for: .milliseconds(200))
                let page = browser.pageShadow.frame, inset = SidebarFloatAppearance.inset
                browser.sidebarFloat.edge.touched?()
                check(browser.isSidebarFloating, "Touching the edge slides the sidebar out")
                let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)! }
                let parts: [(String, NSView)] = [("close button", lights[0]), ("minimize button", lights[1]), ("zoom button", lights[2]),
                                                  ("sidebar button", browser.toolbarButtons[0]), ("back button", browser.toolbarButtons[1])]
                let reveal = try await sample(0.45) { [self] in
                    // Where each titlebar control sits relative to the sidebar, in window coordinates.
                    let sidebar = browser.sidebar.convert(browser.sidebar.bounds, to: nil)
                    let offsets = parts.map { _, view in
                        let rect = view.convert(view.bounds, to: nil)
                        return NSPoint(x: rect.minX-sidebar.minX, y: rect.maxY-sidebar.maxY)
                    }
                    return (browser.sidebar.frame.minX, browser.pageShadow.frame, offsets)
                }
                check(reveal.first!.0 < 0, "It starts past the window's edge: \(reveal.first!.0)")
                check(reveal.allSatisfy { $0.1 == page }, "The page never moves under it")
                for (index, (name, _)) in parts.enumerated() {
                    let xs = reveal.map { $0.2[index].x }, ys = reveal.map { $0.2[index].y }
                    check(xs.max()!-xs.min()! < 0.5 && ys.max()!-ys.min()! < 0.5,
                          "The \(name) moves with the sidebar as one block: x \(xs.min()!)...\(xs.max()!), y \(ys.min()!)...\(ys.max()!)")
                }
                check(browser.sidebarFloat.shadow.isHidden == false && browser.sidebarFloat.shadow.frame == browser.sidebar.frame
                      && browser.sidebarFloat.shadow.layer!.shadowOpacity > 0 && !browser.sidebarFloat.shadow.layer!.masksToBounds,
                      "The floating sidebar casts its shadow onto the page")
                let peak = reveal.map(\.0).max()!
                check(peak > inset+1 && peak < inset+6, "A subtle spring overshoot: peaks at \(peak)")
                // Settled once it stays within a quarter point of its rest for good.
                let settledAt = (reveal.lastIndex { abs($0.0-inset) >= 0.25 } ?? -1)+1
                let settle = settledAt < sampleTimes.count ? sampleTimes[settledAt] : .infinity
                check(browser.sidebar.frame.minX == inset, "It rests one margin in: \(browser.sidebar.frame)")
                check(browser.sidebar.frame.width == SidebarWidth.ideal, "It floats at the ideal width: \(browser.sidebar.frame.width)")
                check(settle > 0.22 && settle <= 0.27, "It settles in about a quarter second: \(settle)")
                print("Reveal: peak \(String(format: "%.2f", peak)), settled after \(String(format: "%.3f", settle))s")
                check(window.standardWindowButton(.closeButton)!.isEnabled && !window.standardWindowButton(.closeButton)!.isHidden, "Traffic lights work while floating")
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let light = window.standardWindowButton(kind)!.convert(NSPoint.zero, to: nil)
                    let docked = dockedLights[Int(kind.rawValue)]
                    check(light == NSPoint(x: docked.x+inset, y: docked.y-inset), "Traffic light \(kind.rawValue) rests carried with the sidebar: \(light), docked \(docked)")
                }
                capture("sidebar-floating")

                browser.toggleSidebar()
                let dock = try await sample(0.5) { (self.browser.pageShadow.frame.minX, self.browser.sidebar.frame) }
                let lefts = dock.map(\.0)
                check(zip(lefts, lefts.dropFirst()).allSatisfy { $1 >= $0-0.01 }, "The page slides over steadily to make room")
                check(lefts.contains { $0 > inset+20 && $0 < browser.sidebarWidth-20 }, "The page glides rather than jumping")
                check(browser.pageShadow.frame.minX == browser.sidebarWidth, "The page ends beside the sidebar")
                check(browser.sidebar.frame == NSRect(x: 0, y: 0, width: browser.sidebarWidth, height: browser.root.bounds.height), "The sidebar slots in")
                check(browser.sidebar.cornerRadius == 0 && browser.sidebar.layer?.shadowOpacity == 0, "Docked, it loses its float")
                let docked = sampleTimes[(lefts.lastIndex { abs($0-browser.sidebarWidth) >= 0.25 } ?? -1)+1]
                print("Dock: settled after \(String(format: "%.3f", docked))s")
                check(docked < 0.25, "Docking is quick: \(docked)")
                capture("sidebar-docked")

                // Collapsing springs the docked sidebar away as the page widens after it.
                browser.toggleSidebar()
                let collapse = try await sample(0.45) { (self.browser.pageShadow.frame.minX, self.browser.sidebar.frame.maxX, self.browser.sidebar.isHidden) }
                check(collapse.first.map { !$0.2 && $0.0 > inset+20 } == true, "The sidebar slides away rather than vanishing")
                check(collapse.allSatisfy { $0.2 || $0.1 <= $0.0+0.5 }, "The page's edge follows the sidebar without a gap opening under it")
                let lowest = collapse.map(\.0).min()!
                check(lowest < inset-0.3 && lowest > inset-4, "A gentle spring past the edge: \(lowest)")
                let collapsed = sampleTimes[(collapse.lastIndex { abs($0.0-inset) >= 0.25 } ?? -1)+1]
                check(collapsed > 0.2 && collapsed < 0.26 && browser.sidebar.isHidden, "Collapsing settles in about 0.23s: \(collapsed)")
                print("Collapse: lowest \(String(format: "%.2f", lowest)), settled after \(String(format: "%.3f", collapsed))s")

                // Opening from collapsed springs it back in, landing with a small overshoot.
                browser.toggleSidebar()
                let open = try await sample(0.45) { (self.browser.sidebar.frame.minX, self.browser.pageShadow.frame.minX) }
                check(open.first!.0 < -100, "It opens from the window's edge rather than appearing: \(open.first!.0)")
                let furthest = open.map(\.0).max()!
                check(furthest > 1 && furthest < 6, "Opening overshoots subtly: \(furthest)")
                let opened = sampleTimes[(open.lastIndex { abs($0.0) >= 0.25 } ?? -1)+1]
                check(opened < 0.27 && browser.sidebar.frame.minX == 0 && browser.pageShadow.frame.minX == browser.sidebarWidth, "Opening settles quickly and docks: \(opened)")
                print("Open: overshoot \(String(format: "%.2f", furthest)), settled after \(String(format: "%.3f", opened))s")
                browser.toggleSidebar()
                try await wait { self.browser.sidebar.isHidden }

                browser.sidebarFloat.edge.touched?()
                try await Task.sleep(for: .milliseconds(600))
                // Put the pointer just past the sidebar's right edge, onto its shadow.
                placeWindow(pointerAt: inset+SidebarWidth.ideal+4)
                let left = Date()
                try await wait { !self.browser.isSidebarFloating }
                check(Date().timeIntervalSince(left) < 0.1, "Leaving the sidebar tucks it straight away: \(Date().timeIntervalSince(left))")
                try await wait { self.browser.sidebar.isHidden }
                check(browser.pageShadow.frame == page, "Tucking away leaves the page alone")
                placeWindow(pointerAt: 60); try await Task.sleep(for: .milliseconds(150))
                browser.sidebarFloat.edge.touched?()
                try await Task.sleep(for: .milliseconds(45)); capture("sidebar-sliding")
                print("PASS: edge reveal with a subtle spring, page held still, animated docking, springy collapse and open, immediate tuck")
                browser.saveWork?.cancel(); window.orderOut(nil); NSApp.terminate(nil)
            } catch { fputs("SIDEBAR FLOAT VERIFICATION FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    func placeWindow(pointerAt x: CGFloat) {
        let window = browser.window!
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x-x, y: mouse.y-window.frame.height/2))
    }
    /// Seconds since sampling began, for each value of the last `sample`.
    var sampleTimes: [Double] = []
    func sample<T>(_ seconds: Double, _ value: @escaping () -> T) async throws -> [T] {
        let start = Date()
        var values = [value()]; sampleTimes = [0]
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(for: .milliseconds(8)); values.append(value()); sampleTimes.append(Date().timeIntervalSince(start))
        }
        return values
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(predicate(), "Timed out waiting")
    }
    func capture(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["RISE_SIDEBAR_FRAMES"], let id = browser.window?.windowNumber else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l\(id)", URL(fileURLWithPath: folder).appendingPathComponent(name+".png").path]
        try? task.run(); task.waitUntilExit()
    }
}
