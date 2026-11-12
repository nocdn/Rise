import AppKit

/// A pinned extension's button in the page bar, beside the copy and site controls
/// buttons: its icon, and its badge when it has one. Dragged with Control held, it moves along
/// the row; Control-clicked without moving, it shows its menu.
final class SidebarExtensionButton: SidebarHoverButton {
    let extensionID: String
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")

    init(extensionID: String, action: @escaping () -> Void) {
        self.extensionID = extensionID
        super.init(symbol: "puzzlepiece.extension", size: 13, title: "", action: action)
        image = nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = .white; badge.alignment = .center
        badge.wantsLayer = true; badge.layer?.cornerRadius = 5; badge.layer?.cornerCurve = .continuous
        badge.isHidden = true
        [icon, badge].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The pointer came onto it or left it, to have the extension ready before a press.
    var onHover: ((Bool) -> Void)?
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private var controlPress: NSEvent?, dragging = false
    /// Opens on the press, as its popup closes on one, rather than waiting for the release.
    /// With Control, it waits to see whether it's dragged.
    override func mouseDown(with event: NSEvent) {
        hoverHint?.hide()
        guard event.modifierFlags.contains(.control) else { runAction(); return }
        controlPress = event; dragging = false
    }
    /// Only along the row: a pinned tile starts moving after 3 pt, and so does this.
    override func mouseDragged(with event: NSEvent) {
        guard let press = controlPress else { return }
        if !dragging, abs(event.locationInWindow.x-press.locationInWindow.x) >= 3 { dragging = true; onDragStart?(press) }
        if dragging { onDragMove?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let press = controlPress else { return }
        controlPress = nil
        if dragging { dragging = false; onDragEnd?(); refreshHoverState() }
        else if let menu { NSMenu.popUpContextMenu(menu.separatingIconSections(), with: press, for: self) }
    }

    /// What it shows now: the icon (a puzzle piece until it loads), its name in the toolbar's
    /// hover hint with its shortcut, a badge (empty for none), and dimmed where it doesn't work on
    /// the page.
    func show(icon image: NSImage?, title: String, shortcut: String, badge text: String, badgeColor: NSColor, enabled: Bool) {
        icon.image = image ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? NSColor(hex: 0x7D7B7B) : nil
        icon.alphaValue = enabled ? 1 : 0.45
        if hoverHint?.text != title || hoverHint?.shortcut != shortcut { setHoverHint(title, shortcut: shortcut) }
        badge.stringValue = String(text.prefix(4))
        badge.isHidden = text.isEmpty
        badge.layer?.backgroundColor = badgeColor.cgColor
        needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width-16)/2, y: (bounds.height-16)/2, width: 16, height: 16)
        let width = max(10, ceil(badge.intrinsicContentSize.width)+4)
        badge.frame = NSRect(x: min(bounds.width-width, icon.frame.maxX-width+5), y: bounds.height-11, width: width, height: 10)
    }
}
