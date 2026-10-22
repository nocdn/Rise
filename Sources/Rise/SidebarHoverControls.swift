import AppKit

/// A button that takes clicks only while `allowsInteraction` is set, as the page bar's are.
class SidebarHoverButton: ChromeButton {
    var allowsInteraction = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsInteraction ? super.hitTest(point) : nil
    }
}
