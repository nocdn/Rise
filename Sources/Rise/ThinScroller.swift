import AppKit

/// Reopening the sidebar isn't a scroll gesture. Only interaction should bring its
/// overlay indicator back; AppKit still owns the indicator's usual fade afterward.
final class SidebarScrollView: NSScrollView {
    /// Scrolls with no bar at all, as Settings can ask of the sidebar.
    var hidesScroller = false { didSet { hasVerticalScroller = !hidesScroller } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func revealScroller(at event: NSEvent) {
        // Track from the visible scroll view, since an alpha-zero indicator needn't
        // receive mouse events itself. Its native drag target returns before a click.
        if hasVerticalScroller, let scroller = verticalScroller as? ThinScroller,
           scroller.frame.contains(convert(event.locationInWindow, from: nil)) {
            scroller.revealForInteraction()
        }
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); revealScroller(at: event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); revealScroller(at: event) }
    override func scrollWheel(with event: NSEvent) {
        if hasVerticalScroller, event.scrollingDeltaY != 0 || event.phase == .began {
            (verticalScroller as? ThinScroller)?.revealForInteraction()
        }
        super.scrollWheel(with: event)
    }
}

/// The sidebar's scroll bar, drawn just like the hover cards' (`GmailScroller`): thin, fully rounded,
/// with no track, darker while the pointer is over it. AppKit still fades it in and out as an overlay
/// scroller and lets it be dragged by its whole width, wider than it's drawn.
final class ThinScroller: NSScroller {
    private(set) var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    override class var isCompatibleWithOverlayScrollers: Bool { self == ThinScroller.self }
    override func viewDidHide() {
        super.viewDidHide()
        hovered = false
        suppressRevealFlash()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        suppressRevealFlash()
    }
    private func suppressRevealFlash() {
        // The native overlay can flash its cached knob when an ancestor reappears,
        // without calling NSScrollView.flashScrollers(). Hide that reveal only.
        alphaValue = scrollerStyle == .overlay ? 0 : 1
    }
    func revealForInteraction() {
        guard alphaValue != 1 else { return }
        alphaValue = 1
        enclosingScrollView?.flashScrollers()
    }
    /// The bar as drawn, inside the knob's place.
    var bar: NSRect { GmailScroller.bar(knob: rect(for: .knob), in: bounds) }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() { GmailScroller.draw(bar, hovered: hovered) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    // Like the cards', it darkens with the pointer anywhere over it, not only over the bar.
    private func refreshHover(_ event: NSEvent) { hovered = visibleRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { revealForInteraction(); super.mouseEntered(with: event); refreshHover(event) }
    override func mouseMoved(with event: NSEvent) { revealForInteraction(); super.mouseMoved(with: event); refreshHover(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hovered = false }
    // Dragged, it stays dark until let go wherever the pointer ends up.
    override func mouseDown(with event: NSEvent) {
        revealForInteraction()
        hovered = true
        super.mouseDown(with: event)
        if let window { hovered = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
}
