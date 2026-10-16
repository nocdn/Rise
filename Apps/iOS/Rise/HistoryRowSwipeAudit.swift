#if DEBUG
import UIKit

/// Drives actual cells, saved records, springs and table updates using disposable history.
@MainActor enum HistoryRowSwipeAudit {
    static let argument = "-RiseHistoryRowSwipeAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("HistoryRowSwipeAudit")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(browser, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    private static func exercise(_ browser: BrowserViewController, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid {
                let panel = browser.bottomBar.history
                try JSONSerialization.data(withJSONObject: ["active": panel.swipe.isActive,
                    "panelURLs": panel.entries.map(\.url), "savedURLs": browser.addressSuggestions.history.entries.map(\.url),
                    "rows": panel.list.numberOfItems(inSection: 0), "empty": panel.list.backgroundView is UILabel],
                    options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("state.json"))
                throw Failure(name: name)
            }
        }
        func wait(_ milliseconds: Int = 650) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
        func settleSwipe() async throws {
            for _ in 0..<24 {
                if !browser.bottomBar.history.swipe.isActive { return }
                try await wait(50)
            }
        }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let panel = browser.bottomBar.history, list = panel.list, swipe = panel.swipe, source = browser.addressSuggestions
        for index in 0..<24 {
            source.history.record(URL(string: "https://history.invalid/page/\(index)")!, title: "History item \(index)",
                                  at: Date(timeIntervalSince1970: 2_000_000_000-Double(index)))
        }
        browser.openHistory()
        try await wait()
        func cell(_ index: Int) -> HistoryCell { list.cellForItem(at: IndexPath(item: index, section: 0)) as! HistoryCell }
        func x(_ index: Int) -> CGFloat { cell(index).swipeContent.transform.tx }
        func visibleX(_ index: Int) -> CGFloat { cell(index).row.icon.convert(cell(index).row.icon.bounds, to: panel).minX }
        let restingX = (0...6).map(visibleX)
        let row = cell(3), key = panel.entries[3].url, count = panel.entries.count, boundary = swipe.threshold
        try check("begins-on-a-visible-history-item", swipe.begin(row))
        swipe.move(to: boundary*0.7)
        try await wait(180)
        let resistedOffset = x(3)
        try check("the-selected-row-has-light-resistance-before-the-threshold", resistedOffset > boundary*0.7*0.5
                  && resistedOffset < boundary*0.7*0.9)
        try check("the-immediate-neighbours-follow-on-both-sides", x(2) > 3 && abs(x(2)-x(4)) < 0.01)
        try check("the-second-neighbours-follow-less", x(1) > 1 && x(1) < x(2)*0.6 && abs(x(1)-x(5)) < 0.01)
        try check("unrelated-rows-stay-still", x(0) == 0 && x(6) == 0)
        let firstAlpha = row.swipeContent.alpha
        try check("opacity-decreases-with-swipe-distance", firstAlpha < 1 && firstAlpha > 0.6)
        try capture("following")
        for case let item as HistoryCell in list.visibleCells { item.setNeedsLayout() }
        list.setNeedsLayout(); list.layoutIfNeeded()
        try capture("following-after-layout")
        try check("held-row-visibly-moves-after-table-layout", abs(visibleX(3)-restingX[3]-resistedOffset) < 0.5)
        try check("held-neighbours-visibly-move-after-table-layout", visibleX(2)-restingX[2] > 3
                  && visibleX(1)-restingX[1] > 1 && visibleX(4)-restingX[4] > 3 && visibleX(5)-restingX[5] > 1)
        swipe.move(to: boundary+8)
        try check("crossing-the-threshold-arms-removal", swipe.isArmed)
        try check("detachment-does-not-jump-the-row-in-one-frame", abs(x(3)-resistedOffset) < 0.01)
        try await wait(50)
        let catching = x(3)
        try check("detachment-swiftly-catches-up-to-the-finger", catching > resistedOffset+3 && catching < boundary+8)
        swipe.move(to: boundary+28)
        try check("finger-movement-stays-immediate-during-the-catch-up-spring", abs(x(3)-catching-20) < 0.01)
        swipe.move(to: boundary+8)
        try await wait(230)
        try check("the-neighbours-spring-home-while-the-finger-holds-the-row", abs(x(2)) < 0.5 && abs(x(1)) < 0.5
                  && abs(x(3)-(boundary+8)) < 0.5 && row.swipeContent.alpha < firstAlpha)
        try check("crossing-the-threshold-does-not-delete-before-release", panel.entries.count == count && source.history.entries.count == count)
        try capture("armed")
        let beforeRecapture = x(3)
        swipe.move(to: boundary-12)
        try check("reversing-through-the-threshold-disarms", !swipe.isArmed)
        try check("recapture-also-preserves-the-displayed-position", abs(x(3)-beforeRecapture) < 0.01)
        try await wait(230)
        try check("reversing-reconnects-both-pairs-of-neighbours", x(2) > 3 && x(1) > 1 && x(2) > x(1))
        try check("recapture-restores-the-rows-resistance", x(3) > (boundary-12)*0.5 && x(3) < (boundary-12)*0.9)
        try capture("reconnected")
        swipe.end(velocity: -120)
        try await wait()
        try check("letting-go-after-reversing-restores-every-row", !swipe.isActive && (0...6).allSatisfy { abs(x($0)) < 0.01 }
                  && row.swipeContent.alpha == 1 && panel.entries.count == count)
        _ = swipe.begin(row)
        swipe.move(to: -boundary-12)
        try await wait(180)
        try check("leftward-swipes-arm-and-release-neighbours-too", swipe.isArmed && x(3) < 0 && abs(x(2)) < 0.5)
        swipe.end(velocity: -1400, cancelled: true)
        try await wait()
        try check("system-cancellation-never-removes-an-armed-row", !swipe.isActive && panel.entries.count == count && source.history.entries.count == count)
        let before = cell(4).frame.minY
        _ = swipe.begin(row)
        swipe.move(to: -boundary-12)
        let releaseX = x(3)
        swipe.end(velocity: -1100)
        try check("release-keeps-position-and-removes-the-record-immediately", x(3) == releaseX && !source.history.entries.contains { $0.url == key })
        try await wait(60)
        try check("the-flight-continues-in-the-fingers-direction", row.swipeContent.transform.tx < releaseX)
        try await wait(700)
        try check("the-deleted-row-closes-its-gap-and-finishes", !swipe.isActive && panel.entries.count == count-1
                  && list.numberOfItems(inSection: 0) == count-1 && cell(3).frame.minY == before-SearchPanel.rowHeight)
        try check("rows-do-not-retain-offsets-or-faded-opacity-after-deletion", list.visibleCells.compactMap { $0 as? HistoryCell }.allSatisfy {
            $0.swipeContent.transform == .identity && $0.swipeContent.alpha == 1
        })
        source.save()
        try check("deleted-history-stays-deleted-after-relaunch", !BrowsingHistory(storageURL: source.history.storageURL).entries.contains { $0.url == key })
        try check("deletion-retains-every-other-history-entry", source.history.entries.count == count-1)
        try capture("removed")
        let flicked = panel.entries[2].url
        _ = swipe.begin(cell(2)); swipe.move(to: boundary*0.45); swipe.end(velocity: 1700)
        try await wait()
        try check("a-fast-short-flick-can-complete-the-swipe", !swipe.isActive && !panel.entries.contains { $0.url == flicked })
        _ = swipe.begin(cell(2)); swipe.move(to: boundary*1.1); swipe.end(velocity: -900)
        try await wait()
        try check("a-strong-reversal-cancels-even-before-returning-under-the-threshold", !swipe.isActive && panel.entries.count == count-2)
        _ = swipe.begin(cell(2)); swipe.move(to: -boundary*0.6)
        browser.closeHistory()
        try await wait()
        try check("closing-history-cancels-an-uncommitted-row-swipe", !swipe.isActive && source.history.entries.count == count-2)
        browser.openHistory()
        try await wait()
        try check("reopening-history-has-no-stale-row-transforms", list.visibleCells.compactMap { $0 as? HistoryCell }.allSatisfy { $0.swipeContent.transform == .identity && $0.swipeContent.alpha == 1 })
        let accessible = panel.entries[0].url
        try check("every-item-offers-an-accessible-delete-action", cell(0).row.accessibilityCustomActions?.map(\.name) == ["Delete from history"])
        _ = swipe.delete(cell(0))
        try await settleSwipe()
        try check("accessible-deletion-removes-the-same-record", !swipe.isActive && !panel.entries.contains { $0.url == accessible })
        try source.history.clear()
        source.history.record(URL(string: "https://history.invalid/last")!, title: "Last visit")
        panel.reload(); list.layoutIfNeeded()
        _ = swipe.delete(cell(0))
        try await settleSwipe()
        try check("deleting-the-last-visit-shows-the-empty-state", panel.entries.isEmpty && source.history.entries.isEmpty
                  && list.numberOfItems(inSection: 0) == 0 && list.backgroundView is UILabel && !swipe.isActive)
        source.save()
        try check("the-empty-history-is-persisted", BrowsingHistory(storageURL: source.history.storageURL).entries.isEmpty)
        // Leave disposable populated rows available for a real gesture check.
        for index in 0..<24 {
            source.history.record(URL(string: "https://history.invalid/preview/\(index)")!, title: "History preview \(index)",
                                  at: Date(timeIntervalSince1970: 2_000_000_000-Double(index)))
        }
        panel.reload()
    }
}
#endif
