import UIKit

/// A settings row whose value is picked from a menu at its end, as AI Provider's is: the value and
/// a chevron, opening the system's menu.
final class SettingsMenuRow: UIView {
    let button = UIButton(type: .system)
    private let symbol = UIImageView()
    private let label = UILabel()
    private let iconSide: CGFloat

    init(_ title: String, icon: UIImage?, colour: UIColor, iconSide: CGFloat = 26) {
        self.iconSide = iconSide
        super.init(frame: .zero)
        backgroundColor = SearchPanel.fill
        symbol.image = icon; symbol.tintColor = colour; symbol.contentMode = .scaleAspectFit
        label.text = title
        label.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        [symbol, label, button].forEach(addSubview)
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = title
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `value`, and the menu to change it.
    func show(_ value: String, menu: UIMenu) {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(value, attributes: AttributeContainer([
            .font: PanelHeader.font("OpenRunde-Regular", size: 16, fallbackWeight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ]))
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        config.baseForegroundColor = .secondaryLabel
        button.configuration = config
        button.accessibilityValue = value
        button.menu = menu
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Without an icon, the title starts at the row's edge, as Autofill Information's do.
        let iconColumn: CGFloat = 28, textX: CGFloat = symbol.image == nil ? 16 : 16+iconColumn+10
        symbol.frame = CGRect(x: 16+(iconColumn-iconSide)/2, y: bounds.midY-iconSide/2, width: iconSide, height: iconSide)
        let width = min(bounds.width*0.47, button.sizeThatFits(bounds.size).width)
        button.frame = CGRect(x: bounds.width-16-width, y: 0, width: width, height: bounds.height)
        label.frame = CGRect(x: textX, y: 0, width: max(0, button.frame.minX-textX-8), height: bounds.height)
    }
}
