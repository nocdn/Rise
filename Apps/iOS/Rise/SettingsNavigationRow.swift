import UIKit

/// A settings destination, with the address bar's chevron in place of a switch.
final class SettingsNavigationRow: UIButton {
    private let label = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)))

    init(_ title: String) {
        super.init(frame: .zero)
        label.text = title
        label.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .center
        for view in [label, chevron] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            addSubview(view)
        }
        accessibilityLabel = title
        layer.cornerCurve = .continuous
        layer.cornerRadius = MenuPanel.cornerRadius
        darkensWhenPressed(restingFill: .clear)
        shrinksWhenPressed(to: 0.98)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        chevron.frame = CGRect(x: bounds.width-16-20, y: 0, width: 20, height: bounds.height)
        label.frame = CGRect(x: 16, y: 0, width: max(0, chevron.frame.minX-12-16), height: bounds.height)
    }
}
