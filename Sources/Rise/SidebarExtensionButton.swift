import AppKit

/// A pinned extension's button in the sidebar's address row, beside the copy and site controls
/// buttons, fading in and out with them: its icon, and its badge when it has one.
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

    /// What it shows now: the icon (a puzzle piece until it loads), a tooltip, a badge (empty for
    /// none), and dimmed where it doesn't work on the page.
    func show(icon image: NSImage?, title: String, badge text: String, badgeColor: NSColor, enabled: Bool) {
        icon.image = image ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        icon.contentTintColor = image == nil ? NSColor(hex: 0x7D7B7B) : nil
        icon.alphaValue = enabled ? 1 : 0.45
        toolTip = title; setAccessibilityLabel(title)
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

@MainActor extension SidebarView {
    /// Room for the pinned extensions' buttons left of the copy button, leaving the address some.
    static let extensionButtonStride: CGFloat = 26
    var visibleExtensionButtons: [SidebarExtensionButton] {
        let room = fixedControlsMinX-address.frame.minX-60
        let count = max(0, Int(room/Self.extensionButtonStride))
        return Array(extensionButtons.prefix(count))
    }
    /// The left edge of the address row's buttons, as many as show.
    var addressControlsMinX: CGFloat {
        visibleExtensionButtons.last.map(\.frame.minX) ?? fixedControlsMinX
    }
    /// The copy button's left edge, or the zoom button's while it shows.
    var fixedControlsMinX: CGFloat { showsZoom ? zoomButton.frame.minX : copyButton.frame.minX }
    func layoutExtensionButtons() {
        let visible = visibleExtensionButtons
        for (index, button) in extensionButtons.enumerated() {
            button.frame = NSRect(x: fixedControlsMinX-Self.extensionButtonStride*CGFloat(index+1), y: copyButton.frame.minY,
                                  width: 25, height: copyButton.frame.height)
            button.isHidden = !hasAddress || !visible.contains(button)
        }
    }
}
