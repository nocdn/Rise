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
                for (name, valid) in try await MenuDownloadsAudit.exercise(browser, folder: folder) { try check(name, valid) }
                // Test the real menu controls without triggering Share/Find navigation on release.
                let controls = MenuPanel(frame: browser.bottomBar.menu.frame)
                browser.bottomBar.addSubview(controls)
                controls.layoutIfNeeded()
                for (index, tile) in controls.tiles.enumerated() {
                    guard let icon = tile.subviews.compactMap({ $0 as? UIImageView }).first else { throw Failure(check: "icon") }
                    @MainActor func same(_ a: UIColor?, _ b: UIColor) -> Bool {
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
                // Measure action-to-render-server commit, rather than the duration of the spring.
                // The callback's bitmap work deliberately follows this boundary.
                var actionStart: CFTimeInterval = 0
                var actionName = ""
                var onset: [String: Double] = [:]
                switcher.onFlightCommit = {
                    if actionStart > 0 {
                        onset[actionName] = (CACurrentMediaTime()-actionStart)*1000
                        actionStart = 0
                    }
                }
                @MainActor func stationary() -> Bool {
                    switcher.cells.enumerated().filter { $0.offset != switcher.current }.allSatisfy { _, cell in
                        cell.caption.alpha == 1 && cell.caption.transform == .identity
                            && !(cell.caption.layer.animationKeys() ?? []).contains { $0.hasPrefix("flight.") }
                            && abs((cell.caption.layer.presentation()?.opacity ?? 1)-1) < 0.001
                    }
                }
                actionName = "first-button-entry"; actionStart = CACurrentMediaTime()
                browser.bottomBar.tabsButton.sendActions(for: .primaryActionTriggered)
                try check("stationary-at-button-entry", stationary())
                try check("button-entry-shows-the-whole-grid-immediately", switcher.grid.alpha == 1
                          && switcher.grid.transform == .identity && switcher.grid.layer.animation(forKey: "opacity") == nil
                          && switcher.grid.subviews.allSatisfy { !($0 is UIImageView) })
                guard let button = switcher.moving?.layer.animation(forKey: "flight.bounds") else { throw Failure(check: "button-flight") }
                let buttonDuration = button.duration
                guard let shadow = switcher.movingShadow,
                      let shadowFlight = shadow.layer.animation(forKey: "flight.shadowOpacity") as? CAKeyframeAnimation else {
                    throw Failure(check: "moving-shadow-flight")
                }
                let shadowValues = shadowFlight.values?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
                try check("moving-shadow-forms-during-flight", shadowValues.first == 0
                          && abs((shadowValues.last ?? 0)-0.10) < 0.001
                          && shadowValues.contains { $0 > 0.02 && $0 < 0.08 }
                          && shadowFlight.duration == buttonDuration)
                try check("moving-shadow-shape-and-position-follow-the-page", ["bounds", "position", "shadowPath"].allSatisfy {
                    shadow.layer.animation(forKey: "flight."+$0)?.duration == buttonDuration
                })
                try check("moving-title-animation", switcher.cells[2].caption.layer.animation(forKey: "flight.opacity") != nil)
                var samples: [[String: Any]] = []
                let began = CACurrentMediaTime()
                while CACurrentMediaTime()-began < 0.8 {
                    try check("stationary-through-button-flight", stationary())
                    try check("grid-stays-opaque-through-button-flight", abs((switcher.grid.layer.presentation()?.opacity ?? 1)-1) < 0.001)
                    samples.append(["time": CACurrentMediaTime()-began,
                                    "movingTitle": switcher.cells[2].caption.layer.presentation()?.opacity ?? 1,
                                    "stationaryTitle": switcher.cells[0].caption.layer.presentation()?.opacity ?? 1,
                                    "shadow": switcher.movingShadow?.layer.presentation()?.shadowOpacity ?? 0])
                    try await Task.sleep(for: .milliseconds(8))
                }
                try check("button-landed", switcher.moving == nil)
                try check("landing-hands-the-shadow-to-the-grid-without-a-remnant", switcher.movingShadow == nil
                          && switcher.cells[switcher.current].cardShadow.alpha == 1)
                try check("deck-corners-remain-generously-rounded", switcher.cells.allSatisfy { $0.card.layer.cornerRadius >= 19 })
                let opacity = samples.compactMap { $0["movingTitle"] as? Float }
                try check("moving-title-still-reveals", (opacity.min() ?? 1) < 0.2 && (opacity.max() ?? 0) > 0.9)
                let shadows = samples.compactMap { $0["shadow"] as? Float }
                try check("shadow-is-visible-before-the-page-lands", shadows.contains { $0 > 0.02 && $0 < 0.08 })
                actionName = "current-card-open"; actionStart = CACurrentMediaTime()
                switcher.cells[browser.tabIndex].onSelect()
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
                browser.endTabSwipe(velocity: CGPoint(x: 0, y: -700))
                guard let swipe = switcher.moving?.layer.animation(forKey: "flight.bounds") else { throw Failure(check: "swipe-flight") }
                checks["buttonDuration"] = buttonDuration
                checks["swipeDuration"] = swipe.duration
                try check("button-entry-matches-arcs-short-transition", (0.25...0.65).contains(buttonDuration))
                try check("swipe-release-remains-a-brief-continuous-spring", (0.25...0.85).contains(swipe.duration))
                try await Task.sleep(for: .milliseconds(850))
                switcher.focusTab(switcher.current)
                let hitCell = switcher.cells[switcher.current]
                let hitCard = hitCell.card.convert(CGPoint(x: hitCell.card.bounds.midX, y: hitCell.card.bounds.midY), to: switcher)
                let corner = hitCell.card.convert(CGPoint(x: hitCell.card.bounds.maxX-18, y: 18), to: switcher)
                try check("card-touches-reach-the-pressing-button", switcher.hitTest(hitCard, with: nil) === hitCell)
                try check("card-corner-touches-reach-the-card-with-no-close-button", switcher.hitTest(corner, with: nil) === hitCell)
                let cell = switcher.cells[0], selection = cell.onSelect
                let cellBounds = cell.bounds
                var selections = 0
                cell.onSelect = { selections += 1 }
                for end in [UIControl.Event.touchCancel, .touchDragExit, .touchUpOutside] {
                    cell.sendActions(for: .touchDown)
                    try await Task.sleep(for: .milliseconds(150))
                    try check("tab-press-scales-the-card-and-shadow", abs(cell.transform.a-TabCell.pressedScale) < 0.001
                              && cell.bounds == cellBounds && cell.cardShadow.superview === cell)
                    cell.sendActions(for: end)
                    try await Task.sleep(for: .milliseconds(350))
                    try check("cancelled-tab-press-returns-without-opening", cell.transform == .identity && selections == 0)
                }
                try check("tab-press-does-not-delay-or-prevent-grid-scrolling", !switcher.scroll.delaysContentTouches
                          && switcher.scroll.touchesShouldCancel(in: cell))
                // Cards have no Close button; VoiceOver closes them with an action.
                let accessibleSelection = hitCell.onSelect
                hitCell.onSelect = { selections += 1 }
                let activated = hitCell.card.accessibilityActivate()
                try check("voiceover-reaches-the-tab-as-one-target", !hitCell.isAccessibilityElement
                          && hitCell.card.isAccessibilityElement && hitCell.accessibilityElements?.count == 1
                          && activated && selections == 1)
                try check("tabs-expose-an-accessible-close-action", cell.card.accessibilityCustomActions?.contains { $0.name == "Close Tab" } == true)
                hitCell.onSelect = accessibleSelection
                cell.onSelect = selection
                cell.sendActions(for: .touchDown)
                try await Task.sleep(for: .milliseconds(150))
                let pressedFrame = cell.shownCardFrame(in: switcher)
                actionName = "different-card-open"; actionStart = CACurrentMediaTime()
                cell.sendActions(for: .primaryActionTriggered)
                let firstBounds = (switcher.moving?.layer.animation(forKey: "flight.bounds") as? CAKeyframeAnimation)?
                    .values?.first as? NSValue
                let firstPosition = (switcher.moving?.layer.animation(forKey: "flight.position") as? CAKeyframeAnimation)?
                    .values?.first as? NSValue
                try check("opening-flight-starts-at-the-visible-pressed-size", abs((firstBounds?.cgRectValue.width ?? 0)-pressedFrame.width) < 0.5
                          && abs((firstBounds?.cgRectValue.height ?? 0)-pressedFrame.height) < 0.5
                          && abs((firstPosition?.cgPointValue.x ?? 0)-pressedFrame.midX) < 0.5
                          && abs((firstPosition?.cgPointValue.y ?? 0)-pressedFrame.midY) < 0.5)
                cell.sendActions(for: .touchUpInside)
                try await Task.sleep(for: .milliseconds(850))
                checks["onsetMilliseconds"] = onset
                try check("different-tab-opens-and-finishes", browser.tabIndex == 0 && switcher.isHidden)
                actionName = "repeat-button-entry"; actionStart = CACurrentMediaTime()
                browser.bottomBar.tabsButton.sendActions(for: .primaryActionTriggered)
                try await Task.sleep(for: .milliseconds(850))
                actionStart = 0
                checks["onsetMilliseconds"] = onset
                switcher.onFlightCommit = {}
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
