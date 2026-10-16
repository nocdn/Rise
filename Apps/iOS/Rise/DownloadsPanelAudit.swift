#if DEBUG
import UIKit

/// Isolated rows in the real sheet, native collection-selection callbacks and displayed
/// icon transitions. Leaves the panel open for real touch checks in Device Hub.
@MainActor enum DownloadsPanelAudit {
    static let argument = "-RiseDownloadsPanelAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("DownloadsPanelAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                let checks = try await exercise(browser,folder: folder)
                try "Passed \(checks.count) native checks\n".write(to: folder.appendingPathComponent("done.txt"),atomically: true,encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"),atomically: true,encoding: .utf8)
            }
        }
    }

    static func exercise(_ browser: BrowserViewController,folder: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func check(_ name: String,_ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks,options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        let bar = browser.bottomBar, panel = bar.downloads, list = panel.list
        let fixtures = (1...16).map { index in
            MobileDownloads.Item(url: URL.temporaryDirectory.appendingPathComponent("Report \(index).pdf"),state: .finished)
        }
        func row(_ index: Int) throws -> DownloadsPanel.Row {
            guard let value = list.cellForItem(at: IndexPath(item: index,section: 0))?.contentView.subviews
                .compactMap({ $0 as? DownloadsPanel.Row }).first else { throw Failure(name: "missing visible row \(index)") }
            return value
        }
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(400))
        browser.openDownloads()
        panel.reload(fixtures)
        try await Task.sleep(for: .milliseconds(450))
        list.layoutIfNeeded()
        let compact = browser.downloadsHeights.compact, expanded = browser.downloadsHeights.expanded
        try check("downloads-keeps-its-original-opening-height", abs(bar.bounds.height-compact) < 0.5 && browser.downloadsSheet.detent == .compact)
        try check("compact-panel-keeps-four-visible-rows-and-scrolls-the-rest", abs(list.bounds.height-4*DownloadsPanel.rowHeight) < 0.5
                  && list.numberOfItems(inSection: 0) == fixtures.count && panel.isScrollable)
        try check("native-two-finger-selection-is-enabled", list.allowsMultipleSelectionDuringEditing
                  && list.collectionView(list,shouldBeginMultipleSelectionInteractionAt: IndexPath(item: 0,section: 0)))
        var opened = 0
        panel.open = { _ in opened += 1 }
        let first = try row(0), badge = first.selectionViews.badge, checkbox = first.selectionViews.checkbox
        first.iconButton.sendActions(for: .primaryActionTriggered)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        try check("tapping-the-file-icon-selects-it-without-opening-the-file", panel.isSelecting && panel.selected == [fixtures[0].id]
                  && opened == 0 && list.indexPathsForSelectedItems == [IndexPath(item: 0,section: 0)])
        let entering = checkbox.layer.presentation()?.opacity ?? 0
        try check("the-existing-icon-to-checkbox-transition-stays-animated", entering > 0 && entering < 1
                  && badge.layer.presentation()?.opacity ?? 1 < 1 && first.accessibilityTraits.contains(.selected))
        try await Task.sleep(for: .milliseconds(400))
        try check("the-tapped-icon-lands-as-a-checked-checkbox", checkbox.alpha == 1 && badge.alpha == 0
                  && !first.moreButton.isUserInteractionEnabled && first.iconButton.accessibilityLabel == "Deselect Report 1.pdf")
        panel.update(fixtures[0])
        try check("progress-refresh-does-not-reset-the-selection", panel.selected == [fixtures[0].id]
                  && first.iconButton.accessibilityLabel == "Deselect Report 1.pdf")
        first.iconButton.sendActions(for: .primaryActionTriggered)
        try check("tapping-the-checkbox-deselects-only-that-row", panel.isSelecting && panel.selected.isEmpty && opened == 0)
        panel.setSelecting(false)
        try await Task.sleep(for: .milliseconds(80))
        try check("the-checkbox-to-icon-transition-stays-animated", (badge.layer.presentation()?.opacity ?? 0) > 0
                  && (badge.layer.presentation()?.opacity ?? 1) < 1)
        try await Task.sleep(for: .milliseconds(400))
        try check("leaving-selection-restores-the-same-icon-and-options", badge.alpha == 1 && checkbox.alpha == 0
                  && first.moreButton.isUserInteractionEnabled && checkbox.subviews.isEmpty)

        list.collectionView(list,didBeginMultipleSelectionInteractionAt: IndexPath(item: 0,section: 0))
        for index in 0...2 {
            let path = IndexPath(item: index,section: 0)
            list.selectItem(at: path,animated: false,scrollPosition: [])
            list.collectionView(list,didSelectItemAt: path)
        }
        try check("native-range-callbacks-select-every-crossed-item", panel.isSelecting && panel.selected == Set(fixtures.prefix(3).map(\.id)))
        list.deselectItem(at: IndexPath(item: 2,section: 0),animated: false)
        list.collectionView(list,didDeselectItemAt: IndexPath(item: 2,section: 0))
        try check("reversing-a-range-deselects-the-items-leaving-it", panel.selected == Set(fixtures.prefix(2).map(\.id)))
        let added = MobileDownloads.Item(url: URL.temporaryDirectory.appendingPathComponent("New arrival.pdf"),state: .downloading)
        panel.reload([added]+fixtures)
        try check("arrivals-do-not-move-the-native-gesture-anchors-mid-drag", panel.items.map(\.id) == fixtures.map(\.id)
                  && panel.selected == Set(fixtures.prefix(2).map(\.id)))
        list.collectionViewDidEndMultipleSelectionInteraction(list)
        panel.layoutIfNeeded(); list.layoutIfNeeded()
        try check("deferred-arrivals-preserve-selection-by-file-identity", panel.items.first === added
                  && panel.selected == Set(fixtures.prefix(2).map(\.id))
                  && Set(list.indexPathsForSelectedItems?.map(\.item) ?? []) == [1,2])
        list.collectionView(list,didBeginMultipleSelectionInteractionAt: IndexPath(item: 1,section: 0))
        panel.reload(fixtures)
        panel.reload([added]+fixtures)
        list.collectionViewDidEndMultipleSelectionInteraction(list)
        try check("a-reversed-list-update-does-not-apply-a-stale-deferred-snapshot", panel.items.first === added
                  && panel.items.count == fixtures.count+1)
        panel.setSelecting(true)
        try check("entering-selection-again-never-clears-existing-checks", panel.selected == Set(fixtures.prefix(2).map(\.id)))
        panel.toggleAll()
        try check("select-all-includes-offscreen-files", panel.selected.count == fixtures.count+1)
        panel.toggleAll()
        try check("deselect-all-clears-native-and-custom-selection", panel.selected.isEmpty && list.indexPathsForSelectedItems?.isEmpty != false)
        panel.setSelecting(false)
        list.setContentOffset(CGPoint(x: 0,y: list.contentSize.height-list.bounds.height),animated: false)
        list.layoutIfNeeded()
        list.setContentOffset(.zero,animated: false); list.layoutIfNeeded()
        let reused = try row(1)
        try check("cell-reuse-keeps-the-original-row-and-its-icon", reused === first && reused.selectionViews.badge === badge
                  && reused.superview === list.cellForItem(at: IndexPath(item: 1,section: 0))?.contentView)
        try await Task.sleep(for: .milliseconds(400))
        reused.sendActions(for: .primaryActionTriggered)
        try check("ordinary-row-taps-still-open-files-outside-selection", opened == 1 && !panel.isSelecting)

        list.setContentOffset(.zero,animated: false)
        browser.dragPanel(to: -80)
        try check("dragging-up-follows-the-finger-between-the-two-heights", abs(bar.bounds.height-(compact+80)) < 1)
        browser.dragPanel(to: -10_000)
        try check("dragging-cannot-stretch-above-the-tall-detent", abs(bar.bounds.height-expanded) < 0.5)
        browser.finishPanelDrag(at: -10_000,velocity: -900)
        try await Task.sleep(for: .milliseconds(450))
        try check("an-upward-flick-settles-only-at-the-tall-detent", browser.downloadsSheet.detent == .expanded && abs(bar.bounds.height-expanded) < 0.5)
        try check("the-tall-detent-is-higher-than-new-page-and-exposes-more-rows", expanded > browser.view.bounds.height*BrowserViewController.panelHeightFraction+40
                  && list.bounds.height > 4*DownloadsPanel.rowHeight+80 && list.visibleCells.count > 4)
        list.setContentOffset(CGPoint(x: 0,y: list.contentSize.height-list.bounds.height),animated: false); list.layoutIfNeeded()
        try check("the-final-file-remains-fully-reachable-at-the-tall-detent", list.cellForItem(at: IndexPath(item: fixtures.count,section: 0)) != nil
                  && abs(list.contentSize.height-list.contentOffset.y-list.bounds.height) < 0.5)
        list.setContentOffset(.zero,animated: false)
        browser.dragPanel(to: 10_000)
        try check("dragging-down-stops-at-the-original-height-without-dismissing", abs(bar.bounds.height-compact) < 0.5
                  && browser.isPanelOpen && bar.panel == .downloads)
        browser.finishPanelDrag(at: 10_000,velocity: 900)
        try await Task.sleep(for: .milliseconds(450))
        try check("a-downward-flick-settles-at-the-small-detent", browser.downloadsSheet.detent == .compact && abs(bar.bounds.height-compact) < 0.5)
        browser.dragPanel(to: -15)
        browser.finishPanelDrag(at: -15,velocity: -900)
        try await Task.sleep(for: .milliseconds(80))
        let outgoingHeight = panel.bounds.height
        browser.closeDownloads()
        try check("returning-to-more-keeps-outgoing-rows-in-place-through-the-crossfade", abs(panel.bounds.height-outgoingHeight) < 0.5)
        try await Task.sleep(for: .milliseconds(450))
        try check("x-can-catch-a-height-animation-and-return-to-more", bar.panel == .menu && bar.shown === bar.menu
                  && abs(bar.bounds.height-BottomBar.menuHeight(width: bar.bounds.width,safeBottom: browser.view.window?.safeAreaInsets.bottom ?? 0)) < 0.5)
        browser.openDownloads()
        try await Task.sleep(for: .milliseconds(400))
        try check("reopening-downloads-always-resets-to-the-small-detent", browser.downloadsSheet.detent == .compact
                  && abs(bar.bounds.height-browser.downloadsHeights.compact) < 0.5 && !panel.isSelecting)
        browser.closeDownloads()
        try await Task.sleep(for: .milliseconds(350))
        try check("x-also-returns-to-more-from-the-small-detent", bar.panel == .menu && bar.shown === bar.menu)
        browser.openDownloads(); panel.reload(fixtures)
        try await Task.sleep(for: .milliseconds(400))
        panel.layoutIfNeeded(); list.layoutIfNeeded()
        return checks
    }
}
#endif
