import Contacts
import ContactsUI
import UIKit

/// Autofill My Information in Settings: its switch, and once it's on, Source joined beneath it, as
/// AI features' provider and key are. Source's Contact card, in blue, asks for the person's card
/// with the system's contact picker; once it's copied, it's grey, opening a menu to edit the copy
/// (Autofill Information), to pick the card again, or to revoke it, which forgets it at once and
/// turns it blue again.
final class AutofillSettingsGroup: UIView {
    /// Teal, apart from the colours of the rows around it.
    static let colour = UIColor.systemTeal
    let enabledRow = SettingsToggleRow("Autofill My Information", icon: MenuIcons.autofill, colour: AutofillSettingsGroup.colour,
                                       iconSide: 26, on: AutofillStore.shared.isEnabled)
    let sourceButton = UIButton(type: .system)
    let detail = UILabel()
    private let group = UIView()
    private let sourceRow = UIView()
    private let sourceIcon = UIImageView(image: MenuIcons.autofillSource)
    private let sourceTitle = UILabel()
    private let divider = UIView()
    private let store: AutofillStore
    var onChanged: (() -> Void)?
    /// Source's Edit: Autofill Information, to change and add to the card's copy.
    var onEdit: (() -> Void)?
    var buttons: [UIButton] { [enabledRow, sourceButton] }
    var rowsHeight: CGFloat { (store.isEnabled ? 2 : 1)*SiteSettingsPanel.rowHeight }

    init(store: AutofillStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        group.layer.cornerCurve = .continuous
        group.layer.cornerRadius = MenuPanel.cornerRadius
        group.clipsToBounds = true
        addSubview(group)
        [enabledRow, sourceRow, divider].forEach(group.addSubview)
        sourceRow.backgroundColor = SearchPanel.fill
        divider.backgroundColor = .separator
        enabledRow.toggle.onTintColor = SiteSettingsPanel.switchBlue
        enabledRow.onChanged = { [weak self] enabled in
            guard let self else { return }
            store.isEnabled = enabled
            refresh()
            onChanged?()
        }
        sourceTitle.text = "Source"
        sourceTitle.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
        sourceTitle.textColor = .label
        sourceTitle.adjustsFontForContentSizeCategory = true
        sourceIcon.tintColor = Self.colour
        sourceIcon.contentMode = .scaleAspectFit
        [sourceIcon, sourceTitle, sourceButton].forEach(sourceRow.addSubview)
        sourceButton.preferredMenuElementOrder = .fixed
        sourceButton.addAction(UIAction { [weak self] _ in
            guard let self, !store.hasCard else { return }
            pickCard()
        }, for: .primaryActionTriggered)
        detail.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        addSubview(detail)
        NotificationCenter.default.addObserver(forName: AutofillStore.didChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.onChanged?() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let enabled = store.isEnabled, card = store.hasCard
        if enabledRow.toggle.isOn != enabled {
            enabledRow.toggle.setOn(enabled, animated: window != nil)
            enabledRow.updateIcon()
        }
        sourceRow.isHidden = !enabled
        divider.isHidden = !enabled
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString("Contact card", attributes: AttributeContainer([
            .font: PanelHeader.font("OpenRunde-Regular", size: 16, fallbackWeight: .regular),
            .foregroundColor: card ? UIColor.secondaryLabel : UIColor.systemBlue,
        ]))
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        config.baseForegroundColor = card ? .secondaryLabel : .systemBlue
        sourceButton.configuration = config
        sourceButton.accessibilityLabel = "Source"
        sourceButton.accessibilityValue = card ? "Contact card" : "None"
        sourceButton.accessibilityHint = card ? nil : "Picks your contact card"
        sourceButton.showsMenuAsPrimaryAction = card
        sourceButton.menu = card ? UIMenu(children: [
            UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onEdit?() },
            UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.pickCard() },
            UIAction(title: "Revoke", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) { [weak self] _ in
                self?.store.revoke()
            },
        ]) : nil
        detail.textColor = .secondaryLabel
        detail.text = enabled
            ? "Fills in forms from your contact card. A copy stays in this device’s Keychain."
            : "Fills in forms from your contact card, above the keyboard."
        enabledRow.toggle.accessibilityHint = detail.text
        setNeedsLayout()
    }

    /// The system's contact picker, which asks for no access to Contacts: Rise sees only the card picked.
    private func pickCard() {
        guard let presenter = presenter else { return }
        ContactCardPicker.present(from: presenter) { [weak self] contact in
            guard let self, let contact else { return }
            do {
                // Picked again, what the card has replaces what's kept; what was added in Rise stays.
                let card = AutofillProfile(contact: contact)
                try store.save(store.profile?.refreshed(with: card) ?? card)
                store.lookUpCounties()
            } catch { detail.text = error.localizedDescription; detail.textColor = .systemRed; onChanged?() }
        }
    }

    private var presenter: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = next
        }
        return nil
    }

    func height(for width: CGFloat) -> CGFloat {
        rowsHeight+12+detail.sizeThatFits(CGSize(width: max(0, width-32), height: .greatestFiniteMagnitude)).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowHeight = SiteSettingsPanel.rowHeight, width = bounds.width, textX: CGFloat = 54
        group.frame = CGRect(x: 0, y: 0, width: width, height: rowsHeight)
        enabledRow.frame = CGRect(x: 0, y: 0, width: width, height: rowHeight)
        sourceRow.frame = CGRect(x: 0, y: rowHeight, width: width, height: rowHeight)
        sourceIcon.frame = CGRect(x: 17, y: rowHeight/2-13, width: 26, height: 26)
        let buttonWidth = min(width*0.47, sourceButton.sizeThatFits(CGSize(width: width, height: rowHeight)).width)
        sourceButton.frame = CGRect(x: width-16-buttonWidth, y: 0, width: buttonWidth, height: rowHeight)
        sourceTitle.frame = CGRect(x: textX, y: 0, width: max(0, sourceButton.frame.minX-textX-8), height: rowHeight)
        let hairline = 1/max(1, traitCollection.displayScale)
        divider.frame = CGRect(x: 16, y: rowHeight-hairline/2, width: width-32, height: hairline)
        detail.frame = CGRect(x: 16, y: rowsHeight+12, width: width-32, height: max(0, bounds.height-rowsHeight-12))
    }
}

/// Presents the system's contact picker and hands back the card picked, or nothing if it's cancelled.
@MainActor final class ContactCardPicker: NSObject, @preconcurrency CNContactPickerDelegate {
    private static var current: ContactCardPicker?
    private let completion: (CNContact?) -> Void

    private init(completion: @escaping (CNContact?) -> Void) { self.completion = completion }

    static func present(from presenter: UIViewController, completion: @escaping (CNContact?) -> Void) {
        let picker = CNContactPickerViewController()
        let delegate = ContactCardPicker(completion: completion)
        current = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) { finish(contact) }
    func contactPickerDidCancel(_ picker: CNContactPickerViewController) { finish(nil) }

    private func finish(_ contact: CNContact?) {
        completion(contact)
        Self.current = nil
    }
}
