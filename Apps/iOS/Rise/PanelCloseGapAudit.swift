#if DEBUG
import UIKit

/// Opens New Page and closes it, sampling every frame where the bar's bottom edge is drawn,
/// to catch the page showing through beneath it as it closes.
@MainActor enum PanelCloseGapAudit {
    static let argument = "-RisePanelCloseGapAudit"

    final class Sampler: NSObject {
        let browser: BrowserViewController
        var samples: [[String: Double]] = []
        var start = CACurrentMediaTime()
        init(_ browser: BrowserViewController) { self.browser = browser }
        @objc func tick(_ link: CADisplayLink) {
            let bar = browser.bottomBar.layer.presentation() ?? browser.bottomBar.layer
            let bottom = browser.view.bounds.maxY
            samples.append(["t": CACurrentMediaTime()-start, "barTop": bar.frame.minY, "barBottom": bar.frame.maxY,
                            "gap": bottom-bar.frame.maxY, "fill": browser.bottomBarUnderfillCoverage])
        }
    }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PanelCloseGapAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            browser.webView.loadHTMLString("<meta name='viewport' content='width=device-width'><style>body{background:#fc0084;min-height:200vh}</style><h1>Gap</h1>",
                                           baseURL: URL(string: "https://gap.invalid/"))
            try? await Task.sleep(for: .milliseconds(800))
            var results: [String: Any] = [:]
            for (name, close) in [("tap", { browser.closePanel() }),
                                  ("swipe", { browser.finishPanelDrag(at: 40, velocity: 900) })] as [(String, () -> Void)] {
                for panel in [BottomBar.Panel.search, .menu] {
                    browser.openPanel(panel)
                    try? await Task.sleep(for: .milliseconds(900))
                    let sampler = Sampler(browser)
                    let link = CADisplayLink(target: sampler, selector: #selector(Sampler.tick))
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
                    link.add(to: .main, forMode: .common)
                    sampler.start = CACurrentMediaTime()
                    close()
                    try? await Task.sleep(for: .milliseconds(700))
                    link.invalidate()
                    let worst = sampler.samples.max { ($0["gap"] ?? 0)-($0["fill"] ?? 0) < ($1["gap"] ?? 0)-($1["fill"] ?? 0) } ?? [:]
                    results["\(name)-\(panel)"] = ["worstUncovered": (worst["gap"] ?? 0)-(worst["fill"] ?? 0), "worst": worst,
                                                   "samples": sampler.samples]
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("results.json"))
            }
            try? "Done".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
