import AppKit
import WebKit
@testable import Rise

/// Drives the find bar in a real window: slide-in, the Tab swap to ask mode, a streamed
/// answer from the model, and the slide-out. Writes frames to RISE_FIND_FRAMES.
@main @MainActor struct FindBarBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = FindBarVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class FindBarVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var failures = 0
    let frames = ProcessInfo.processInfo.environment["RISE_FIND_FRAMES"].map { URL(fileURLWithPath: $0) }
    func check(_ condition: Bool, _ message: String) {
        print(condition ? "✓ \(message)" : "✗ \(message)"); if !condition { failures += 1 }
    }
    func capture(_ name: String) {
        guard let frames, let window = browser.window else { return }
        let path = frames.appendingPathComponent("\(name).png").path
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? process.run(); process.waitUntilExit()
    }
    func type(_ text: String) {
        browser.findBar.input.stringValue = text
        browser.findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    /// A real Return key press through the window, so the field editor picks the command.
    func press(shift: Bool) {
        let window = browser.window!
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            // Queued like a real key press, so NSApp.currentEvent carries its modifiers.
            NSApp.postEvent(event, atStart: false)
        }
    }
    func escape() {
        let window = browser.window!
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            NSApp.postEvent(event, atStart: false)
        }
    }
    func heldEscape() {
        let window = browser.window!
        for (type, repeatKey) in [(NSEvent.EventType.keyDown, false), (.keyDown, true), (.keyUp, false)] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: repeatKey, keyCode: 53)!
            NSApp.postEvent(event, atStart: false)
        }
    }
    func highlights(_ web: WKWebView) async -> [Int] {
        let sizes = try? await web.callAsyncJavaScript("return ['rise-find', 'rise-find-current'].map(n => CSS.highlights.get(n)?.size ?? 0)", contentWorld: PageFind.world)
        return sizes as? [Int] ?? []
    }
    func scrollY(_ web: WKWebView) async -> Double {
        (try? await web.evaluateJavaScript("scrollY") as? Double) ?? -1
    }
    var panel: NSRect { browser.findBar.convert(browser.findBar.panel.frame, to: browser.root) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            do {
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false)
                browser.window?.setContentSize(NSSize(width: 1100, height: 720)); browser.window?.center(); browser.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                let tab = browser.addTab(), web = tab.webView
                let filler = String(repeating: "<p>Filler paragraph about browsers, tabs and the web.</p>", count: 60)
                web.loadHTMLString("""
                <html><head><title>Rise 2.0</title></head><body style="font: 16px -apple-system; padding: 40px">
                <h1>Rise 2.0 is coming</h1><p>We've been testing Rise 2.0 with a small group since August. Each re<b>lease</b> gets a beta first.</p>
                <p>The public release is planned for <b>March 3, 2027</b>, after a two-week beta that starts on February 15.</p>
                \(filler)<p id="last">Pricing stays free after the release.</p></body></html>
                """, baseURL: URL(string: "https://rise.example/blog/2-0"))
                try await Task.sleep(for: .milliseconds(900))
                browser.update(); browser.root.layoutSubtreeIfNeeded()
                let page = browser.findBar.frame, bar = browser.findBar

                browser.showFind()
                try await Task.sleep(for: .milliseconds(45))
                check(panel.minY < page.minY+FindBar.top-4 && abs(panel.maxX-(page.maxX-FindBar.margin)) < 0.5, "Bar drops in from the top, already in its column: \(panel)")
                capture("01-sliding-in")
                try await Task.sleep(for: .milliseconds(600))
                check(abs(panel.maxX-(page.maxX-FindBar.margin)) < 0.5 && abs(panel.minY-(page.minY+FindBar.top)) < 0.5, "Bar rests in the page's top-right corner: \(panel)")
                check(browser.window?.firstResponder === bar.input.currentEditor(), "Input takes focus")
                _ = try await web.evaluateJavaScript("window.__draftEsc = 0; for (const type of ['keydown', 'keyup']) addEventListener(type, e => { if (e.key === 'Escape') __draftEsc++ }, true); 0")
                press(shift: false); try await Task.sleep(for: .milliseconds(250))
                check(bar.mode == .ask && !bar.hasSubmittedQuestion && bar.input.stringValue.isEmpty, "Enter on an empty find input opens ask mode without submitting")
                heldEscape(); try await Task.sleep(for: .milliseconds(250))
                let draftLeaked = try await web.evaluateJavaScript("__draftEsc") as? Int
                check(bar.isPresented && bar.mode == .find && draftLeaked == 0, "Held Escape returns an unsent question to Find without reaching the page")
                // The first search starts from the first match on screen, so start from the top.
                let loadedAt = await scrollY(web)
                if loadedAt != 0 { print("Page loaded scrolled to \(loadedAt); scrolling back to the top"); _ = try? await web.evaluateJavaScript("scrollTo(0, 0)") }
                type("release")
                try await Task.sleep(for: .milliseconds(250))
                check(bar.count.stringValue == "1/3", "Typing counts every match, including one split across elements: \(bar.count.stringValue)")
                let painted = await highlights(web); check(painted == [2, 1], "All matches are highlighted, with the current one on top")
                capture("02-find")
                let top = await scrollY(web)
                press(shift: false); try await Task.sleep(for: .milliseconds(150))
                check(bar.count.stringValue == "2/3", "Enter steps to the next match: \(bar.count.stringValue)")
                press(shift: false); try await Task.sleep(for: .milliseconds(150))
                let scrolled = await scrollY(web)
                check(bar.count.stringValue == "3/3" && scrolled > top+200, "The last match scrolls into view: \(bar.count.stringValue), \(top) → \(scrolled)")
                capture("02b-find-last")
                press(shift: false); try await Task.sleep(for: .milliseconds(150))
                check(bar.count.stringValue == "1/3", "Enter wraps around to the first match: \(bar.count.stringValue)")
                press(shift: true); try await Task.sleep(for: .milliseconds(150))
                check(bar.count.stringValue == "3/3", "Shift-Enter steps backwards and wraps: \(bar.count.stringValue)")
                browser.findPrevious(); try await Task.sleep(for: .milliseconds(150))
                check(bar.count.stringValue == "2/3", "⇧⌘G steps backwards: \(bar.count.stringValue)")
                type("zzqx"); try await Task.sleep(for: .milliseconds(200))
                check(bar.count.stringValue == "0/0" && bar.input.textColor == .systemRed, "No matches shows 0/0 in red")
                capture("02c-no-match")
                check(bar.shimmer.isHidden, "No idle shimmer copy covers the red text")
                press(shift: false); try await Task.sleep(for: .milliseconds(60))
                let editor = bar.input.currentEditor() as? NSTextView
                let transitioning = editor?.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
                var normalColor = NSColor.labelColor
                bar.input.effectiveAppearance.performAsCurrentDrawingAppearance { normalColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
                check(transitioning != nil && transitioning != NSColor.systemRed && transitioning != normalColor, "Red text blends toward the normal color instead of changing instantly")
                capture("02d-enter-to-send-mid")
                try await Task.sleep(for: .milliseconds(300))
                check(bar.mode == .ask && bar.badge.caption == .send && bar.badge.alphaValue > 0.99, "Enter on no matches offers to ask: ⏎ Send")
                capture("02e-enter-to-send")
                check(bar.input.textColor == .labelColor, "The color transition settles to the native text color")
                escape(); try await Task.sleep(for: .milliseconds(300))
                check(bar.isPresented && bar.mode == .find && bar.input.stringValue == "zzqx" && bar.input.textColor == .systemRed, "Escape returns the unsent draft to its red search")
                press(shift: false); try await Task.sleep(for: .milliseconds(300))
                check(bar.mode == .ask && !bar.isAnswering, "Enter can offer the same draft again without submitting")
                escape(); try await Task.sleep(for: .milliseconds(300))
                check(bar.isPresented && bar.mode == .find && bar.badge.caption == .send, "Escape can repeatedly switch an unsent draft back to Find")
                type("release"); try await Task.sleep(for: .milliseconds(200))

                let other = browser.addTab()
                try await Task.sleep(for: .milliseconds(200))
                check(browser.findBar !== bar && !browser.findBar.isPresented && bar.superview == nil, "Another tab doesn't show this page's find bar")
                browser.showFind(); try await Task.sleep(for: .milliseconds(500))
                let emptyBar = browser.findBar
                browser.select(tab.id); try await Task.sleep(for: .milliseconds(300))
                check(browser.findBar === bar && bar.isPresented && bar.superview != nil && bar.count.stringValue.hasSuffix("/3"), "Returning restores the page's search: \(bar.count.stringValue)")
                check(abs(panel.minY-(page.minY+FindBar.top)) < 0.5, "It's back at rest, without sliding in: \(panel.minY)")
                browser.select(other.id); try await Task.sleep(for: .milliseconds(200))
                check(!emptyBar.isPresented && !browser.findBar.isPresented, "An empty find bar doesn't survive leaving its tab")
                browser.select(tab.id); try await Task.sleep(for: .milliseconds(300))
                browser.window?.makeFirstResponder(bar.input)

                bar.toggleMode()
                try await Task.sleep(for: .milliseconds(50))
                capture("03-swap-mid")
                try await Task.sleep(for: .milliseconds(400))
                check(bar.mode == .ask && bar.badge.alphaValue > 0.99, "Tab shows the Send badge")
                let asking = await highlights(web); check(asking == [0, 0], "Ask mode clears the find highlights")
                type("When is this getting publicly released?")
                if let video = ProcessInfo.processInfo.environment["RISE_FIND_VIDEO"], let window = browser.window, let screen = window.screen {
                    // The question's text through the answer and the shimmer's hand-back, for frame-by-frame checks.
                    let rect = window.convertToScreen(bar.input.convert(bar.input.bounds, to: nil))
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-v", "-V", "8", "-R", "\(Int(rect.minX)),\(Int(screen.frame.maxY-rect.maxY)),\(Int(rect.width)),\(Int(rect.height))", video]
                    try? process.run()
                }
                let badgeCenter = bar.badge.convert(NSPoint(x: bar.badge.bounds.midX, y: bar.badge.bounds.midY), to: bar.superview)
                check(bar.hitTest(badgeCenter) === bar.badge, "The Send badge takes clicks")
                press(shift: false); try await Task.sleep(for: .milliseconds(60))
                check(bar.badge.isThinking && bar.shimmer.isRunning, "Enter sends the question: Thinking, with the question shimmering")
                check(browser.window?.firstResponder !== bar.input.currentEditor() && bar.input.currentEditor() == nil, "Sending unfocuses the input")
                let pressed = bar.badge.layer?.transform.m11 ?? 1
                check(abs(pressed-1) < 0.001, "Submitting does not scale Send: \(pressed)")
                capture("05-thinking")
                var grew = false, doneAt: Date?, resetting = false; let start = Date()
                while (bar.isAnswering || bar.badge.caption != .reset) && Date().timeIntervalSince(start) < 60 {
                    try await Task.sleep(for: .milliseconds(20))
                    if bar.badge.caption == .done && doneAt == nil { doneAt = Date(); capture("05b-done") }
                    if bar.badge.caption == .reset && !resetting { resetting = true; capture("06b-reset-entering") }
                    if panel.height > FindBar.rowHeight+4 && !grew { grew = true; capture("06-streaming") }
                }
                while bar.isAnswering && Date().timeIntervalSince(start) < 60 { try await Task.sleep(for: .milliseconds(20)) }
                let answeredAt = Date()
                check(doneAt != nil, "Thinking turns to Done as soon as the model responds")
                check(resetting && bar.badge.caption == .reset && !bar.badge.isHidden, "Done swaps into the reset X")
                capture("07-answered")
                var still = 0
                while bar.shimmer.isRunning && Date().timeIntervalSince(answeredAt) < 3 {
                    // Window stills through the last sweep and the ease back (they work even if the window is covered).
                    if let frames, let window = browser.window, ProcessInfo.processInfo.environment["RISE_FIND_STILLS"] != nil {
                        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", frames.appendingPathComponent(String(format: "still-%03d.png", still)).path]
                        try? process.run(); still += 1
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let sweepEnd = Date().timeIntervalSince(answeredAt)
                check(!bar.shimmer.isRunning && sweepEnd <= InputShimmer.period+InputShimmer.restore+0.1, "The shimmer finishes its sweep and eases back, then stops: \(sweepEnd)s after the answer")
                try await Task.sleep(for: .milliseconds(100))
                check(bar.input.textColor == .labelColor, "The question's own color returns")
                capture("07a-restored")
                type("When is this getting publicly released in Europe?")
                try await Task.sleep(for: .milliseconds(60))
                capture("07b-send-returning")
                check(bar.badge.caption == .send && !bar.badge.isResting, "Editing swaps the reset X back to Send")
                try await Task.sleep(for: .milliseconds(400))
                check(bar.badge.isResting && bar.badge.caption == .send && abs((bar.badge.layer?.transform.m11 ?? 0)-1) < 0.001, "Send is back at full size, reading Send")
                browser.theme = .dark; browser.update()
                try await Task.sleep(for: .milliseconds(200))
                capture("07c-dark")
                browser.theme = .neutral; browser.update()
                let pasteboard = NSPasteboard(name: .init("rise-find-bar-check")); bar.pasteboard = pasteboard
                bar.copyAnswer()
                check(pasteboard.string(forType: .string) == bar.conversation.last?.answer.replacingOccurrences(of: "**", with: ""), "Copy puts the answer, as shown, on the pasteboard")
                bar.regenerate(); try await Task.sleep(for: .milliseconds(60))
                check(bar.isAnswering && bar.badge.isThinking, "Regenerate asks the same question again")
                let regenerating = Date()
                while bar.isAnswering && Date().timeIntervalSince(regenerating) < 60 { try await Task.sleep(for: .milliseconds(40)) }
                check(bar.conversation.count == 1, "Regenerate replaces the answer rather than adding a turn: \(bar.conversation.count)")
                try await Task.sleep(for: .milliseconds(800))
                check(bar.badge.caption == .send, "With the question edited, Send stays after a regenerated answer")
                try await Task.sleep(for: .milliseconds(1500))
                capture("07d-regenerated")
                let answer = bar.conversation.last?.answer ?? ""
                print("Answer: \(answer)")
                check(grew && panel.height > FindBar.rowHeight+10, "Panel grows to fit the streamed answer: \(panel.height)")
                check(answer.contains("March 3") || answer.contains("3 March"), "The model answers from the page")
                let passage = try await web.callAsyncJavaScript("const h = CSS.highlights.get('rise-passage'); return h ? [...h][0].toString() : ''", contentWorld: PageFind.world) as? String ?? ""
                print("Highlighted: \(passage)")
                check(passage.contains("March 3, 2027"), "The model highlights the passage that answers the question")

                escape(); try await Task.sleep(for: .milliseconds(400))
                check(!bar.isPresented, "Escape dismisses ask mode after an answer was received")
                browser.showFind(); try await Task.sleep(for: .milliseconds(400))
                bar.toggleMode()
                // Reuse a controlled stream for the reset checks below.
                bar.answer = { _, _ in AsyncThrowingStream { continuation in
                    continuation.yield("Reset verification answer"); continuation.finish()
                } }
                type("When is this getting publicly released?"); bar.send()
                try await Task.sleep(for: .milliseconds(650))
                _ = await PageFind.highlightPassage("March 3, 2027", in: web)
                check(bar.badge.caption == .reset, "The answered question restores its reset X")
                let resetFrame = bar.badge.resetButton.convert(bar.badge.resetButton.bounds, to: bar)
                let closeFrame = bar.close.convert(bar.close.bounds, to: bar)
                check(abs(resetFrame.minX-closeFrame.minX) < 0.1 && resetFrame.size == closeFrame.size && bar.badge.resetButton.hoverColor == bar.close.hoverColor, "The reset X matches the find X position, size and hover background")
                let resetCenter = bar.badge.resetButton.convert(NSPoint(x: 13, y: 14), to: bar.superview)
                check(bar.hitTest(resetCenter) === bar.badge.resetButton, "The reset X receives clicks through its native button")
                bar.badge.resetButton.performClick(nil)
                try await Task.sleep(for: .milliseconds(400))
                let resetPassage = try await web.callAsyncJavaScript("return CSS.highlights.get('rise-passage')?.size ?? 0", contentWorld: PageFind.world) as? Int
                let resetFind = await highlights(web)
                check(bar.mode == .find && bar.input.stringValue.isEmpty && bar.conversation.isEmpty && abs(panel.height-FindBar.rowHeight) < 0.5, "Reset clears the question and answer, returning to Find")
                check(resetPassage == 0 && resetFind == [0, 0], "Reset removes all page highlighting")
                check(browser.window?.firstResponder === bar.input.currentEditor(), "Reset focuses the empty find input")
                type("release")
                try await Task.sleep(for: .milliseconds(500))
                check(abs(panel.height-FindBar.rowHeight) < 0.5 && bar.count.stringValue.hasSuffix("/3"), "Find mode collapses the answer and finds again: \(panel.height), \(bar.count.stringValue)")
                capture("08-back-to-find")
                browser.showFind()
                check(!bar.isPresented, "⌘F again closes the bar")
                try await Task.sleep(for: .milliseconds(60))
                capture("09-sliding-out")
                try await Task.sleep(for: .milliseconds(700))
                check(bar.isHidden, "Bar hides once it has slid out")
                let selection = try await web.evaluateJavaScript("String(getSelection())") as? String
                let cleared = await highlights(web)
                check(selection?.lowercased() == "release" && cleared == [0, 0], "Closing clears highlights and selects the current match: \(selection ?? "nil")")
                browser.showFind(); try await Task.sleep(for: .milliseconds(500))
                _ = try await web.evaluateJavaScript("window.__esc = 0; for (const type of ['keydown', 'keyup']) addEventListener(type, e => { if (e.key === 'Escape') __esc++ }, true); 0")
                browser.window?.makeFirstResponder(web)
                heldEscape(); try await Task.sleep(for: .milliseconds(400))
                let leaked = try await web.evaluateJavaScript("__esc") as? Int
                check(!bar.isPresented && leaked == 0, "Held Escape closes the bar without reaching the page: \(leaked ?? -1) page events")
                escape(); try await Task.sleep(for: .milliseconds(400))
                let reached = try await web.evaluateJavaScript("__esc") as? Int
                check(reached == 2, "With the bar closed, Escape reaches the page: \(reached ?? -1) page events")
            } catch { print("error: \(error)"); failures += 1 }
            print(failures == 0 ? "All find bar checks passed" : "\(failures) find bar check(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
