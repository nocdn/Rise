#if DEBUG
import UIKit

/// Replays only search-panel tracking and release, without a display link that could
/// accidentally raise the baseline refresh rate. Profilers can attach before `go` exists.
@MainActor enum PanelMotionAudit {
    static let argument = "-RisePanelMotionAudit"
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PanelMotionAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let field = browser.bottomBar.search.field
            for index in 0..<12 {
                browser.addressSuggestions.history.record(URL(string: "https://panel.example/page/\(index)")!, title: "Panel result \(index)")
            }
            browser.webView.loadHTMLString("<meta name='viewport' content='width=device-width'><h1>Panel motion</h1><p>Local profiling page</p>", baseURL: URL(string: "https://panel.example/"))
            browser.openPanel()
            try? await Task.sleep(for: .milliseconds(900))
            field.text = "panel.example"; field.sendActions(for: .editingChanged)
            try? "Ready".write(to: folder.appendingPathComponent("ready.txt"), atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.arguments.contains("-RiseWaitForProfiler") {
                while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("go").path) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            var rounds: [[String: Any]] = [], checks: [String: Bool] = [:]
            for round in 0..<3 {
                var samples: [[String: Double]] = []
                let start = CACurrentMediaTime()
                for step in 0...90 {
                    let began = CACurrentMediaTime()
                    browser.dragPanel(to: CGFloat(step)*2)
                    samples.append(["t": began-start, "workMS": (CACurrentMediaTime()-began)*1000,
                                    "top": browser.bottomBar.frame.minY])
                    try? await Task.sleep(for: .milliseconds(8))
                }
                let release = CACurrentMediaTime()
                var commitMS = -1.0
                var focusedAtCommit = false
                browser.onPanelCloseCommit = { commitMS = (CACurrentMediaTime()-release)*1000; focusedAtCommit = field.isFirstResponder }
                browser.finishPanelDrag(at: 180, velocity: 900)
                checks["close-\(round)-commits-before-keyboard-resignation"] = focusedAtCommit && commitMS >= 0 && !field.isFirstResponder
                rounds.append(["round": round, "drag": samples, "releaseWorkMS": (CACurrentMediaTime()-release)*1000,
                               "firstCommitMS": commitMS, "preferredFPS": browser.panelMotion.preferredFPS])
                try? await Task.sleep(for: .milliseconds(900))
                browser.openPanel()
                try? await Task.sleep(for: .milliseconds(800))
                field.text = "panel.example"; field.sendActions(for: .editingChanged)
            }
            browser.onPanelCloseCommit = nil
            browser.closePanel()
            try? await Task.sleep(for: .milliseconds(700))
            browser.openPanel(.menu)
            try? await Task.sleep(for: .milliseconds(400))
            browser.openDownloads()
            browser.bottomBar.downloads.reload((0..<16).map {
                MobileDownloads.Item(url: URL.temporaryDirectory.appendingPathComponent("Profile \($0).pdf"), state: .finished)
            })
            try? await Task.sleep(for: .milliseconds(450))
            var downloads: [[String: Any]] = []
            let travel = browser.downloadsHeights.expanded-browser.downloadsHeights.compact
            for direction: CGFloat in [-1, 1] {
                var samples: [Double] = []
                for step in 0...90 {
                    let began = CACurrentMediaTime()
                    browser.dragPanel(to: direction*travel*CGFloat(step)/90)
                    samples.append((CACurrentMediaTime()-began)*1000)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                browser.finishPanelDrag(at: direction*travel, velocity: direction*700)
                checks["downloads-\(direction)-keeps-its-rate-request-through-release"] = browser.panelMotion.isHoldingRate
                try? await Task.sleep(for: .milliseconds(450))
                checks["downloads-\(direction)-stops-its-rate-request-after-landing"] = !browser.panelMotion.isHoldingRate
                downloads.append(["direction": direction, "workMS": samples])
            }
            try? JSONSerialization.data(withJSONObject: rounds, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("timings.json"))
            try? JSONSerialization.data(withJSONObject: downloads, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("downloads.json"))
            try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            let failed = checks.filter { !$0.value }.keys.sorted()
            try? (failed.isEmpty ? "Passed" : failed.joined(separator: "\n"))
                .write(to: folder.appendingPathComponent(failed.isEmpty ? "done.txt" : "failure.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
