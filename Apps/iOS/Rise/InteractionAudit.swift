#if DEBUG
import UIKit
import WebKit

/// Runs the real controls and switcher against local pages, without changing the saved session.
@MainActor enum InteractionAudit {
    static let argument = "-RiseInteractionAudit"

    static func makeBrowser() -> BrowserViewController {
        let store = MobileBrowserSessionStore(fileURL: URL.temporaryDirectory
            .appendingPathComponent("RiseInteraction-\(UUID()).json"))
        let tabs = (1...4).map { MobileBrowserSession.Tab(url: nil, title: "Tab \($0)") }
        store.save(MobileBrowserSession(tabs: tabs, selectedTabID: tabs[2].id))
        store.flush()
        return BrowserViewController(startURL: nil, sessionStore: store)
    }

    struct Failure: Error { let check: String }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("InteractionAudit")
            var checks: [String: Any] = [:]
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                func check(_ name: String, _ valid: Bool) throws {
                    checks[name] = valid
                    if !valid { throw Failure(check: name) }
                }
                browser.webView.loadHTMLString("<html><head><title>Current tab</title></head><body>Local animation check</body></html>",
                                              baseURL: URL(string: "https://rise.test/"))
                for _ in 0..<100 where browser.webView.isLoading { try await Task.sleep(for: .milliseconds(20)) }
                browser.openPanel(.menu)
                try await Task.sleep(for: .milliseconds(650))
                // Test the real menu controls without triggering Share/Find navigation on release.
                let controls = MenuPanel(frame: browser.bottomBar.menu.frame)
                browser.bottomBar.addSubview(controls)
                controls.layoutIfNeeded()
                for (index, tile) in controls.tiles.enumerated() {
                    guard let icon = tile.subviews.compactMap({ $0 as? UIImageView }).first else { throw Failure(check: "icon") }
                    func same(_ a: UIColor?, _ b: UIColor) -> Bool {
                        guard let a else { return false }
                        func rgba(_ colour: UIColor) -> [CGFloat] {
                            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                            colour.resolvedColor(with: tile.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
                            return [r,g,b,a]
                        }
                        return zip(rgba(a),rgba(b)).allSatisfy { abs($0-$1) < 0.005 }
                    }
                    try check("neutral-\(index)", same(icon.tintColor, .label))
                    for end in [UIControl.Event.touchDragExit, .touchCancel, .touchUpOutside, .touchUpInside] {
                        tile.sendActions(for: .touchDown)
                        try check("pressed-\(index)-\(end.rawValue)", same(icon.tintColor, tile.pressedIconColor)
                                  && same(tile.backgroundColor, SearchPanel.pressedFill))
                        tile.sendActions(for: end)
                        try await Task.sleep(for: .milliseconds(300))
                        try check("released-\(index)-\(end.rawValue)", same(icon.tintColor, .label)
                                  && same(tile.backgroundColor, SearchPanel.fill))
                    }
                    tile.sendActions(for: .touchDragEnter)
                    try check("reentered-\(index)", same(icon.tintColor, tile.pressedIconColor))
                    tile.sendActions(for: .touchCancel)
                }
                controls.removeFromSuperview()
                browser.closePanel()
                try await Task.sleep(for: .milliseconds(400))
                let switcher = browser.tabSwitcher
                func stationary() -> Bool {
                    switcher.cells.enumerated().filter { $0.offset != switcher.current }.allSatisfy { _, cell in
                        cell.caption.alpha == 1 && cell.caption.transform == .identity
                            && !(cell.caption.layer.animationKeys() ?? []).contains { $0.hasPrefix("flight.") }
                            && abs((cell.caption.layer.presentation()?.opacity ?? 1)-1) < 0.001
                    }
                }
                browser.showTabSwitcher()
                try check("stationary-at-button-entry", stationary())
                guard let button = switcher.moving?.layer.animation(forKey: "flight.bounds") else { throw Failure(check: "button-flight") }
                let buttonDuration = button.duration
                try check("moving-title-animation", switcher.cells[2].caption.layer.animation(forKey: "flight.opacity") != nil)
                var samples: [[String: Any]] = []
                let began = CACurrentMediaTime()
                while CACurrentMediaTime()-began < 0.8 {
                    try check("stationary-through-button-flight", stationary())
                    samples.append(["time": CACurrentMediaTime()-began,
                                    "movingTitle": switcher.cells[2].caption.layer.presentation()?.opacity ?? 1,
                                    "stationaryTitle": switcher.cells[0].caption.layer.presentation()?.opacity ?? 1])
                    try await Task.sleep(for: .milliseconds(8))
                }
                try check("button-landed", switcher.moving == nil)
                let opacity = samples.compactMap { $0["movingTitle"] as? Float }
                try check("moving-title-still-reveals", (opacity.min() ?? 1) < 0.2 && (opacity.max() ?? 0) > 0.9)
                browser.selectTab(browser.tabIndex)
                try await Task.sleep(for: .milliseconds(50))
                browser.showTabSwitcher()
                try check("stationary-on-turnaround", stationary())
                try await Task.sleep(for: .milliseconds(850))
                browser.selectTab(browser.tabIndex)
                try await Task.sleep(for: .milliseconds(60))
                browser.beginTabSwipe()
                browser.updateTabSwipe(CGPoint(x: 0, y: -30))
                try check("stationary-on-catch", stationary())
                browser.endTabSwipe(velocity: CGPoint(x: 0, y: -700))
                try await Task.sleep(for: .milliseconds(850))
                browser.selectTab(browser.tabIndex)
                try await Task.sleep(for: .milliseconds(850))
                browser.beginTabSwipe()
                try check("stationary-at-drag-entry", stationary())
                switcher.finishSwipe(commit: true)
                guard let swipe = switcher.moving?.layer.animation(forKey: "flight.bounds") else { throw Failure(check: "swipe-flight") }
                checks["buttonDuration"] = buttonDuration
                checks["swipeDuration"] = swipe.duration
                try check("button-entry-quicker", buttonDuration < swipe.duration*0.92)
                try check("swipe-timing-preserved", abs(buttonDuration*TabSwitcherView.buttonEntrySpeed-swipe.duration) < 0.03)
                try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("frames.json"))
                try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
                try "Passed\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
