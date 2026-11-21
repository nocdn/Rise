import AppKit

/// The minimal New Tab button (Settings ▸ Tabs, on by default): a plus level with the traffic
/// lights, centred over the downloads button, instead of the New Tab row above the tabs.
@MainActor extension BrowserController {
    static let minimalNewTabKey = "Rise.MinimalNewTab"
    static let hideSidebarScrollbarKey = "Rise.HideSidebarScrollbar"
    /// Off unless chosen in Settings: the sidebar scrolls with its thin bar.
    var hidesSidebarScrollbar: Bool { preferences.bool(forKey: Self.hideSidebarScrollbarKey) }
    func setHidesSidebarScrollbar(_ hides: Bool) {
        preferences.set(hides, forKey: Self.hideSidebarScrollbarKey)
        sidebar.hidesScrollbar = hides
    }
    var minimalNewTab: Bool { preferences.object(forKey: Self.minimalNewTabKey) as? Bool ?? true }
    func setMinimalNewTab(_ on: Bool) {
        preferences.set(on, forKey: Self.minimalNewTabKey)
        sidebar.minimalNewTab = on
        layoutChrome(); root.layoutSubtreeIfNeeded()
    }

    /// Puts the plus where it belongs, wherever the titlebar, the traffic lights and the sidebar
    /// have got to: it lives in the titlebar, which a click there reaches, not the sidebar under it.
    func placeTitlebarNewTab() {
        guard let sidebar, let close = window?.standardWindowButton(.closeButton) else { return }
        let plus = sidebar.titlebarNewTab
        if plus.superview !== toolbarHost { toolbarHost.addSubview(plus) }
        let x = sidebar.convert(NSPoint(x: sidebar.downloadsCentreX, y: 0), to: toolbarHost).x
        let y = close.convert(NSPoint(x: 0, y: close.bounds.midY), to: toolbarHost).y
        let frame = NSRect(x: (x-14).rounded(), y: (y-14).rounded(), width: 28, height: 28)
        if plus.frame != frame { plus.frame = frame }
    }
}

/// The titlebar's own area beside the traffic lights, which AppKit lays out and moves itself.
final class NativeTitlebarControls: NSView {
    var onMove: (() -> Void)?
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); onMove?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onMove?() }
}
