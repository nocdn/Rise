import AppKit

/// The sidebar's scroll bar: just a thin, fully rounded bar, light, darker at once while the
/// pointer is on it, with no track behind it. AppKit still fades it in and out as an overlay
/// scroller and lets it be dragged by its whole width, wider than it's drawn.
final class ThinScroller: NSScroller {
    static let thickness: CGFloat = 4, edge: CGFloat = 1
    var dark = false { didSet { if dark != oldValue { needsDisplay = true } } }
    private(set) var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    override class var isCompatibleWithOverlayScrollers: Bool { self == ThinScroller.self }
    static func color(dark: Bool, hovered: Bool) -> NSColor {
        (dark ? NSColor.white : .black).withAlphaComponent(hovered ? (dark ? 0.36 : 0.3) : (dark ? 0.18 : 0.14))
    }
    /// The bar as drawn, at the right of the knob's place: AppKit draws an overlay knob in a layer
    /// of the knob's size, so past it the bar would be cut off flat.
    var bar: NSRect {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return .zero }
        return NSRect(x: knob.maxX-Self.edge-Self.thickness, y: knob.minY+2, width: Self.thickness, height: max(0, knob.height-4))
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        guard !bar.isEmpty else { return }
        Self.color(dark: dark, hovered: hovered).setFill()
        NSBezierPath(roundedRect: bar, xRadius: Self.thickness/2, yRadius: Self.thickness/2).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func refreshHover(_ event: NSEvent) { hovered = rect(for: .knob).contains(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); refreshHover(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); refreshHover(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false }
    // Dragged, it stays dark until let go wherever the pointer ends up.
    override func mouseDown(with event: NSEvent) {
        hovered = rect(for: .knob).contains(convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if let window { hovered = rect(for: .knob).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
}
