import AppKit

@MainActor extension BrowserController {
    /// Hit-test through icons, labels, and the close button to the owning tab.
    /// Close only on release over the same tab; do not select it first.
    func handleMiddleTabClick(_ event: NSEvent) -> Bool {
        guard event.type == .otherMouseDown || event.type == .otherMouseUp, event.buttonNumber == 2 else { return false }
        let point = root.convert(event.locationInWindow, from: nil)
        let hit = root.hitTest(point)
        // Transparent button cells may return the document view for other-mouse
        // events. Require the document to be hit, then use the row's full bounds.
        // This also keeps overlays and the scrollbar from closing a covered tab.
        let insideTabs = hit === sidebar.rowsHost || hit?.isDescendant(of: sidebar.rowsHost) == true
        let id = insideTabs ? sidebar.tabID(at: sidebar.convert(point, from: root)) : nil
        if event.type == .otherMouseDown {
            pendingMiddleTabID = id
            return id != nil
        }
        guard let pressedID = pendingMiddleTabID else { return false }
        pendingMiddleTabID = nil
        if id == pressedID { closeTab(pressedID) }
        return true
    }
}
