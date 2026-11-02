import AppKit
import RiseCore

@MainActor extension BrowserController {
    static let base64Icon: NSImage = {
        let image = Bundle.module.url(forResource: "SelectionBase64", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "qrcode", accessibilityDescription: nil)!
        image.size = NSSize(width: 16, height: 16); image.isTemplate = true
        return image
    }()

    func base64DecodeItem(for selection: String) -> NSMenuItem? {
        guard let decoded = SelectionBase64.decode(selection) else { return nil }
        let item = NSMenuItem(title: "Decode Base64", action: nil, keyEquivalent: "")
        item.image = Self.base64Icon
        let submenu = NSMenu(); submenu.autoenablesItems = false
        let copy = menuItem("Copy Decoded Value") { [weak self] in self?.copyBase64Value(decoded.value, message: SelectionBase64.decodedMessage) }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        submenu.addItem(copy)
        let preview = NSMenuItem(title: decoded.preview, action: nil, keyEquivalent: "")
        preview.isEnabled = false; submenu.addItem(preview)
        item.submenu = submenu
        return item
    }

    func base64EncodeItem(for selection: String) -> NSMenuItem? {
        guard let encoded = SelectionBase64.encode(selection) else { return nil }
        let item = NSMenuItem(title: "Encode", action: nil, keyEquivalent: "")
        item.image = Self.base64Icon
        let submenu = NSMenu(); submenu.autoenablesItems = false
        submenu.addItem(menuItem("Base64") { [weak self] in self?.copyBase64Value(encoded, message: SelectionBase64.encodedMessage) })
        item.submenu = submenu
        return item
    }

    private func copyBase64Value(_ text: String, message: String) {
        linkPasteboard.clearContents()
        guard linkPasteboard.setString(text, forType: .string) else { return }
        selectedBar.showNotice(message, image: Self.base64Icon)
    }
}
