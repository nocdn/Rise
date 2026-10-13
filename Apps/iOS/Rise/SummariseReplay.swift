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
        let folder = arguments.indices.contains(index+1) ? URL(fileURLWithPath: arguments[index+1]) : nil
        let kind = arguments.indices.contains(index+2) ? arguments[index+2] : ""
        Task {
            let result = switch kind {
            case "menu": await runFromMenu(in: controller, savingFramesTo: folder)
            case "live": await runLive(in: controller, savingFramesTo: folder)
            case "gentle": await run(in: controller, savingFramesTo: folder, pinch: .gentle)
            case "regrab": await run(in: controller, savingFramesTo: folder, regrab: true)
            case "timing": await timeStart(in: controller)
            case "tabs": await swipeToTabs(in: controller, savingTo: folder)
            case "tabsNew": await tabsThenNewPage(in: controller)
            case "more": await openMore(in: controller)
            case "tabsPress": await pressTabs(in: controller)
            default: await run(in: controller, savingFramesTo: folder)
            }
            let report = "revealed \(result.revealed), bar \(result.barWhileLoading), summary \(result.summaryHeight), finished \(result.finished), page moved \(result.pageMoved)"
            if let folder { try? report.write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8) }
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
    static func swipeToTabs(in controller: BrowserViewController, savingTo folder: URL?) async -> Result {
        controller.webView.loadHTMLString(page, baseURL: URL(string: "https://lalinsky.com/"))
        for _ in 0..<250 where controller.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(800))
        let size = controller.view.bounds.size, start = CGPoint(x: size.width*0.75, y: size.height-40)
        var rows = ["t,move,x,y,width,height,title,titleY"]
        func sample(_ name: String, for seconds: Double, swipe: ((Double) -> Void)? = nil) async {
            let began = CACurrentMediaTime()
            while CACurrentMediaTime()-began < seconds {
                let t = CACurrentMediaTime()-began
                swipe?(t)
                // As shown: the page flies on Core Animation, its own frame already where it's going.
                if let card = controller.tabSwitcher.moving?.layer.presentation(), let cell = controller.tabSwitcher.cells.first,
                   let caption = cell.caption.layer.presentation(), let grid = controller.tabSwitcher.grid.layer.presentation() {
                    let titleY = caption.convert(caption.bounds, to: controller.tabSwitcher.layer.presentation()).midY
                    rows.append(String(format: "%.4f,%@,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f", t, name, card.position.x, card.position.y,
                                       card.bounds.width, card.bounds.height, Double(caption.opacity*grid.opacity), titleY))
                }
                try? await Task.sleep(for: .milliseconds(4))
            }
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
    static let summary = PageSummary(
        overview: "The author, Lukáš Lalinský, discusses his journey in web development and the evolution of templating in Zig, a low-level programming language.",
        sections: [
            .init(symbol: "text.alignleft", heading: "Templating Library", text: "Lalinský introduces 'zt', a type-safe HTML templating library for Zig, designed to ensure compile-time checks, fast performance, and safe defaults against XSS."),
            .init(symbol: "star.fill", heading: "Key Features", text: "The library allows for HTML escaping by default, requires proper element closures, and integrates seamlessly with Zig code, providing a familiar HTML-like syntax."),
            .init(symbol: "bolt.fill", heading: "Performance", text: "Templates compile to plain Zig, so rendering a page is as fast as writing the strings by hand."),
        ])
}
#endif
