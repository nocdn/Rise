import UIKit

/// Site protections' visual preview. Switches change their own appearance, without changing WebKit.
final class SiteSettingsPanel: UIView {
    static let headerHeight = SearchPanel.fieldHeight
    static let rowsTop = headerHeight+MenuPanel.top
    static let rowHeight: CGFloat = 60
    static var height: CGFloat { rowsTop+3*rowHeight }
    /// The reference screenshot's blue, sampled in its Display P3 colour space.
    private static let switchBlue = UIColor(displayP3Red: 63/255, green: 141/255, blue: 247/255, alpha: 1)

    let closeButton = AnimatedSymbolButton(symbol: "xmark", pointSize: 14, weight: .bold)
    private let titleLabel = UILabel()
    private let group = UIView()
    private let rows = [Row("Block ads", icon: MenuIcons.blockAds, colour: .systemRed),
                        Row("Block trackers", icon: MenuIcons.blockTrackers, colour: .systemOrange, iconSide: 26),
                        Row("Block cookie banners", icon: MenuIcons.blockCookieBanners, colour: .systemGreen, iconSide: 26)]
    private let dividers = [UIView(), UIView()]
    var buttons: [UIButton] { [closeButton]+rows }
    var switches: [UISwitch] { rows.map(\.toggle) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = "Site settings"
        titleLabel.font = Self.font("OpenRunde-Semibold", size: 17, fallbackWeight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        closeButton.accessibilityLabel = "Back to More"
        closeButton.shrinksWhenPressed(to: AddressBar.pressedScale)
        addSubview(closeButton)
        group.layer.cornerCurve = .continuous
        group.layer.cornerRadius = MenuPanel.cornerRadius
        group.clipsToBounds = true
        addSubview(group)
        for row in rows {
            row.toggle.onTintColor = Self.switchBlue
            group.addSubview(row)
        }
        for divider in dividers {
            divider.backgroundColor = .separator
            divider.isUserInteractionEnabled = false
            group.addSubview(divider)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        closeButton.bounds = CGRect(x: 0, y: 0, width: AddressBar.buttonWidth, height: Self.headerHeight)
        closeButton.center = CGPoint(x: bounds.width-SearchPanel.inset-AddressBar.outerCentre, y: Self.headerHeight/2)
        let titleInset = SearchPanel.inset+AddressBar.outerCentre
        titleLabel.frame = CGRect(x: titleInset, y: 0,
                                  width: max(0, closeButton.frame.minX-12-titleInset), height: Self.headerHeight)
        // Match More's full-width action exactly, including its rounded-down tile widths.
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        group.frame = CGRect(x: bounds.midX-width/2, y: Self.rowsTop, width: width, height: 3*Self.rowHeight)
        for (index, row) in rows.enumerated() {
            row.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
            row.center = CGPoint(x: width/2, y: (CGFloat(index)+0.5)*Self.rowHeight)
        }
        let hairline = 1/max(1, traitCollection.displayScale)
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: 16, y: CGFloat(index+1)*Self.rowHeight-hairline/2, width: width-32, height: hairline)
        }
    }

    private static func font(_ name: String, size: CGFloat, fallbackWeight: UIFont.Weight) -> UIFont {
        let font = UIFont(name: name, size: size) ?? SearchPanel.roundedFont(ofSize: size, weight: fallbackWeight, scaled: false)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }

    private final class Row: UIButton {
        let toggle = UISwitch()
        private let symbol = UIImageView()
        private let label = UILabel()
        private let iconSide: CGFloat

        init(_ title: String, icon: UIImage?, colour: UIColor, iconSide: CGFloat = 28) {
            self.iconSide = iconSide
            super.init(frame: .zero)
            isAccessibilityElement = false
            symbol.image = icon
            symbol.tintColor = colour
            symbol.contentMode = .scaleAspectFit
            symbol.isAccessibilityElement = false
            addSubview(symbol)
            label.text = title
            label.font = SiteSettingsPanel.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .label
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = false
            addSubview(label)
            toggle.isOn = true
            toggle.accessibilityLabel = title
            toggle.addAction(UIAction { [weak self] _ in self?.updateIcon() }, for: .valueChanged)
            addSubview(toggle)
            darkensWhenPressed()
            addAction(UIAction { [weak self] _ in
                guard let self else { return }
                toggle.setOn(!toggle.isOn, animated: true)
                updateIcon()
            }, for: .primaryActionTriggered)
        }

        required init?(coder: NSCoder) { fatalError() }

        private func updateIcon() {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.symbol.alpha = self.toggle.isOn ? 1 : 0.35
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            toggle.bounds.size = toggle.intrinsicContentSize
            toggle.center = CGPoint(x: bounds.width-16-toggle.bounds.width/2, y: bounds.midY)
            let iconColumn: CGFloat = 28, textX: CGFloat = 16+iconColumn+10
            symbol.frame = CGRect(x: 16+(iconColumn-iconSide)/2, y: bounds.midY-iconSide/2,
                                  width: iconSide, height: iconSide)
            label.frame = CGRect(x: textX, y: 0, width: max(0, toggle.frame.minX-12-textX), height: bounds.height)
        }
    }
}
