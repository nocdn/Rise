#if DEBUG
import UIKit

/// A scripted pinch, run on Summarise's own clock in the real app, so its frames can be checked
/// moment by moment. Launching with `-RiseSummariseReplay <folder>` runs it over a stand-in for
/// the recording's page and saves the frames there (add `menu` for Summarise in More, `live`
/// for the real model, `gentle` for a slow pinch, or `timing` to print the frame gaps of a pinch
/// in real time on a real page); the tests run it too.
@MainActor enum SummariseReplay {
    static let argument = "-RiseSummariseReplay"
    /// The moments, in seconds into the replay, frames are saved at.
    static let frameTimes = [0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.6, 0.7, 0.8, 0.9, 1.1, 1.6, 2.6, 3.0, 3.56, 3.65]
    /// Caught again as it grows back: from the tap, through the pinch, to the summary again.
    static let regrabTimes = [3.0, 3.4, 3.45, 3.55, 3.6, 3.62, 3.65, 3.7, 3.75, 3.8, 3.85, 3.9, 4.0, 4.2, 4.6, 5.0, 5.5, 6.1, 6.3, 6.6]

    struct Result {
        /// How far down the bar was while the card loaded.
        var barWhileLoading: CGFloat = 0
        var revealed = false
        /// How tall the summary was laid out, which it must be to sit under the card.
        var summaryHeight: CGFloat = 0
        /// Whether the card had grown back into the page by the end.
        var finished = false
        /// How far the page under the card was left from where it was, nudged while it was hidden.
        var pageMoved: CGFloat = 0
    }

    /// Starts the replay once the stand-in page has loaded, if the app was launched for it.
    static func runIfRequested(in controller: BrowserViewController) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument) else { return }
        let destination = arguments.indices.contains(index+1) ? arguments[index+1] : nil
        let folder = destination.map { path in
            if path.hasPrefix("caches:") {
                return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(String(path.dropFirst("caches:".count)))
            }
            return URL(fileURLWithPath: path)
        }
        let kind = arguments.indices.contains(index+2) ? arguments[index+2] : ""
        Task {
            let result = switch kind {
            case "menu": await runFromMenu(in: controller, savingFramesTo: folder)
            case "live": await runLive(in: controller, savingFramesTo: folder)
            case "gentle": await run(in: controller, savingFramesTo: folder, pinch: .gentle)
            case "regrab": await run(in: controller, savingFramesTo: folder, regrab: true)
            case "recall": await recall(in: controller, savingFramesTo: folder)
            case "diskRecall": await diskRecall(in: controller)
            case "diskRecallPinch": await diskRecall(in: controller, pinching: true)
            case "cacheProbe": await cacheProbe(in: controller, savingTo: folder)
            case "followUpKeyboard": await followUpKeyboard(in: controller)
            case "send": await send(in: controller, savingFramesTo: folder)
            case "fades": await fades(in: controller, savingFramesTo: folder)
            case "timing": await timeStart(in: controller)
            case "close": await timeClose(in: controller)
            case "tabs": await swipeToTabs(in: controller, savingTo: folder)
            case "tabsDrag": await swipeToTabs(in: controller, savingTo: folder, slowDrag: true)
            case "tabsFlick": await swipeToTabs(in: controller, savingTo: folder, fastFlick: true)
            case "tabsNew": await tabsThenNewPage(in: controller)
            case "more": await openMore(in: controller)
            case "downloads": await downloads(in: controller, savingTo: folder)
            case "tabsPress": await pressTabs(in: controller)
            default: await run(in: controller, savingFramesTo: folder)
            }
            let report = "revealed \(result.revealed), bar \(result.barWhileLoading), summary \(result.summaryHeight), finished \(result.finished), page moved \(result.pageMoved)"
            if let folder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? report.write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// A scripted pinch: from where, to what scale, over how long, and where the fingers drift to.
    struct Pinch {
        var start: CGPoint, drift: CGPoint, endScale: CGFloat, duration: Double
        /// A hard pinch near the right edge, let go while still closing quickly.
        static let hard = Pinch(start: CGPoint(x: 0.85, y: 0.6), drift: CGPoint(x: -40, y: -60), endScale: 0.5, duration: 0.2)
        /// A slow pinch in the middle, let go once the fingers have stopped.
        static let gentle = Pinch(start: CGPoint(x: 0.5, y: 0.45), drift: .zero, endScale: 0.7, duration: 0.6)
    }

    static func run(in controller: BrowserViewController, savingFramesTo folder: URL?, pinch: Pinch = .hard,
                    regrab: Bool = false) async -> Result {
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        // The strip's colour and the first paint land a little after the load.
        try? await Task.sleep(for: .milliseconds(800))
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        var result = Result()
        let size = controller.view.bounds.size
        let start = CGPoint(x: pinch.start.x*size.width, y: pinch.start.y*size.height)
        controller.startSummarise(.pinch, at: start)
        guard let summarise = controller.summarise, let window = controller.view.window else { return result }
        var arrival: CheckedContinuation<PageSummary, Error>?
        summarise.makeSummary = { try await withCheckedThrowingContinuation { arrival = $0 } }
        summarise.manualTime = 0
        // As two fingers would, panning the page under the card.
        let pageOffset = controller.webView.scrollView.contentOffset
        if regrab { controller.webView.scrollView.contentOffset.y += 40 }

        let frames = Set((regrab ? regrabTimes : frameTimes).map { Int(($0*120).rounded()) })
        // The summary comes 1.2 s after letting go; a gentle pinch holds still for its last 0.15 s.
        let pinchStart = 0.05, pinchEnd = pinchStart+pinch.duration, latency = 1.2, tap = 3.5
        let hold = pinch.duration > 0.4 ? 0.15 : 0
        var began = false, ended = false, delivered = false, closed = false
        // Caught in the middle 0.12 s after the tap, pinched in hard over 0.15 s, and tapped again.
        let grab = tap+0.12, grabEnd = grab+0.15, retap = 6.0, middle = CGPoint(x: size.width/2, y: size.height/2)
        var grabbed = false, regrabbed = false, retapped = false
        var summaryHeight: CGFloat = 0
        for step in 0...840 {
            let t = Double(step)/120
            summarise.manualTime = t
            if t >= pinchStart, !began { began = true; summarise.beginPinch(at: start) }
            if began, !ended {
                let p = CGFloat(min(1, max(0, (t-pinchStart)/(pinchEnd-hold-pinchStart))))
                // Easing out, as fingers do.
                let e = pinch.duration > 0.4 ? 1-(1-p)*(1-p) : p
                summarise.updatePinch(scale: 1-e*(1-pinch.endScale),
                                      centroid: CGPoint(x: start.x+e*pinch.drift.x, y: start.y+e*pinch.drift.y))
                if t >= pinchEnd {
                    ended = true; summarise.endPinch(cancelled: false)
                    // The request waits a moment in real time before asking.
                    try? await Task.sleep(for: .seconds(SummariseMotion.requestDelay+0.1))
                }
            }
            if t >= pinchEnd+latency, !delivered, let arrival {
                delivered = true
                arrival.resume(returning: summary)
                for _ in 0..<5 { await Task.yield() }
            }
            if t >= tap, !closed {
                result.revealed = summarise.isRevealed; summaryHeight = summarise.summaryHeight
                closed = true; summarise.close()
            }
            if regrab, t >= grab, !regrabbed {
                if !grabbed { grabbed = true; summarise.grab(at: middle) }
                let p = CGFloat(min(1, (t-grab)/(grabEnd-grab)))
                summarise.updatePinch(scale: 1-0.45*p, centroid: CGPoint(x: middle.x, y: middle.y-80*p))
                if t >= grabEnd { regrabbed = true; summarise.endPinch(cancelled: false) }
            }
            if regrab, t >= retap, !retapped {
                retapped = true
                result.revealed = summarise.isRevealed; summaryHeight = min(summaryHeight, summarise.summaryHeight)
                summarise.close()
            }
            summarise.advance(to: t)
            if step == 120 { result.barWhileLoading = controller.bottomBar.transform.ty }
            if let folder, frames.contains(step) {
                await save(window, to: folder.appendingPathComponent(String(format: "f-%.2f.png", t)))
            }
            if controller.summarise == nil { break }
        }
        result.finished = controller.summarise == nil
        result.summaryHeight = summaryHeight
        result.pageMoved = controller.webView.scrollView.contentOffset.y-pageOffset.y
        return result
    }

    /// Summarises the stand-in page, closes it, then pinches the unchanged page again: the card
    /// should fly straight to its summary, shown at once, with no request. Frames are saved as
    /// `r-<t>.png`; `revealed` is whether it showed the summary at once on letting go.
    static func recall(in controller: BrowserViewController, savingFramesTo folder: URL?) async -> Result {
        _ = await run(in: controller, savingFramesTo: nil)
        try? await Task.sleep(for: .milliseconds(300))
        var result = Result()
        let size = controller.view.bounds.size, pinch = Pinch.hard
        let start = CGPoint(x: pinch.start.x*size.width, y: pinch.start.y*size.height)
        controller.startSummarise(.pinch, at: start)
        guard let summarise = controller.summarise, let window = controller.view.window else { return result }
        var asked = false
        summarise.makeSummary = { asked = true; return summary }
        summarise.manualTime = 0
        let pinchStart = 0.05, pinchEnd = pinchStart+pinch.duration
        var began = false, ended = false
        for step in 0...240 {
            let t = Double(step)/120
            summarise.manualTime = t
            if t >= pinchStart, !began { began = true; summarise.beginPinch(at: start) }
            if began, !ended {
                let p = CGFloat(min(1, max(0, (t-pinchStart)/(pinchEnd-pinchStart))))
                summarise.updatePinch(scale: 1-p*(1-pinch.endScale), centroid: CGPoint(x: start.x+p*pinch.drift.x, y: start.y+p*pinch.drift.y))
                if t >= pinchEnd { ended = true; summarise.endPinch(cancelled: false); result.revealed = summarise.isRevealed }
            }
            summarise.advance(to: t)
            if let folder, step%6 == 0, t >= pinchEnd {
                await save(window, to: folder.appendingPathComponent(String(format: "r-%.2f.png", t)))
            }
        }
        result.summaryHeight = summarise.summaryHeight
        result.finished = !asked
        summarise.finish()
        return result
    }

    /// On a real page: its text's fingerprint over time, and whether the tab has one after going
    /// Back and Forward again, written to `cache.txt`.
    static func cacheProbe(in controller: BrowserViewController, savingTo folder: URL?) async -> Result {
        var lines: [String] = []
        func wait(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func loaded() async { for _ in 0..<500 where controller.webView.isLoading { await wait(20) } }
        func key() async -> String {
            guard let snapshot = try? await PageAssistant.snapshot(of: controller.webView) else { return "no snapshot" }
            return String(SummaryCache.key(of: snapshot).prefix(12))+" (\(snapshot.text.count) chars)"
        }
        func tabKey() -> String { controller.tabs[controller.tabIndex].fingerprint(of: controller.webView).map { String($0.prefix(12)) } ?? "none" }
        controller.webView.load(URLRequest(url: URL(string: "https://www.inceptionlabs.ai/blog")!))
        await wait(500); await loaded(); await wait(1500)
        controller.webView.load(URLRequest(url: URL(string: "https://www.inceptionlabs.ai/blog/introducing-mercury-3")!))
        await wait(500); await loaded()
        for ms in [600, 2000, 5000] {
            await wait(ms == 600 ? 600 : ms == 2000 ? 1400 : 3000)
            lines.append("at \(ms) ms: text \(await key()), tab \(tabKey())")
        }
        controller.webView.goBack()
        await wait(500); await loaded(); await wait(1500)
        lines.append("back on \(controller.webView.url?.absoluteString ?? "?")")
        controller.webView.goForward()
        await wait(500); await loaded(); await wait(1500)
        lines.append("forward on \(controller.webView.url?.absoluteString ?? "?"): text \(await key()), tab \(tabKey())")
        await wait(3000)
        lines.append("3 s later: text \(await key()), tab \(tabKey())")
        if let folder { try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("cache.txt"), atomically: true, encoding: .utf8) }
        var result = Result(); result.finished = true
        return result
    }

    /// Keeps a summary of the stand-in page on disk by its text's fingerprint, reloads the page
    /// (which forgets the one in memory), and summarises it from More: `finished` reports that it
    /// came back from disk without asking for a summary.
    static func diskRecall(in controller: BrowserViewController, pinching: Bool = false) async -> Result {
        var result = Result()
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        guard let snapshot = try? await PageAssistant.snapshot(of: controller.webView) else { return result }
        SummaryCache.store(summary, for: SummaryCache.key(of: snapshot))
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        // Past the fingerprints taken after loading.
        try? await Task.sleep(for: .milliseconds(3500))
        if pinching {
            // As if the text had still been landing when the page loaded: only the fingerprint
            // taken as the pinch starts can find it.
            let web = controller.webView
            controller.tabs[controller.tabIndex].fingerprint("stale", of: web, url: web.url, item: web.backForwardList.currentItem)
            let size = controller.view.bounds.size, pinch = Pinch.hard
            let start = CGPoint(x: pinch.start.x*size.width, y: pinch.start.y*size.height)
            controller.startSummarise(.pinch, at: start)
            guard let summarise = controller.summarise else { return result }
            var asked = false
            summarise.makeSummary = { asked = true; return summary }
            summarise.beginPinch(at: start)
            for step in 1...30 {
                try? await Task.sleep(for: .milliseconds(10))
                let p = CGFloat(step)/30
                summarise.updatePinch(scale: 1-p*(1-pinch.endScale), centroid: start)
            }
            summarise.endPinch(cancelled: false)
            try? await Task.sleep(for: .seconds(2))
            result.revealed = summarise.isRevealed
            result.finished = summarise.isRevealed && !asked
            return result
        }
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(400))
        controller.summariseFromMenu()
        guard let summarise = controller.summarise else { return result }
        var asked = false
        summarise.makeSummary = { asked = true; return summary }
        try? await Task.sleep(for: .seconds(2.5))
        result.revealed = summarise.isRevealed
        result.finished = summarise.isRevealed && !asked
        return result
    }

    /// In real time: summarises the stand-in page from More, then focuses the follow-up field and,
    /// 1.5 s later, lets the keyboard go, for a screen recording of the field rising with it.
    static func followUpKeyboard(in controller: BrowserViewController) async -> Result {
        var result = Result()
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        // Summarised before, so it shows without asking a model.
        let web = controller.webView
        controller.tabs[controller.tabIndex].remember(summary, of: web, url: web.url, item: web.backForwardList.currentItem)
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(400))
        controller.summariseFromMenu()
        guard let summarise = controller.summarise else { return result }
        try? await Task.sleep(for: .seconds(2.5))
        result.revealed = summarise.isRevealed
        summarise.focusFollowUpField()
        try? await Task.sleep(for: .seconds(1.5))
        controller.view.endEditing(true)
        try? await Task.sleep(for: .seconds(1))
        result.finished = true
        return result
    }

    /// In real time: shows the stand-in page's summary, sends two questions from the field with
    /// a stand-in answer, saving frames through each flight, and then scrolls as far as it goes.
    static func send(in controller: BrowserViewController, savingFramesTo folder: URL?) async -> Result {
        var result = Result()
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        let web = controller.webView
        controller.tabs[controller.tabIndex].remember(summary, of: web, url: web.url, item: web.backForwardList.currentItem)
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(400))
        controller.summariseFromMenu()
        guard let summarise = controller.summarise, let window = controller.view.window else { return result }
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        summarise.answerFollowUp = { _, _, _ in
            try await Task.sleep(for: .seconds(1.2))
            return ["zt parses each template at compile time with Zig's comptime, so a typo in a tag or a missing closing element is a build error rather than a broken page.",
                    "Values are escaped for the context they land in, attribute or text, unless a template asks for raw output by name."]
        }
        try? await Task.sleep(for: .seconds(2.5))
        result.revealed = summarise.isRevealed
        for round in 0..<2 {
            // The second asked from the top, the end of the first answer far below the field.
            if round == 1 { summarise.scrollSummaryToTop() }
            summarise.focusFollowUpField()
            try? await Task.sleep(for: .seconds(1))
            if let folder { await save(window, to: folder.appendingPathComponent("s\(round)-typing.png")) }
            summarise.sendFollowUp(round == 0 ? "How does it check templates?" : "And what about escaping inside attributes?")
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(150))
                if let folder { await save(window, to: folder.appendingPathComponent(String(format: "s%d-%.2f.png", round, Double(step)*0.15))) }
            }
            try? await Task.sleep(for: .seconds(1.5))
            if let folder { await save(window, to: folder.appendingPathComponent("s\(round)-answered.png")) }
        }
        summarise.scrollToSummaryEnd()
        try? await Task.sleep(for: .milliseconds(300))
        if let folder { await save(window, to: folder.appendingPathComponent("end.png")) }
        summarise.scrollToSummaryEnd(less: 520)
        try? await Task.sleep(for: .milliseconds(300))
        if let folder { await save(window, to: folder.appendingPathComponent("under-field.png")) }
        // A stand-in keyboard, as a headless Simulator shows none: scrolled to the end, the
        // summary should stay at its end as it comes up and goes, never jump back.
        summarise.scrollToSummaryEnd()
        try? await Task.sleep(for: .milliseconds(200))
        var lines = ["closed at end: \(summarise.followUpScroll)"]
        func keyboard(_ height: CGFloat) {
            let screen = window.screen.bounds
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: screen.maxY-height, width: screen.width, height: height)),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
                UIResponder.keyboardAnimationCurveUserInfoKey: UInt(7)])
        }
        keyboard(336)
        lines.append("just after opening: \(summarise.followUpScroll)")
        try? await Task.sleep(for: .milliseconds(400))
        lines.append("opened: \(summarise.followUpScroll)")
        keyboard(0)
        try? await Task.sleep(for: .milliseconds(400))
        lines.append("closed again: \(summarise.followUpScroll)")
        if let folder { try? lines.joined(separator: "\n").write(to: folder.appendingPathComponent("keyboard.txt"), atomically: true, encoding: .utf8) }
        summarise.focusFollowUpField()
        try? await Task.sleep(for: .seconds(1))
        let open = summarise.followUpScroll
        summarise.scrollToSummaryEnd()
        try? await Task.sleep(for: .milliseconds(300))
        if let folder { await save(window, to: folder.appendingPathComponent("end-keyboard.png")) }
        print("send replay: keyboard-open offset \(open.offset) of max \(open.max)")
        controller.view.endEditing(true)
        try? await Task.sleep(for: .seconds(1))
        result.finished = true
        return result
    }

    /// In real time: shows a long first summary, its first paragraph running on behind the
    /// follow-up field, and saves it under each of `fadeTrials` as `fade-<n>.png`.
    static func fades(in controller: BrowserViewController, savingFramesTo folder: URL?) async -> Result {
        var result = Result()
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        let web = controller.webView
        controller.tabs[controller.tabIndex].remember(longSummary, of: web, url: web.url, item: web.backForwardList.currentItem)
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(400))
        controller.summariseFromMenu()
        guard let summarise = controller.summarise, let window = controller.view.window else { return result }
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? await Task.sleep(for: .seconds(2.5))
        result.revealed = summarise.isRevealed
        for (i, shape) in fadeTrials.enumerated() {
            summarise.tryFade(shape)
            try? await Task.sleep(for: .milliseconds(150))
            if let folder { await save(window, to: folder.appendingPathComponent(String(format: "fade-%02d.png", i+1))) }
        }
        // Back to the default, then closed, for a screen recording of the fade going with it.
        summarise.tryFade(SummariseMotion.followUpFade)
        try? await Task.sleep(for: .milliseconds(500))
        summarise.close()
        try? await Task.sleep(for: .seconds(1.5))
        result.finished = true
        return result
    }

    /// A first summary long enough that its first paragraph runs on behind the field.
    static let longSummary = PageSummary(paragraphs: [
        "Lukáš Lalinský writes about building web apps in Zig, a low-level language, and introduces zt, a type-safe HTML templating library that checks templates at compile time and escapes HTML by default against XSS. He started web development around 2000, just after PHP 3.0, and has used raw PHP, string concatenation in Python, Smarty in PHP, Template Toolkit in Perl and Jinja and Django templates in Python, then single-page apps and JavaScript frameworks, before coming back to server-rendered pages. What he missed in Zig was a way to write HTML that the compiler understands, so that a mistyped tag, an unclosed element or a missing value fails the build instead of producing a broken page, and so that rendering costs no more than writing the strings out by hand.",
        "Templates use a familiar HTML-like syntax, must close their elements, and compile to plain Zig, so rendering a page is as fast as writing the strings by hand. Values are escaped for the context they land in, attribute or text, unless a template asks for raw output by name.",
    ])

    /// Fades to compare over the field, for `fades`.
    static let fadeTrials: [SummaryFade] = [
        SummaryFade(height: 60),
        SummaryFade(height: 90),
        SummaryFade(height: 120),
        SummaryFade(height: 60, curve: .smooth),
        SummaryFade(height: 90, curve: .smooth),
        SummaryFade(height: 120, curve: .smooth),
        SummaryFade(height: 160, curve: .smooth),
        SummaryFade(height: 60, hold: 16, curve: .smooth),
        SummaryFade(height: 90, hold: 24, curve: .smooth),
        SummaryFade(height: 120, hold: 32, curve: .smooth),
        SummaryFade(height: 90, curve: .quick),
        SummaryFade(height: 140, curve: .quick),
        SummaryFade(height: 100, hold: 20, curve: .quick),
        SummaryFade(height: 90, curve: .late),
        SummaryFade(height: 80, hold: 40),
    ]

    /// Summarise in More, from the open panel over the receded page: frames every 0.1 s to its card.
    static func runFromMenu(in controller: BrowserViewController, savingFramesTo folder: URL?) async -> Result {
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(800))
        var result = Result()
        guard let window = controller.view.window else { return result }
        if let folder { await save(window, to: folder.appendingPathComponent("m-open.png")) }
        controller.summariseFromMenu()
        guard let summarise = controller.summarise else { return result }
        summarise.makeSummary = { try await withCheckedThrowingContinuation { _ in } }
        summarise.manualTime = 0
        for step in 0...120 {
            let t = Double(step)/120
            summarise.advance(to: t)
            if step == 60 { result.barWhileLoading = controller.bottomBar.transform.ty }
            if let folder, step%12 == 0 { await save(window, to: folder.appendingPathComponent(String(format: "m-%.2f.png", t))) }
        }
        summarise.finish()
        result.finished = controller.summarise == nil
        return result
    }

    /// Swipes up the bar to the tabs in real time, a hard flick up and to the left from the right,
    /// a short swipe that springs back, and a tap on the card that grows it back, noting the moving
    /// page's frame every frame in `tabs.csv`.
    static func swipeToTabs(in controller: BrowserViewController, savingTo folder: URL?, slowDrag: Bool = false,
                            fastFlick: Bool = false) async -> Result {
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        let size = controller.view.bounds.size, start = CGPoint(x: size.width*0.75, y: size.height-40)
        let replayStart = CACurrentMediaTime()
        var rows = ["t,move,x,y,width,height,title,titleY,elapsed"]
        func sample(_ name: String, for seconds: Double, swipe: ((Double) -> Void)? = nil) async {
            let began = CACurrentMediaTime()
            while CACurrentMediaTime()-began < seconds {
                let t = CACurrentMediaTime()-began
                swipe?(t)
                // As shown: the page flies on Core Animation, its own frame already where it's going.
                if let card = controller.tabSwitcher.moving?.layer.presentation(), let cell = controller.tabSwitcher.cells.first,
                   let caption = cell.caption.layer.presentation(), let grid = controller.tabSwitcher.grid.layer.presentation() {
                    let titleY = caption.convert(caption.bounds, to: controller.tabSwitcher.layer.presentation()).midY
                    rows.append(String(format: "%.4f,%@,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f,%.4f", t, name, card.position.x, card.position.y,
                                       card.bounds.width, card.bounds.height, Double(caption.opacity*grid.opacity), titleY,
                                       CACurrentMediaTime()-replayStart))
                }
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
        if fastFlick {
            // A short, sharp flick: the final touch arrives just before release, before its pose
            // has necessarily reached the screen. This exposes a skipped first flight frame.
            for round in 0..<3 {
                controller.beginTabSwipe()
                await sample("fast-drag-\(round)", for: 0.05) { t in
                    controller.updateTabSwipe(CGPoint(x: -10*t/0.05, y: -60*t/0.05), from: start)
                }
                controller.updateTabSwipe(CGPoint(x: -15, y: -90), from: start)
                controller.endTabSwipe(velocity: CGPoint(x: -300, y: -2400))
                await sample("fast-flight-\(round)", for: 1.1)
                controller.selectTab(controller.tabIndex)
                await sample("fast-return-\(round)", for: 0.9)
            }
        }
        // Slow enough to outlast the bar's own animation, then reverse under the finger. No
        // recording display link: it would ask for 120 Hz itself and hide the drag's actual rate.
        if slowDrag {
            controller.beginTabSwipe()
            await sample("drag", for: 1.2) { t in
                controller.updateTabSwipe(CGPoint(x: -30*t/1.2, y: -280*t/1.2), from: start)
            }
            await sample("reverse", for: 0.7) { t in
                controller.updateTabSwipe(CGPoint(x: -30+25*t/0.7, y: -280+240*t/0.7), from: start)
            }
            controller.endTabSwipe(velocity: CGPoint(x: 36, y: 343))
            await sample("cancel", for: 0.8)
        }
        // A hard flick, 0.12 s up and to the left, let go still going.
        controller.beginTabSwipe()
        await sample("flick", for: 0.12) { t in
            controller.updateTabSwipe(CGPoint(x: -70*t/0.12, y: -380*t/0.12), from: start)
        }
        controller.endTabSwipe(velocity: CGPoint(x: -580, y: -3200))
        await sample("flick", for: 1.2)
        // A tap on its card grows it back.
        controller.selectTab(controller.tabIndex)
        await sample("grow", for: 1.0)
        // A short, slow swipe that springs back.
        controller.beginTabSwipe()
        await sample("short", for: 0.3) { t in
            controller.updateTabSwipe(CGPoint(x: 20*t/0.3, y: -70*t/0.3), from: start)
        }
        controller.endTabSwipe(velocity: CGPoint(x: 0, y: -60))
        await sample("short", for: 0.8)
        if slowDrag {
            // Catch a card growing back into the page, drag it again, and return all the way.
            controller.showTabSwitcher()
            await sample("press", for: 0.3)
            controller.selectTab(controller.tabIndex)
            await sample("return-before-catch", for: 0.1)
            controller.beginTabSwipe()
            await sample("caught-drag", for: 0.35) { t in
                controller.updateTabSwipe(CGPoint(x: 30*t/0.35, y: -110*t/0.35), from: start)
            }
            controller.endTabSwipe(velocity: CGPoint(x: 86, y: -314))
            await sample("caught-land", for: 1.1)
            controller.selectTab(controller.tabIndex)
            await sample("caught-return", for: 1.0)
        }
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? rows.joined(separator: "\n").write(to: folder.appendingPathComponent("tabs.csv"), atomically: true, encoding: .utf8)
        }
        return Result(finished: controller.tabSwitcher.isHidden)
    }

    /// Presses Tabs, then New Page 100 ms later, as quickly as a person might, on a real page,
    /// printing every frame's gap for a second and what each press cost, for the console.
    /// Presses Tabs and taps the card back a few times, with nothing else asking for frames, to see
    /// in an Animation Hitches trace the rate the flights run at on their own.
    static func pressTabs(in controller: BrowserViewController) async -> Result {
        controller.webView.load(URLRequest(url: URL(string: "https://news.ycombinator.com/")!))
        for _ in 0..<500 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(1500))
        for _ in 0..<3 {
            controller.bottomBar.tabsButton.sendActions(for: .primaryActionTriggered)
            try? await Task.sleep(for: .milliseconds(1500))
            controller.selectTab(controller.tabIndex)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        return Result()
    }

    /// Opens More over a page with a coloured top and leaves it open, to see the receded page's corners.
    static func openMore(in controller: BrowserViewController) async -> Result {
        controller.webView.load(URLRequest(url: URL(string: "https://news.ycombinator.com/")!))
        for _ in 0..<500 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        controller.openPanel(.menu)
        return Result()
    }

    /// Opens More over Hacker News, starts a download, answers its question after a moment, then
    /// opens Downloads, drawing the screen at each step into the folder.
    static func downloads(in controller: BrowserViewController, savingTo folder: URL?) async -> Result {
        let snap = { (name: String) in
            guard let folder, let scene = controller.view.window?.windowScene else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bounds = scene.screen.bounds
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
                for window in scene.windows.sorted(by: { $0.windowLevel < $1.windowLevel }) where !window.isHidden {
                    window.drawHierarchy(in: window.frame, afterScreenUpdates: true)
                }
            }
            try? image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        controller.webView.load(URLRequest(url: URL(string: "https://news.ycombinator.com/")!))
        for _ in 0..<500 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(900))
        snap("1-menu")
        controller.openSiteSettings()
        try? await Task.sleep(for: .milliseconds(900))
        snap("1b-site-settings")
        controller.closeSiteSettings()
        try? await Task.sleep(for: .milliseconds(700))
        let downloads = MobileDownloads.shared, ask = downloads.confirm
        downloads.confirm = { name, host, bytes, answer in
            ask?(name, host, bytes) { _ in }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                snap("2-confirm")
                controller.presentedViewController?.dismiss(animated: false)
                downloads.confirm = ask
                answer(true)
            }
        }
        controller.webView.load(URLRequest(url: URL(string: "https://proof.ovh.net/files/10Mb.dat")!))
        for _ in 0..<300 where downloads.items.first?.state != .downloading { try? await Task.sleep(for: .milliseconds(20)) }
        controller.openDownloads()
        try? await Task.sleep(for: .milliseconds(900))
        snap("3-downloads")
        for _ in 0..<1500 where downloads.items.first?.state == .downloading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(1500))
        snap("4-finished")
        controller.bottomBar.downloads.setSelecting(true)
        try? await Task.sleep(for: .milliseconds(700))
        snap("5-selecting")
        controller.bottomBar.downloads.toggleAll()
        try? await Task.sleep(for: .milliseconds(700))
        snap("6-selected")
        print("Rise iOS downloads: \(downloads.items.map { "\($0.name) \($0.state) \($0.totalBytes)" })")
        return Result()
    }

    static func tabsThenNewPage(in controller: BrowserViewController) async -> Result {
        controller.webView.load(URLRequest(url: URL(string: "https://www.apple.com/iphone/")!))
        for _ in 0..<500 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(1500))
        // Both, then New Page on its own, then Tabs on its own.
        for round in 0..<6 {
            let tabs = round < 2 || round >= 4, newPage = round < 4
            let recorder = FrameRecorder()
            recorder.start()
            try? await Task.sleep(for: .milliseconds(100))
            var began = CACurrentMediaTime()
            if tabs {
                controller.bottomBar.tabsButton.sendActions(for: .primaryActionTriggered)
                recorder.mark("tabs", cost: CACurrentMediaTime()-began)
            }
            try? await Task.sleep(for: .milliseconds(100))
            began = CACurrentMediaTime()
            if newPage {
                controller.bottomBar.newPageButton.sendActions(for: .primaryActionTriggered)
                recorder.mark("new page", cost: CACurrentMediaTime()-began)
            }
            try? await Task.sleep(for: .milliseconds(900))
            print("Rise iOS tabsNew \(round) \(tabs ? "tabs" : "")\(tabs && newPage ? "+" : "")\(newPage ? "new page" : ""): " + recorder.stop())
            controller.closePanel()
            try? await Task.sleep(for: .milliseconds(700))
            if controller.isTabSwitcherOpen { controller.selectTab(controller.tabIndex) }
            try? await Task.sleep(for: .milliseconds(900))
        }
        return Result()
    }

    /// Notes every frame's gap and when things happened between them.
    @MainActor final class FrameRecorder: NSObject {
        private var link: CADisplayLink?, t0 = CACurrentMediaTime(), last: CFTimeInterval?
        private var lines: [String] = []
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            t0 = CACurrentMediaTime()
        }
        func mark(_ name: String, cost: Double) {
            lines.append(String(format: "[%@ at %.3f s took %.1f ms]", name, CACurrentMediaTime()-t0-cost, cost*1000))
        }
        @objc private func frame(_ link: CADisplayLink) {
            if let last {
                let gap = (link.timestamp-last)*1000
                if gap > (link.targetTimestamp-link.timestamp)*1000*1.5 {
                    lines.append(String(format: "DROP %.0f ms at %.3f s", gap, link.timestamp-t0))
                }
            }
            last = link.timestamp
        }
        func stop() -> String {
            link?.invalidate()
            return lines.joined(separator: "  ")
        }
    }

    /// Reopens a settled, long summary on Apple's homepage three times. Only the scene's own
    /// logger asks for frames, and nothing retains the scene after it hands the live page back.
    static func timeClose(in controller: BrowserViewController) async -> Result {
        controller.webView.load(URLRequest(url: URL(string: "https://www.apple.com/")!))
        for _ in 0..<500 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(1500))
        let longSummary = PageSummary(paragraphs: summary.paragraphs+summary.paragraphs)
        var result = Result()
        for round in 0..<3 {
            // Install the fixture before committing starts its request.
            controller.startSummarise(.pinch)
            controller.summarise?.makeSummary = { longSummary }
            controller.summarise?.startFromMenu()
            controller.summarise?.log?.event("replay", "close \(round)")
            for _ in 0..<250 where controller.summarise?.isRevealed != true {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .seconds(2.5))
            result.revealed = controller.summarise?.isRevealed == true
            result.summaryHeight = controller.summarise?.summaryHeight ?? 0
            controller.summarise?.close()
            try? await Task.sleep(for: .milliseconds(1400))
            result.finished = controller.summarise == nil
        }
        return result
    }

    /// Pinches in real time on a real page, printing the gaps between frames, for the console.
    static func timeStart(in controller: BrowserViewController) async -> Result {
        controller.webView.load(URLRequest(url: URL(string: "https://www.apple.com/iphone/")!))
        for _ in 0..<500 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(1500))
        for round in 0..<3 {
            let driver = PinchDriver(controller: controller)
            await driver.run()
            print("Rise iOS timing \(round): " + driver.report)
            try? await Task.sleep(for: .milliseconds(600))
            controller.summarise?.finish()
            try? await Task.sleep(for: .milliseconds(600))
        }
        return Result()
    }

    /// Drives a 0.15 s pinch frame by frame, then taps the card closed once its summary shows,
    /// catches it with another pinch on its way back, and taps it closed again once the summary
    /// shows again, noting when each frame came.
    @MainActor final class PinchDriver: NSObject {
        let controller: BrowserViewController
        var stamps: [(t: Double, gap: Double)] = [], start: CFTimeInterval?, startCost = 0.0, last: CFTimeInterval?
        var revealed = false, revealedAgain = false, phase = 0
        var done: CheckedContinuation<Void, Never>?
        init(controller: BrowserViewController) { self.controller = controller }
        func run() async {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            await withCheckedContinuation { done = $0 }
            link.invalidate()
        }
        @objc func frame(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            if let last, let start { stamps.append((now-start, (link.timestamp-last)*1000)) }
            last = link.timestamp
            let point = CGPoint(x: 200, y: 500)
            guard let start else {
                start = now
                controller.startSummarise(.pinch, at: point)
                startCost = CACurrentMediaTime()-now
                controller.summarise?.makeSummary = { summary }
                return
            }
            let t = now-start, summarise = controller.summarise
            switch phase {
            case 0 where t < 0.15: summarise?.updatePinch(scale: 1-0.5*t/0.15, centroid: point)
            case 0: summarise?.endPinch(cancelled: false); phase = 1
            case 1 where t >= 3.0: revealed = summarise?.isRevealed == true; summarise?.close(); phase = 2
            case 2 where t >= 3.12: summarise?.grab(at: point); summarise?.updatePinch(scale: 1, centroid: point); phase = 3
            case 3 where t < 3.27: summarise?.updatePinch(scale: 1-0.45*(t-3.12)/0.15, centroid: point)
            case 3: summarise?.endPinch(cancelled: false); phase = 4
            case 4 where t >= 6.0: revealedAgain = summarise?.isRevealed == true; summarise?.close(); phase = 5
            case 5 where t >= 7.0 || summarise == nil: done?.resume(); done = nil; phase = 6
            default: break
            }
        }
        var report: String {
            func window(_ name: String, _ from: Double, _ to: Double) -> String {
                let gaps = stamps.filter { $0.t >= from && $0.t < to }.map(\.gap)
                let late = stamps.filter { $0.t >= from && $0.t < to && $0.gap > 9 }.map { String(format: "%.0f ms at %.2f s", $0.gap, $0.t) }
                return String(format: "%@ %d frames, late: ", name, gaps.count) + (late.isEmpty ? "none" : late.joined(separator: ", "))
            }
            return String(format: "start %.1f ms, revealed %@ and again %@; ", startCost*1000, "\(revealed)", "\(revealedAgain)")
                + [window("pinch", 0, 3.0), window("close", 3.0, 3.12), window("grab", 3.12, 6.0),
                   window("close again", 6.0, 7.0)].joined(separator: "; ")
        }
    }

    /// Drawing shows what the screen last showed, so it waits for the screen to show this step
    /// first. Summarise's clock is the replay's, so the pause doesn't move it on.
    /// Summarise in More on the real clock with the real model, saving the summary once it shows.
    static func runLive(in controller: BrowserViewController, savingFramesTo folder: URL?) async -> Result {
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        controller.openPanel(.menu)
        try? await Task.sleep(for: .milliseconds(600))
        var result = Result()
        controller.summariseFromMenu()
        guard let summarise = controller.summarise, let window = controller.view.window else { return result }
        let start = Date()
        while !summarise.isRevealed, Date().timeIntervalSince(start) < 60 { try? await Task.sleep(for: .milliseconds(100)) }
        result.revealed = summarise.isRevealed
        result.summaryHeight = summarise.summaryHeight
        if let folder {
            try? "\(Date().timeIntervalSince(start)) s".write(to: folder.appendingPathComponent("latency.txt"), atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .milliseconds(2000))
            await save(window, to: folder.appendingPathComponent("live.png"))
        }
        summarise.close()
        try? await Task.sleep(for: .milliseconds(1500))
        result.finished = controller.summarise == nil
        return result
    }

    private static func save(_ window: UIWindow, to file: URL) async {
        try? await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: file)
    }

    /// The page in the recording, much as the playground draws it.
    static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width">
    <title>Type-safe HTML templating in Zig | Lukáš Lalinský</title>
    <style>
    body { margin: 0; background: #f0f0f0; color: #111; }
    .menu { height: 28px; background: #000; color: #fff; font: 11px/28px -apple-system, sans-serif; letter-spacing: .02em; text-align: center; }
    .author { font: 600 15px/1 -apple-system, sans-serif; text-align: center; margin: 22px 0 0; }
    h2 { font: italic 700 35px/1.12 Georgia, "Times New Roman", serif; margin: 44px 18px 0; letter-spacing: -.01em; }
    .meta { font: 10px/1.45 -apple-system, sans-serif; margin: 18px 18px 0; color: #222; }
    p { font: 12.4px/1.5 -apple-system, sans-serif; margin: 12px 18px 0; color: #1a1a1a; }
    </style></head><body>
    <div class="menu">MENU</div><div class="author">Lukáš Lalinský</div>
    <h2>Type-safe HTML templating in Zig</h2><div class="meta">Lukáš Lalinský<br>2026-10-11</div>
    <p>I’ve done a lot of web development over the years. I started around the year 2000, just after PHP 3.0 was released and started taking over the web world. I’ve used all kinds of approaches for generating HTML: raw PHP, string concatenation in Python, Smarty templates in PHP, Template Toolkit in Perl, and Jinja/Django templates in Python. Then, as the world moved on to SPAs and JavaScript frameworks, I stopped working on frontends.</p>
    <p>Two years ago, I picked up Zig, and I’d never have imagined I’d be considering web development in such a low-level language. But as I was building my own ecosystem with zio and Dusty, I realized it’s not that far-fetched. I built these libraries for API backends, where the output is JSON or MessagePack, but then I saw that with proper use of arena allocators, even web development is actually manageable. And with Zig’s comptime, you can build very high-level interfaces without losing the performance. You can even build SPAs without touching JavaScript.</p>
    </body></html>
    """

    /// The playground's summary.
    static let summary = PageSummary(paragraphs: [
        "Lukáš Lalinský writes about building web apps in Zig, a low-level language, and introduces zt, a type-safe HTML templating library that checks templates at compile time and escapes HTML by default against XSS.",
        "Templates use a familiar HTML-like syntax, must close their elements, and compile to plain Zig, so rendering a page is as fast as writing the strings by hand.",
    ])
}
#endif
