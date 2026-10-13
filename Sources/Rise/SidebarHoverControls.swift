import AppKit

/// The layer supplies the URL pill; the native cell must not clear its fill.
final class SidebarAddressButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {}
}

/// Keep the anchor view attached while fading, but pass clicks through once
/// the sidebar is no longer hovered. Popovers anchor to the stable address bar.
class SidebarHoverButton: ChromeButton {
    var allowsInteraction = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        allowsInteraction ? super.hitTest(point) : nil
    }
}

@MainActor extension SidebarView {
    static let controlsFadeKey = "Rise.AddressControlsFade"
    func setSidebarHovered(_ hovered: Bool, animated: Bool = true) {
        isSidebarHovered = hovered
        updateAddressControlVisibility(animated: animated)
    }
    func updateAddressControlVisibility(animated: Bool = true) {
        let visible = hasAddress && (isSidebarHovered || isSiteControlsOpen) && !isHidden
        updateAddressTextBoundary(animated: animated)
        let pinned = visibleExtensionButtons
        for button in [copyButton,settingsButton] + extensionButtons {
            let shown = !(button is SidebarExtensionButton) || pinned.contains(button as! SidebarExtensionButton)
            button.allowsInteraction = visible && shown
            button.isHidden = !hasAddress || !shown
            let target: CGFloat = visible ? 1 : 0
            guard button.alphaValue != target else {
                if !animated { button.layer?.removeAnimation(forKey: Self.controlsFadeKey) }
                continue
            }
            let old = button.layer?.presentation()?.opacity ?? Float(button.alphaValue)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            button.alphaValue = target
            if !visible { button.hover = false; button.layer?.backgroundColor = button.baseColor.cgColor }
            CATransaction.commit()
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = old; fade.toValue = Float(target); fade.duration = visible ? 0.14 : 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.layer?.add(fade,forKey:Self.controlsFadeKey)
            } else { button.layer?.removeAnimation(forKey: Self.controlsFadeKey) }
        }
    }
    func updateAddressTextBoundary(animated: Bool) {
        let visible = hasAddress && (isSidebarHovered || isSiteControlsOpen) && !isHidden
        let edge = visible ? addressControlsMinX-address.frame.minX-addressText.frame.minX-2 : addressText.bounds.width
        addressText.setFadeBoundary(max(0, edge), duration: animated ? (visible ? 0.14 : 0.12) : 0)
    }
    var settingsAnchorRect: NSRect { address.convert(settingsButton.bounds, from: settingsButton) }
}
