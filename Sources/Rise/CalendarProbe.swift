import AppKit

// TEMPORARY development probe: evaluates /tmp/rise-calendar-probe/in.js in an offscreen
// Google Calendar page and writes the answer to out.json. Removed before the feature ships.
@MainActor enum CalendarProbe {
    static var page: WebPage?
    static var timer: Timer?
    static func start(host: NSView) {
        let folder = URL(fileURLWithPath: "/tmp/rise-calendar-probe")
        guard page == nil, FileManager.default.fileExists(atPath: folder.path) else { return }
        let web = BrowserTab.makePage()
        let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 1200, height: 900))
        web.view.frame = container.bounds; container.addSubview(web.view)
        host.addSubview(container, positioned: .below, relativeTo: host.subviews.first)
        page = web
        web.load(URL(string: "https://calendar.google.com/calendar/u/0/r/day")!)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let input = folder.appendingPathComponent("in.js")
                if let url = try? String(contentsOf: folder.appendingPathComponent("load.txt"), encoding: .utf8), let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("load.txt"))
                    web.load(target)
                }
                guard let script = try? String(contentsOf: input, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: input)
                Task { @MainActor in
                    var output: Any
                    do { output = try await web.evaluate(script, arguments: [:], in: nil, world: .named("Rise.CalendarProbe")) ?? NSNull() }
                    catch { output = "error: \(error)" }
                    let wrapped: [String: Any] = ["url": web.url?.absoluteString ?? "", "loading": web.isLoading, "result": output]
                    let data = (try? JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .fragmentsAllowed])) ?? Data("\(wrapped)".utf8)
                    try? data.write(to: folder.appendingPathComponent("out.json"))
                }
            }
        }
    }
}
