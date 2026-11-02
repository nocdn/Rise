import UIKit

/// Keep the system's translation command, responder routing and localized title;
/// only its image changes to Rise's translation glyph at native-menu weight.
@MainActor enum SelectionMenuIcons {
    static let translation = UIImage(named: "SelectionTranslate")

    static func build(_ builder: UIMenuBuilder) {
        guard builder.system == .context else { return }
        builder.replaceChildren(ofMenu: .root) { $0.map(replacingTranslationIcon) }
    }

    static func applying(to menu: UIMenu) -> UIMenu {
        replacingTranslationIcon(menu) as! UIMenu
    }

    private static func replacingTranslationIcon(_ element: UIMenuElement) -> UIMenuElement {
        if let menu = element as? UIMenu {
            let children = menu.children.map(replacingTranslationIcon)
            return zip(children, menu.children).allSatisfy { $0 === $1 } ? menu : menu.replacingChildren(children)
        }
        // WebKit supports both spellings, including on non-English systems.
        guard let command = element as? UICommand,
              ["translate:", "_translate:"].contains(NSStringFromSelector(command.action)),
              let translation, command.image !== translation else { return element }
        let result = command.copy() as! UICommand
        result.image = translation
        return result
    }
}
