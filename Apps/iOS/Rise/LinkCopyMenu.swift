import UIKit

/// A held link's Copy Link, for one that writes an email, rings or texts a number or shows a
/// place, becomes Copy Email Address, Copy Phone Number, Copy Coordinates or Copy Address, with
/// an icon of its own, copying that alone (`LinkCopy`), as the Mac's menu does.
enum LinkCopyMenu {
    /// WebKit's Copy for a link, which is Copy Link; an image's own Copy is Rise's by now.
    static let copyIdentifier = UIAction.Identifier("WKElementActionTypeCopy")
    static let identifier = UIAction.Identifier("dev.bartosz.Rise.copyLinkTarget")

    static func menu(_ menu: UIMenu, link: URL?) -> UIMenu {
        guard let link else { return menu }
        let copy = LinkCopy(link)
        guard let text = copy.text else { return menu }
        var replaced = false
        func swap(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.map { element in
                if let menu = element as? UIMenu { return menu.replacingChildren(swap(menu.children)) }
                guard let action = element as? UIAction, action.title == "Copy Link" || action.identifier == copyIdentifier else { return element }
                replaced = true
                return self.action(copy, text: text)
            }
        }
        let children = swap(menu.children)
        // Where WebKit offered no Copy at all, it goes at the end in a section of its own.
        let all = replaced ? children : children+[UIMenu(options: .displayInline, children: [action(copy, text: text)])]
        return menu.replacingChildren(all)
    }
    private static func action(_ copy: LinkCopy, text: String) -> UIAction {
        UIAction(title: copy.title, image: UIImage(systemName: copy.symbol), identifier: identifier) { _ in UIPasteboard.general.string = text }
    }
}
