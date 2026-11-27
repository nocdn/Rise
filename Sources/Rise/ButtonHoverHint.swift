import AppKit

/// A button's native hover popover: its action, followed by its shortcut in secondary ink.
/// Kept separate from drawing so custom glyph buttons use the same hint as image buttons.
@MainActor final class ButtonHoverHint {
    static let delay = 0.6
    private weak var button: NSView?
    private let delay: TimeInterval
    /// The part of the view the popover points to, when not all of it.
    var anchor: (() -> NSRect)?
    private(set) var text: String
    private(set) var shortcut: String
    private var hovered = false
    private var timer: Timer?
    private var hintField: NSTextField?
    private(set) var popover: NSPopover?
    var appearance: NSAppearance? { didSet { popover?.appearance = appearance ?? button?.effectiveAppearance } }

    init(button: NSView, text: String, shortcut: String = "", delay: TimeInterval? = nil) {
        self.button = button; self.text = text; self.shortcut = shortcut; self.delay = delay ?? Self.delay
    }
    var hintText: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if !shortcut.isEmpty {
            result.append(NSAttributedString(string: "  "+shortcut, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return result
    }
    func update(text: String, shortcut: String) {
        guard text != self.text || shortcut != self.shortcut else { return }
        self.text = text; self.shortcut = shortcut
        guard let hint = hintField, let content = hint.superview else { return }
        hint.attributedStringValue = hintText; hint.sizeToFit()
        content.setFrameSize(NSSize(width: ceil(hint.frame.width)+24, height: ceil(hint.frame.height)+16))
        popover?.contentSize = content.frame.size
    }
    func setShortcut(_ shortcut: String) { update(text: text, shortcut: shortcut) }

    func setHovered(_ hovered: Bool) {
        guard hovered != self.hovered else { return }
        self.hovered = hovered
        hide()
        guard hovered else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }
    private func show() {
        timer = nil
        guard let button, hovered, button.window?.isVisible == true,
              !button.isHiddenOrHasHiddenAncestor, button.alphaValue > 0.01, popover?.isShown != true else { return }
        let rect = anchor?() ?? button.bounds
        guard !rect.isEmpty else { return }
        let popover = popover ?? makePopover()
        popover.appearance = appearance ?? button.effectiveAppearance
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: rect, of: button, preferredEdge: button.isFlipped ? .minY : .maxY)
    }
    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let hint = NSTextField(labelWithAttributedString: hintText)
        hintField = hint; hint.sizeToFit()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: ceil(hint.frame.width)+24, height: ceil(hint.frame.height)+16))
        hint.frame.origin = NSPoint(x: 12, y: 8); content.addSubview(hint)
        let controller = NSViewController(); controller.view = content
        popover.contentViewController = controller; popover.contentSize = content.frame.size
        self.popover = popover
        return popover
    }
    func hide() {
        timer?.invalidate(); timer = nil
        if popover?.isShown == true { popover?.close() }
    }
    deinit { timer?.invalidate() }
}

/// Something in a row that explains itself in the native hover popover, after a second's pause,
/// though the row under it takes the clicks: a quick answer's source, the copy icon.
@MainActor class HoverHintView: FlippedView {
    static let hintDelay: TimeInterval = 1
    private(set) var hoverHint: ButtonHoverHint?
    /// Where the pointer brings the hint up, and the popover points to.
    var hintRect: NSRect { bounds }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The hint, or none, in the palette's theme.
    func setHoverHint(_ text: String?, theme: RiseTheme) {
        guard let text else {
            hoverHint?.setHovered(false); hoverHint = nil
            return
        }
        if let hoverHint { hoverHint.update(text: text, shortcut: "") }
        else {
            let hint = ButtonHoverHint(button: self, text: text, delay: Self.hintDelay)
            hint.anchor = { [weak self] in self?.hintRect ?? .zero }
            hoverHint = hint
        }
        hoverHint?.appearance = theme.appearance
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        // Moves too: shown only once its row is picked, it can appear under the pointer.
        addTrackingArea(NSTrackingArea(rect: hintRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
        // Moved or changed under a still pointer: no hint starts, but one it has left goes.
        if !pointerIsOver { hoverHint?.setHovered(false) }
    }
    private var pointerIsOver: Bool {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 else { return false }
        return hintRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { hoverHint?.setHovered(pointerIsOver) }
    override func mouseMoved(with event: NSEvent) { hoverHint?.setHovered(pointerIsOver) }
    override func mouseExited(with event: NSEvent) { hoverHint?.setHovered(false) }
    override func viewDidHide() { super.viewDidHide(); hoverHint?.setHovered(false) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hoverHint?.setHovered(false) } }
}
