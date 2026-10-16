#if DEBUG
import UIKit

/// Exercises the actual list, native range callbacks, rendered selection transitions,
/// reuse, bulk deletion and saved history using an isolated suggestions directory.
@MainActor enum HistorySelectionAudit {
    static let argument = "-RiseHistorySelectionAudit"
    struct Failure: Error { let name: String }
    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("HistorySelectionAudit")
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
            if !valid { throw Failure(name: name) }
        }
        func wait(_ ms: Int = 400) async throws { try await Task.sleep(for: .milliseconds(ms)) }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let panel = browser.bottomBar.history, list = panel.list, source = browser.addressSuggestions
        let urls = (0..<48).map { URL(string: "https://history.invalid/article/\($0)")! }
        let titles = ["Designing a browser for everyday use", "A closer look at the new iPhone", "The quiet craft of making software",
                      "Notes from a weekend in London", "A guide to better typography", "Building interfaces that feel natural"]
        for (index, url) in urls.enumerated() {
            source.history.record(url, title: titles[index % titles.count], at: Date(timeIntervalSince1970: 2_000_000_000-Double(index)))
        }
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 16, height: 16)).fill()
        }
        for url in urls { source.icons.remember(icon, for: url) }
        browser.overrideUserInterfaceStyle = .light
        browser.openHistory()
        try await wait(550)
        func cell(_ index: Int) -> HistoryCell { list.cellForItem(at: IndexPath(item: index, section: 0)) as! HistoryCell }
        func select(_ index: Int) {
            let path = IndexPath(item: index, section: 0)
            list.selectItem(at: path, animated: false, scrollPosition: [])
            list.collectionView(list, didSelectItemAt: path)
        }
        func deselect(_ index: Int) {
            let path = IndexPath(item: index, section: 0)
            list.deselectItem(at: path, animated: false)
            list.collectionView(list, didDeselectItemAt: path)
        }
        try check("history-reuses-downloads-header-dots", panel.listMenuButton.currentImage?.pngData() == browser.bottomBar.downloads.listMenuButton.currentImage?.pngData()
                  && panel.listMenuButton.showsMenuAsPrimaryAction && panel.listMenuButton.tintColor == .secondaryLabel
                  && panel.listMenuButton.bounds.size == CGSize(width: AddressBar.buttonWidth, height: PanelHeader.height))
        try check("normal-menu-offers-multi-select", panel.selectionMenu().compactMap { ($0 as? UIAction)?.title } == ["Multi Select"])
        try check("history-has-native-range-selection", list.allowsMultipleSelectionDuringEditing && list.delegate === list
                  && list.collectionView(list, shouldBeginMultipleSelectionInteractionAt: IndexPath(item: 0, section: 0)))
        let first = cell(0), oldFrame = cell(0).row.frame
        let oldIconCentre = first.row.icon.convert(CGPoint(x: first.row.icon.bounds.midX, y: first.row.icon.bounds.midY), to: first.swipeContent)
        var opened = 0
        panel.open = { _ in opened += 1 }
        try capture("history-normal")
        panel.setSelecting(true)
        CATransaction.flush()
        try await wait(80)
        let moving = first.row.layer.presentation()?.position.x ?? first.row.center.x
        let opacity = first.checkbox.layer.presentation()?.opacity ?? 0
        try check("entering-selection-animates-the-rows-and-check-circles", moving > oldFrame.midX && moving < first.row.center.x
                  && opacity > 0 && opacity < 1)
        try await wait()
        try check("selection-keeps-icons-and-shifts-titles-right", first.row.icon.alpha == 1 && first.row.alpha == 1
                  && first.row.frame.minX == oldFrame.minX+HistoryCell.selectionShift
                  && first.row.bounds.width == oldFrame.width-HistoryCell.selectionShift)
        try check("the-checkbox-occupies-the-original-favicon-column", abs(first.checkbox.center.x-oldIconCentre.x) <= 1
                  && first.checkbox.preferredSymbolConfiguration == UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        try check("selection-disables-swipe-deletion", !panel.swipe.isEnabled && !panel.swipe.pan.isEnabled && !panel.swipe.begin(first)
                  && first.row.accessibilityCustomActions == nil)
        first.row.sendActions(for: .primaryActionTriggered)
        try check("row-taps-select-instead-of-opening", panel.selected == [urls[0].absoluteString] && opened == 0
                  && list.indexPathsForSelectedItems == [IndexPath(item: 0, section: 0)] && first.row.accessibilityTraits.contains(.selected))
        try check("selected-check-circles-use-downloads-blue", first.checkbox.tintColor == SiteSettingsPanel.switchBlue
                  && first.row.accessibilityValue == "Selected")
        first.checkButton.sendActions(for: .primaryActionTriggered)
        try check("tapping-a-checkbox-deselects-its-own-row", panel.selected.isEmpty && !first.row.accessibilityTraits.contains(.selected) && opened == 0)
        select(1)
        panel.refreshIcons()
        try check("favicon-refresh-preserves-selection-and-shift", panel.selected == [urls[1].absoluteString]
                  && cell(1).row.accessibilityTraits.contains(.selected) && cell(1).row.frame.minX == first.row.frame.minX)
        try capture("history-selected")
        panel.setSelecting(false)
        CATransaction.flush()
        try await wait(80)
        let returning = first.row.layer.presentation()?.position.x ?? first.row.center.x
        try check("leaving-selection-animates-back-instead-of-jumping", returning > oldFrame.midX
                  && returning < oldFrame.midX+HistoryCell.selectionShift/2
                  && (first.checkbox.layer.presentation()?.opacity ?? 0) > 0)
        try await wait()
        try check("leaving-selection-restores-exact-row-layout-and-gestures", first.row.frame == oldFrame && first.checkbox.alpha == 0
                  && panel.selected.isEmpty && panel.swipe.isEnabled && first.row.accessibilityValue == nil
                  && list.indexPathsForSelectedItems?.isEmpty != false)
        for _ in 0..<5 { panel.setSelecting(true); panel.setSelecting(false) }
        try await wait()
        try check("rapid-selection-toggles-leave-no-ghost-circles", first.checkbox.alpha == 0 && first.checkbox.subviews.isEmpty
                  && first.row.frame == oldFrame && first.row.icon.alpha == 1)

        list.collectionView(list, didBeginMultipleSelectionInteractionAt: IndexPath(item: 0, section: 0))
        for index in 0...4 { select(index) }
        try check("two-finger-selection-enters-mode-and-selects-each-crossed-row", panel.isSelecting && list.isRangeSelecting
                  && panel.selected == Set(urls.prefix(5).map(\.absoluteString)) && opened == 0)
        deselect(4); deselect(3)
        try check("reversing-the-range-deselects-only-the-rows-leaving-it", panel.selected == Set(urls.prefix(3).map(\.absoluteString)))
        let newURL = URL(string: "https://history.invalid/new-arrival")!
        source.history.record(newURL, title: "A new visit", at: Date(timeIntervalSince1970: 2_000_000_001))
        panel.reload()
        try check("a-history-refresh-does-not-move-native-range-anchors", panel.entries.count == 48
                  && panel.entries[0].url == urls[0].absoluteString && panel.selected.count == 3)
        list.collectionViewDidEndMultipleSelectionInteraction(list)
        try check("range-completion-applies-refresh-and-preserves-selection-by-url", panel.entries.count == 49
                  && panel.entries[0].url == newURL.absoluteString && panel.selected == Set(urls.prefix(3).map(\.absoluteString))
                  && Set(list.indexPathsForSelectedItems?.map(\.item) ?? []) == [1,2,3])
        panel.toggleAll()
        try check("select-all-includes-offscreen-history", panel.selected.count == 49 && list.indexPathsForSelectedItems?.count == 49)
        panel.toggleAll()
        try check("deselect-all-clears-both-native-and-custom-checks", panel.selected.isEmpty && list.indexPathsForSelectedItems?.isEmpty != false)
        select(1)
        list.setContentOffset(CGPoint(x: 0, y: list.contentSize.height-list.bounds.height), animated: false)
        list.layoutIfNeeded()
        try check("offscreen-cells-are-reused-with-correct-unchecked-state", list.visibleCells.allSatisfy {
            guard let cell = $0 as? HistoryCell else { return false }
            return cell.isSelecting && cell.checkbox.alpha == 1 && !cell.row.accessibilityTraits.contains(.selected)
        })
        list.setContentOffset(.zero, animated: false); list.layoutIfNeeded()
        try check("scrolling-back-restores-the-selected-checkmark", cell(1).row.accessibilityTraits.contains(.selected)
                  && cell(1).checkbox.tintColor == SiteSettingsPanel.switchBlue && cell(1).row.frame.minX == oldFrame.minX+HistoryCell.selectionShift)
        select(3)
        panel.deleteSelected()
        try await wait(550)
        source.save()
        let saved = BrowsingHistory(storageURL: source.history.storageURL)
        try check("deleting-selected-removes-only-those-visits-and-persists", panel.entries.count == 47
                  && !saved.entries.contains { $0.url == urls[0].absoluteString || $0.url == urls[2].absoluteString }
                  && saved.entries.contains { $0.url == urls[1].absoluteString } && !panel.isSelecting)
        try check("bulk-deletion-leaves-no-stale-row-motion", list.visibleCells.allSatisfy {
            guard let cell = $0 as? HistoryCell else { return false }
            return cell.swipeContent.transform == .identity && cell.swipeContent.alpha == 1 && cell.row.frame == oldFrame
        })
        panel.setSelecting(true); panel.toggleAll(); panel.deleteSelected()
        try await wait(550)
        try check("deleting-every-selected-visit-reaches-the-empty-state", panel.entries.isEmpty && list.numberOfItems(inSection: 0) == 0
                  && list.backgroundView is UILabel && !panel.isSelecting && source.history.entries.isEmpty)
        try check("empty-history-disables-multi-select", (panel.selectionMenu().first as? UIAction)?.attributes.contains(.disabled) == true)
        for (index, url) in urls.enumerated() { source.history.record(url, title: titles[index % titles.count]) }
        panel.reload(); panel.setSelecting(true)
        browser.closeHistory()
        try await wait()
        browser.openHistory()
        try await wait()
        try check("reopening-history-starts-with-normal-rows", !panel.isSelecting && panel.selected.isEmpty && panel.swipe.isEnabled
                  && cell(0).row.frame == oldFrame && cell(0).checkbox.alpha == 0)
        cell(0).row.sendActions(for: .primaryActionTriggered)
        try check("normal-row-taps-still-open-visits", opened == 1)
        panel.setSelecting(true); select(0); select(1)
        try await wait()
        browser.overrideUserInterfaceStyle = .dark
        try await wait()
        try capture("history-selected-dark")
        try check("dark-mode-keeps-legible-native-check-circles", cell(0).checkbox.tintColor == SiteSettingsPanel.switchBlue
                  && cell(2).checkbox.tintColor == .tertiaryLabel && cell(0).row.titleLabelView.textColor == .label)
        panel.setSelecting(false)
        browser.overrideUserInterfaceStyle = .light
    }
}
#endif
