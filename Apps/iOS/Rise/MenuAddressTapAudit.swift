#if DEBUG
import UIKit

/// Opens More and, partway through its spring, hit-tests where the address is drawn, as a tap
/// there would; then taps it for real and checks the editor takes over without waiting.
@MainActor enum MenuAddressTapAudit {
    static let argument = "-RiseMenuAddressTapAudit"

    /// Where `view` is drawn in its window right now: its presentation layers, not its model.
    static func drawnFrame(of view: UIView) -> CGRect? {
        guard let window = view.window, let layer = view.layer.presentation(),
              let windowLayer = window.layer.presentation() ?? Optional(window.layer) else { return nil }
        return layer.convert(layer.bounds, to: windowLayer)
    }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("MenuAddressTapAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            browser.webView.loadHTMLString("<title>Tap</title><body>Address tap check</body>", baseURL: URL(string: "https://rise.test/page"))
            for _ in 0..<100 where browser.webView.isLoading { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(300))
            var results: [String: Any] = [:]
            let address = browser.bottomBar.menu.address
            var everyHit = true
            for delay in [16, 40, 70, 100, 150, 220] {
                browser.openPanel(.menu)
                try? await Task.sleep(for: .milliseconds(delay))
                var sample: [String: Any] = [:]
                if let window = browser.view.window, let drawn = drawnFrame(of: address) {
                    let centre = CGPoint(x: drawn.midX, y: drawn.midY)
                    let hit = window.hitTest(centre, with: nil)
                    sample["drawnMidY"] = drawn.midY
                    sample["modelMidY"] = address.convert(address.bounds, to: window).midY
                    let hitsAddress = hit.map { $0 === address || $0.isDescendant(of: address) } ?? false
                    sample["hitsAddress"] = hitsAddress
                    everyHit = everyHit && hitsAddress
                    sample["hit"] = hit.map { String(describing: type(of: $0)) } ?? "nil"
                } else { everyHit = false }
                results["open+\(delay)ms"] = sample
                browser.closePanel()
                try? await Task.sleep(for: .milliseconds(700))
            }
            results["drawnAddressTakesTapsThroughoutTheSpring"] = everyHit
            // A real tap early in the spring: the editor takes over straight away.
            browser.openPanel(.menu)
            try? await Task.sleep(for: .milliseconds(60))
            address.sendActions(for: .touchUpInside)
            results["earlyTapEditsAddress"] = browser.bottomBar.panel == .search && browser.bottomBar.search.editingAddress != nil
            try? await Task.sleep(for: .milliseconds(700))
            results["earlyTapSettlesEditing"] = browser.bottomBar.panel == .search && browser.bottomBar.search.field.isFirstResponder
            browser.closePanel()
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("results.json"))
            }
            try? "Done".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }
}
#endif
