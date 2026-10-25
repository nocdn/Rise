#if DEBUG
import UIKit

/// Checks the displayed Core Animation flight, overlapping arrivals and touch feedback.
@MainActor enum DownloadFlightAudit {
    static let argument = "-RiseDownloadFlightAudit"
    struct Failure: Error { let name: String }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("DownloadFlightAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let checks = try await exercise(browser, folder: folder)
                try "Passed \(checks.count) native checks\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    static func exercise(_ browser: BrowserViewController, folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        guard let window = browser.view.window else { throw Failure(name: "no window") }
        func flights() -> [MobileDownloadFlight] { window.subviews.compactMap { $0 as? MobileDownloadFlight } }
        func item(_ name: String) -> MobileDownloads.Item {
            let item = MobileDownloads.Item(url: URL.temporaryDirectory.appendingPathComponent(name), state: .downloading)
            item.totalBytes = 8_000_000
            return item
        }
        browser.webView.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:17px -apple-system;padding:28px;background:#f9fafb;color:#222}a{display:block;margin-top:160px;padding:22px;background:#e6edff;border-radius:16px;color:#145adb;text-align:center;text-decoration:none}</style>
        <h2>Download flight</h2><p>A small file for the native confirmation and touch-origin check.</p>
        <a download="Rise-flight-preview.txt" href="data:text/plain,Download%20flight%20preview">Download sample file</a>
        """, baseURL: nil)
        for _ in 0..<100 where browser.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(450))
        let observer = browser.webView.gestureRecognizers?.compactMap { $0 as? DownloadOriginTracker.Observer }.first
        try check("page-touch-observer-does-not-delay-or-cancel-webkit", observer != nil && observer?.cancelsTouchesInView == false
                  && observer?.delaysTouchesBegan == false && observer?.delaysTouchesEnded == false)
        try check("installing-the-observer-twice-is-idempotent", {
            browser.downloadOrigins.install(on: browser.webView)
            return browser.webView.gestureRecognizers?.filter { $0 is DownloadOriginTracker.Observer }.count == 1
        }())
        let origin = CGPoint(x: 126, y: 310)
        browser.launchDownloadFlight(item("Quarterly report.pdf"), from: origin)
        guard let flight = flights().first else { throw Failure(name: "flight did not launch") }
        let path = flight.path, button = browser.bottomBar.moreButton, landing = browser.bottomBar.moreLanding
        try check("download-start-waits-for-impact-before-its-single-pulse", flight.impactFeedbackCount == 0)
        let position = flight.card.layer.animation(forKey: "download.position") as? CAKeyframeAnimation
        try check("flight-starts-at-the-original-window-touch", (position?.values?.first as? NSValue)?.cgPointValue == origin)
        try check("flight-uses-a-solid-download-row", flight.card.backgroundColor == MobileDownloadFlight.fill
                  && flight.card.bounds.height == DownloadsPanel.rowHeight && flight.card.layer.cornerRadius == MenuPanel.cornerRadius)
        try check("flight-never-intercepts-touches", !flight.isUserInteractionEnabled && flight.accessibilityElementsHidden)
        let target = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        try check("flight-lands-in-the-three-dot-button", path.destination == target)
        let half = path.pose(at: path.duration*0.5).position
        let straightX = origin.x+(target.x-origin.x)*(half.y-origin.y)/(target.y-origin.y)
        try check("the-flight-takes-a-visible-but-shallow-arc", abs(half.x-straightX) > 5 && abs(half.x-straightX) < 100)
        try check("row-pops-up-before-the-late-collapse", path.pose(at: 0.13).scale > path.pose(at: 0).scale*2
                  && path.pose(at: path.duration*0.7).scale > 0.8 && path.pose(at: path.duration*0.98).scale < 0.3)
        try check("row-disappears-only-as-it-enters-the-button", path.pose(at: path.duration*0.9).opacity == 1
                  && path.pose(at: path.duration).opacity < 0.001)
        try check("flight-and-impact-request-120-hz", position?.preferredFrameRateRange.preferred == 120
                  && landing.layer.animationKeys()?.contains(where: { $0.hasPrefix("download-impact-") }) == true)
        let start = CACurrentMediaTime()
        var samples: [[String: Double]] = []
        for elapsed in [0.08,0.16,0.24,0.32,path.duration+0.07] {
            let delay = elapsed-(CACurrentMediaTime()-start)
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            guard let shown = flight.card.layer.presentation() else { throw Failure(name: "missing presentation layer") }
            samples.append(["time":CACurrentMediaTime()-start,"x":shown.position.x,"y":shown.position.y,
                            "scale":hypot(shown.transform.m11,shown.transform.m12),"opacity":Double(shown.opacity)])
            if elapsed == 0.32 {
                try check("the-single-start-pulse-does-not-play-during-the-flight", flight.impactFeedbackCount == 0)
            }
        }
        try check("the-start-pulse-coincides-with-the-button-impact", flight.impactFeedbackCount == 1
                  && abs((flight.impactFeedbackTime ?? 0)-(flight.startTime+path.duration)) < 0.05)
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("displayed-poses.json"))
        try check("render-server-shows-intermediate-positions", samples[1]["y"]! > origin.y && samples[1]["y"]! < target.y-20)
        let impact = landing.layer.presentation()?.transform ?? CATransform3DIdentity
        try check("button-moves-a-few-points-with-the-impact", hypot(impact.m41,impact.m42) > 1 && hypot(impact.m41,impact.m42) < 4)
        try await Task.sleep(for: .milliseconds(600))
        try check("flight-and-button-clean-up-at-rest", flights().isEmpty
                  && landing.layer.animationKeys()?.contains(where: { $0.hasPrefix("download-impact-") }) != true
                  && CATransform3DIsIdentity(landing.layer.transform))
        try check("the-start-pulse-never-repeats-while-the-button-settles", flight.impactFeedbackCount == 1)

        for x in [70.0,180.0,290.0] { browser.launchDownloadFlight(item("Download \(Int(x)).zip"), from: CGPoint(x: x, y: 370)) }
        try check("three-rapid-downloads-keep-three-independent-flights", flights().count == 3
                  && landing.layer.animationKeys()?.filter { $0.hasPrefix("download-impact-") }.count == 3)
        button.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(180))
        try check("normal-button-press-still-works-during-a-flight", abs(button.transform.a-BottomBar.pressedScale) < 0.01
                  && CATransform3DIsIdentity(landing.layer.transform))
        button.sendActions(for: .touchCancel)
        let interrupted = flights().first
        interrupted?.removeFromSuperview()
        try check("cancelling-one-overlay-keeps-the-other-impacts", flights().count == 2
                  && landing.layer.animationKeys()?.filter { $0.hasPrefix("download-impact-") }.count == 2)
        try await Task.sleep(for: .seconds(1))
        try check("concurrent-flights-all-release-their-overlays", flights().isEmpty && abs(button.transform.a-1) < 0.001)
        try check("an-interrupted-flight-cannot-play-a-late-start-pulse", interrupted?.impactFeedbackCount == 0)
        browser.setBottomBarCollapsed(true, animated: false)
        browser.launchDownloadFlight(item("From collapsed toolbar.pdf"), from: nil)
        try check("a-download-reveals-the-collapsed-toolbar", !browser.bottomBar.isCollapsed && flights().count == 1)
        if let fallback = flights().first {
            try check("missing-touch-uses-the-page-centre", fallback.path.origin == browser.webView.convert(
                CGPoint(x: browser.webView.bounds.midX,y: browser.webView.bounds.midY),to:window))
        }
        try await Task.sleep(for: .seconds(1.2))
        return checks
    }
}
#endif
