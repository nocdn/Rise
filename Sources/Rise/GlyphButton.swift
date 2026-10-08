import AppKit

/// A button drawn with layers, with a rounded background while the pointer
/// is over it when `hoverColor` is set, as on the tab rows' buttons.
@MainActor class GlyphButton: NSView {
    var action: (() -> Void)?
    var hoverColor: NSColor? { didSet { refreshHover() } }
    var acceptsFirstClick = true
    private var hovering = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 6; layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        if hoverColor != nil {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        refreshHover()
    }
    /// Revealing or moving the button can leave its tracking state at the previous geometry.
    func refreshHover() {
        if let window, window.isVisible, !isHiddenOrHasHiddenAncestor, hoverColor != nil {
            // Without clipping, visibleRect alone can span the whole window.
            hovering = visibleRect.intersection(bounds).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else { hovering = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = hovering ? hoverColor?.cgColor : nil
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}
