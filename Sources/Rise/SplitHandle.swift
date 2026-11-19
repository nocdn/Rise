import AppKit

/// The small pill in the gap between split pages. Hovering springs it longer and a little
/// darker; pressing darkens it more and shrinks it slightly, as the app's buttons do; dragging
/// moves the split, and a double click puts it back in the middle.
@MainActor final class SplitHandle: NSView {
    static let thickness: CGFloat = 3, restingLength: CGFloat = 28, hoverLength: CGFloat = 44
    static let pressedScale: CGFloat = 0.9
    /// Quick, with a little bounce as it lengthens; it settles back without one.
    static var growSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.28, bounce: 0.3) }
    static var shrinkSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.22, bounce: 0) }

    /// How far the pointer has moved sideways since the press, in points.
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?
    var canReturnToPeek: (() -> Bool)?
    var onReturnToPeek: (() -> Void)?
    var onSwapSides: (() -> Void)?
    /// The menu's Swap sides shows the shortcut the menu bar's Swap Split Sides has.
    var swapShortcut: (() -> NSMenuItem?)?
    private let pill = CALayer()
    private var tint = NSColor.black
    private var pressPoint: NSPoint?
    private(set) var hovering = false { didSet { if hovering != oldValue { update(lengthChanged: true) } } }
    private(set) var pressed = false {
        didSet {
            guard pressed != oldValue else { return }
            update(lengthChanged: false); PressScale.set(pill, to: pressed ? Self.pressedScale : 1)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pill.cornerRadius = Self.thickness/2
        pill.bounds = CGRect(x: 0, y: 0, width: Self.thickness, height: Self.restingLength)
        layer?.addSublayer(pill)
        toolTip = "Drag to resize the split"
        setAccessibilityElement(true); setAccessibilityRole(.splitter); setAccessibilityLabel("Split divider")
        update(lengthChanged: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: RiseTheme) { tint = theme.text; update(lengthChanged: false) }
    var length: CGFloat { hovering || pressed ? Self.hoverLength : Self.restingLength }
    /// Darker on hover, and darker again while held.
    var alpha: CGFloat { pressed ? 0.42 : hovering ? 0.3 : 0.18 }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pill.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    private func update(lengthChanged: Bool) {
        let target = length
        let shown = (pill.presentation() ?? pill).bounds.height
        CATransaction.begin(); CATransaction.setAnimationDuration(pressed ? 0.06 : 0.15)
        pill.backgroundColor = tint.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
        guard lengthChanged || pill.bounds.height != target else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pill.bounds.size.height = target
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(shown-target) > 0.1 else { return }
        // One number, so the spring can carry it past its end.
        let spring = target > shown ? Self.growSpring : Self.shrinkSpring
        spring.keyPath = "bounds.size.height"; spring.fromValue = shown; spring.toValue = target
        spring.duration = spring.settlingDuration
        pill.add(spring, forKey: "length")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate], owner: self))
        refreshHover()
    }
    func refreshHover() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { hovering = false; return }
        hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { canReturnToPeek == nil ? nil : makeContextMenu().separatingIconSections() }
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = NSMenuItem(title: "Return to Peek state", action: #selector(returnToPeek), keyEquivalent: "")
        item.target = self; item.isEnabled = canReturnToPeek?() == true
        menu.addItem(item)
        let swap = NSMenuItem(title: "Swap sides", action: #selector(swapSides), keyEquivalent: "")
        if let shortcut = swapShortcut?() { swap.keyEquivalent = shortcut.keyEquivalent; swap.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask }
        swap.target = self; swap.isEnabled = onSwapSides != nil
        menu.addItem(swap)
        return menu
    }
    @objc private func returnToPeek() { if canReturnToPeek?() == true { onReturnToPeek?() } }
    @objc private func swapSides() { onSwapSides?() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pressPoint = nil; onReset?(); return }
        pressPoint = event.locationInWindow; pressed = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint else { return }
        NSCursor.resizeLeftRight.set()
        onDrag?(event.locationInWindow.x-pressPoint.x)
    }
    override func mouseUp(with event: NSEvent) {
        let dragged = pressPoint != nil
        pressPoint = nil; pressed = false
        if dragged { onDragEnd?() }
        refreshHover()
    }

    /// For tests: the pill as it rests once any spring is done, and how far it's shrunk.
    var pillLength: CGFloat { pill.bounds.height }
    var pillAlpha: CGFloat { pill.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 }
    var pressScale: CGFloat { pill.transform.m11 }
    var lengthSpring: CASpringAnimation? { pill.animation(forKey: "length") as? CASpringAnimation }
}
