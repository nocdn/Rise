import AppKit

/// A button that takes clicks only while `allowsInteraction` is set, as the page bar's are.
class SidebarHoverButton: ChromeButton {
    var allowsInteraction = false { didSet { if !allowsInteraction { hoverHint?.setHovered(false) } } }
    override var hoverRect: NSRect { allowsInteraction ? super.hoverRect : .zero }
    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsInteraction ? super.hitTest(point) : nil
    }
}
