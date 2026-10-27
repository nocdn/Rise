import AppKit

/// A button's native hover popover: its action, followed by its shortcut in secondary ink.
/// Kept separate from drawing so custom glyph buttons use the same hint as image buttons.
@MainActor final class ButtonHoverHint {
    static let delay = 0.6
    private weak var button: ChromeButton?
    private(set) var text: String
    private(set) var shortcut: String
    private var hovered = false
    private var timer: Timer?
    private var hintField: NSTextField?
    private(set) var popover: NSPopover?
    var appearance: NSAppearance? { didSet { popover?.appearance = appearance ?? button?.effectiveAppearance } }

    init(button: ChromeButton, text: String, shortcut: String) {
        self.button = button; self.text = text; self.shortcut = shortcut
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }
    private func show() {
        timer = nil
        guard let button, button.hover, button.window?.isVisible == true,
              !button.isHiddenOrHasHiddenAncestor, button.alphaValue > 0.01, popover?.isShown != true else { return }
        let popover = popover ?? makePopover()
        popover.appearance = appearance ?? button.effectiveAppearance
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .minY : .maxY)
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
