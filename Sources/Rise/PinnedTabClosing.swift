import AppKit

@MainActor extension BrowserController {
    /// How long after ⌘W in a pinned tab a second ⌘W closes it, as long as the page bar says so.
    static let pinnedCloseWindow: TimeInterval = 2.5
    /// ⌘W in a pinned tab doesn't close it at once: the page bar says to press it again, and a
    /// second press while it says so closes the tab, its tile leaving the grid. Holding the keys
    /// down is one press. Whether this press was taken here rather than closing the tab.
    func asksBeforeClosingPinnedTab(_ id: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), tab.pinned, !splitGroups.contains(where: { $0.contains(id) }) else {
            pinnedCloseRequest = nil; return false
        }
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return true }
        if let request = pinnedCloseRequest, request.id == id, request.until > Date() {
            pinnedCloseRequest = nil; selectedBar.hideNotice()
            return false
        }
        pinnedCloseRequest = (id, Date().addingTimeInterval(Self.pinnedCloseWindow))
        siteInfoPopover.close(); siteControlsPopover.close(); permissionCoordinator.cancel(); hidePalette()
        selectedBar.showNotice("Press ⌘W again to unpin tab", image: BarNotice.unpinImage, hold: Self.pinnedCloseWindow)
        return true
    }
}
