import AppKit
import WebKit
@testable import Rise

@main @MainActor struct SplitBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = SplitVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class SplitVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    /// SPLIT_SHOTS=<folder> saves screenshots of the split view along the way.
    let shots = ProcessInfo.processInfo.environment["SPLIT_SHOTS"]
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            do {
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false)
                browser.window?.setContentSize(NSSize(width: 1100, height: 760)); browser.window?.center(); browser.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let source = folder.appendingPathComponent("source.html"), target = folder.appendingPathComponent("target.html")
                try """
                <body style="margin:0;padding:24px;background:#f6f6ef;font:15px Verdana"><h2>Source page</h2>
                <p>Some text on the page that was open before.</p>
                <a id="link" href="target.html">Open the target</a></body>
                """.write(to: source, atomically: true, encoding: .utf8)
                try "<body style='margin:0;padding:24px;background:#2a6df4;color:white;font:15px Verdana'><h2>Target page</h2><p>Opened from a Peek.</p></body>".write(to: target, atomically: true, encoding: .utf8)
                let tab = browser.addTab(url: source)
                try await waitUntil { !tab.webView.isLoading && tab.webView.url == source }
                browser.showPeek(url: target, from: tab.webView)
                try await Task.sleep(for: .milliseconds(800))
                let card = browser.peekCard!, peek = browser.peekTab!, peekPage = peek.webView, sourcePage = tab.webView
                _ = try await peekPage.evaluateJavaScript("window.riseMark = 4")
                let cardFrom = card.frame, pageFrom = sourcePage.frame
                let final = browser.splitFrames(in: browser.pageBody, fraction: 0.5)
                let rightInRoot = browser.pageClip.convert(final.right, to: browser.root)

                // Split: the card moves into the right half while the page narrows into the left, both live, without a bounce.
                var samples: [(time: Double, card: NSRect, cardPage: CGFloat, page: CGFloat)] = [], reloaded = false
                let pageRight = browser.pageClip.convert(browser.pageClip.bounds, to: browser.root).maxX
                let pressed = CACurrentMediaTime()
                browser.splitPeek()
                while browser.peekLiveMotion != nil || samples.isEmpty {
                    samples.append((CACurrentMediaTime()-pressed, card.frame, peekPage.frame.width, sourcePage.frame.width))
                    reloaded = reloaded || peekPage.isLoading
                    try await Task.sleep(for: .milliseconds(4))
                }
                let firstMove = samples.first { abs($0.card.width-cardFrom.width) > 0.5 }?.time ?? 1
                check(firstMove < 0.03, "The split starts straight away: \(Int(firstMove*1000)) ms")
                check(samples.contains { $0.card.width < cardFrom.width-20 && $0.card.width > final.right.width+20 && abs($0.cardPage-$0.card.width) < 0.5 },
                      "The Peek's page narrows live with its card: \(samples.map { Int($0.card.width) })")
                check(samples.contains { $0.page < pageFrom.width-20 && $0.page > final.left.width+20 }, "The page behind narrows live: \(samples.map { Int($0.page) })")
                let narrowest = samples.map(\.card.width).min()!, rightmost = samples.map(\.card.minX).max()!
                check(samples.allSatisfy { $0.card.maxX <= pageRight+0.01 }, "The card's bounce never carries it past the window's edge: \(samples.map(\.card.maxX).max()!) vs \(pageRight)")
                check(narrowest > final.right.width-0.01 && rightmost < rightInRoot.minX+0.01, "The card settles into its half without overshooting: \(narrowest) vs \(final.right.width), \(rightmost) vs \(rightInRoot.minX)")
                check(samples.map(\.page).min()! > final.left.width-0.01, "So does the page behind: \(samples.map(\.page).min()!) vs \(final.left.width)")
                check(zip(samples, samples.dropFirst()).allSatisfy { $1.card.width <= $0.card.width+0.01 && $1.page <= $0.page+0.01 }, "Both only ever move one way")
                let group = browser.activeSplitGroup
                check(group?.leftID == tab.id && group?.rightID == peek.id && browser.peekTab == nil, "The Peek's page is the right half of a split with the page it came from")
                check(sourcePage.frame == final.left && peekPage.frame == final.right && peekPage.superview === browser.pageClip, "Both settle exactly into their halves")
                check(browser.pageClip.convert(peekPage.frame, to: browser.root) == rightInRoot, "Right where the card landed")
                let kept = try await peekPage.evaluateJavaScript("window.riseMark") as? Int
                check(kept == 4 && !reloaded, "Without loading again")
                try await Task.sleep(for: .milliseconds(300))
                check(!browser.splitHandle.isHidden && browser.splitHandle.alphaValue == 1, "The handle shows between them")
                try await shot("split")

                // ⌘Z: the right half shrinks back into the Peek, live, over the page behind, whole again.
                var undoing: [(card: CGFloat, cardPage: CGFloat, outline: CGFloat, page: CGFloat)] = []
                check(browser.undoPeekPromotion(), "⌘Z puts the Peek back")
                let backCard = browser.peekCard!, cardTo = browser.peekCardFrame.width
                while browser.peekLiveMotion != nil || undoing.isEmpty {
                    undoing.append((backCard.frame.width, peekPage.frame.width, browser.pageClip.restingOutline?.boundingBoxOfPath.width ?? pageFrom.width, sourcePage.frame.width))
                    try await Task.sleep(for: .milliseconds(4))
                }
                check(abs(undoing.first!.card-final.right.width) < 2, "⌘Z starts from the right half: \(undoing.first!)")
                check(undoing.contains { $0.card > final.right.width+20 && $0.card < cardTo-20 }, "The card grows back through sizes in between: \(undoing.map { Int($0.card) })")
                // The Peek's real page resizes with its card every frame. The page behind is whole at once,
                // under the card, so the card uncovers it as it shrinks, with no gap at the right.
                check(undoing.allSatisfy { abs($0.cardPage-$0.card) < 0.5 }, "The Peek's real page resizes live: \(undoing.map { (Int($0.card), Int($0.cardPage)) })")
                check(undoing.allSatisfy { abs($0.page-pageFrom.width) < 0.5 && abs($0.outline-pageFrom.width) < 0.5 }, "The page behind is whole from the first frame: \(undoing.map { Int($0.page) })")
                check(sourcePage.frame == browser.pageBody && browser.splitGroups.isEmpty && browser.peekTab === peek && peekPage.frame == backCard.bounds,
                      "The page is whole again with the same Peek over it")
                check(browser.pageClip.restingOutline == nil && browser.splitHandle.isHidden, "And the page is one card again")

                // Split again, without motion checks, to try the handle.
                try await Task.sleep(for: .milliseconds(400))
                browser.splitPeek()
                try await waitUntil { browser.peekLiveMotion == nil && browser.activeSplitGroup != nil }
                try await Task.sleep(for: .milliseconds(300))
                let handle = browser.splitHandle
                handle.mouseEntered(with: NSEvent())
                check(handle.lengthSpring != nil && handle.pillLength == SplitHandle.hoverLength, "Hovering springs the handle longer")
                try await Task.sleep(for: .milliseconds(400))
                try await shot("hover")
                handle.mouseDown(with: mouse(.leftMouseDown, at: handle))
                try await Task.sleep(for: .milliseconds(200))
                try await shot("pressed")
                let width = sourcePage.frame.width
                for step in 1...10 {
                    handle.mouseDragged(with: mouse(.leftMouseDragged, at: handle, dx: CGFloat(step)*12, from: width))
                    try await Task.sleep(for: .milliseconds(16))
                }
                check(abs(sourcePage.frame.width-(width+120)) < 1.5 && peekPage.frame.minX == sourcePage.frame.maxX+BrowserController.splitGap,
                      "Dragging moves the split, both pages live: \(sourcePage.frame.width) vs \(width+120)")
                try await shot("dragged")
                handle.mouseUp(with: mouse(.leftMouseUp, at: handle, from: width))
                handle.mouseDown(with: mouse(.leftMouseDown, at: handle, clicks: 2))
                try await waitUntil { browser.splitMotion == nil }
                check(abs(sourcePage.frame.width-final.left.width) < 0.5, "A double click springs it back to the middle")
                handle.mouseExited(with: NSEvent())
                browser.chooseTheme(.dark)
                try await Task.sleep(for: .milliseconds(400))
                try await shot("dark")
                print("Split verified: first move after \(Int(firstMove*1000)) ms, \(samples.count) split samples (narrowest \(narrowest) vs \(final.right.width)), \(undoing.count) ⌘Z samples.")
                NSApp.terminate(nil)
            } catch { fputs("SPLIT VERIFICATION FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    /// A mouse event at the middle of `view`, or `dx` along from where the split was `from` wide.
    func mouse(_ type: NSEvent.EventType, at view: NSView, dx: CGFloat = 0, from width: CGFloat? = nil, clicks: Int = 1) -> NSEvent {
        var point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        if let width { point.x = browser.pageClip.convert(NSPoint(x: width+BrowserController.splitGap/2, y: 0), to: nil).x }
        point.x += dx
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: browser.window!.windowNumber,
                                  context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    /// Saves the window as it is now, when SPLIT_SHOTS is set.
    func shot(_ name: String) async throws {
        guard let shots else { return }
        NSApp.activate(ignoringOtherApps: true); browser.window?.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(browser.window!.windowNumber)", "\(shots)/\(name).png"]
        try capture.run(); capture.waitUntilExit()
    }
    func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        check(condition(), "Timed out waiting at line \(line)")
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); if ProcessInfo.processInfo.environment["SPLIT_KEEP_GOING"] == nil { exit(1) } } }
}
