import UIKit
import WebKit

/// Native UIKit submenus inherit the system's Liquid Glass menu presentation.
@MainActor enum SelectionBase64Menu {
    static let decodeIdentifier = UIMenu.Identifier("dev.bartosz.Rise.decodeBase64")
    static let encodeIdentifier = UIMenu.Identifier("dev.bartosz.Rise.encode")
    static var icon: UIImage? { UIImage(named: "SelectionBase64") }
    static var menuIcon: UIImage? { UIImage(named: "SelectionBase64Menu") }

    static func build(_ builder: UIMenuBuilder, in page: WKWebView) {
        guard builder.system == .context else { return }
        let text = SelectionTimeMenu.rawSelection(in: page)
        let children = [decodeMenu(for: text, in: page), encodeMenu(for: text, in: page)].compactMap { $0 }
        guard !children.isEmpty else { return }
        builder.insertChild(UIMenu(identifier: .init("dev.bartosz.Rise.base64Section"), options: .displayInline, children: children), atEndOfMenu: .root)
    }

    static func decodeMenu(for text: String, in page: WKWebView?) -> UIMenu? {
        guard let decoded = SelectionBase64.decode(text) else { return nil }
        let copy = UIAction(title: "Copy Value", image: UIImage(systemName: "doc.on.doc")) { [weak page] _ in
            copied(decoded.value, message: SelectionBase64.decodedMessage, in: page)
        }
        let preview = UIAction(title: decoded.preview, attributes: .disabled) { _ in }
        return UIMenu(title: "Decode Base64", image: menuIcon, identifier: decodeIdentifier, children: [copy, preview])
    }

    static func encodeMenu(for text: String, in page: WKWebView?) -> UIMenu? {
        guard let encoded = SelectionBase64.encode(text) else { return nil }
        let action = UIAction(title: "Base64", image: menuIcon) { [weak page] _ in
            copied(encoded, message: SelectionBase64.encodedMessage, in: page)
        }
        return UIMenu(title: "Encode", image: menuIcon, identifier: encodeIdentifier, children: [action])
    }

    private static func copied(_ text: String, message: String, in page: WKWebView?) {
        UIPasteboard.general.string = text
        UISelectionFeedbackGenerator().selectionChanged()
        var responder: UIResponder? = page
        while let current = responder {
            if let browser = current as? BrowserViewController {
                let toast = Toast(message: message, glyph: icon, name: "base64")
                browser.showToast(toast); toast.leave(after: 2)
                UIAccessibility.post(notification: .announcement, argument: message)
                break
            }
            responder = current.next
        }
    }
}
