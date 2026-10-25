import UIKit

/// A joined settings row: it darkens under a tap and keeps its native switch at full size.
final class SettingsToggleRow: UIButton {
    let toggle = UISwitch()
    let spinner = UIActivityIndicatorView(style: .medium)
    var onChanged: ((Bool) -> Void)?
    private let symbol = UIImageView()
    private let label = UILabel()
    private let iconSide: CGFloat

    init(_ title: String, icon: UIImage?, colour: UIColor, iconSide: CGFloat = 28, on: Bool = true) {
        self.iconSide = iconSide
        super.init(frame: .zero)
        isAccessibilityElement = false
        symbol.image = icon
        symbol.tintColor = colour
        symbol.contentMode = .scaleAspectFit
        symbol.isAccessibilityElement = false
        addSubview(symbol)
        label.text = title
        label.font = PanelHeader.font("OpenRunde-Medium", size: 16, fallbackWeight: .medium)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = false
        addSubview(label)
        toggle.isOn = on
        symbol.alpha = on ? 1 : 0.35
        toggle.accessibilityLabel = title
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            updateIcon()
            onChanged?(toggle.isOn)
        }, for: .valueChanged)
        addSubview(toggle)
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        spinner.isUserInteractionEnabled = false
        addSubview(spinner)
        darkensWhenPressed()
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            toggle.setOn(!toggle.isOn, animated: true)
            updateIcon()
            onChanged?(toggle.isOn)
        }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateIcon() {
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.symbol.alpha = self.toggle.isOn ? 1 : 0.35
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        toggle.bounds.size = toggle.intrinsicContentSize
        toggle.center = CGPoint(x: bounds.width-16-toggle.bounds.width/2, y: bounds.midY)
        spinner.bounds.size = spinner.intrinsicContentSize
        spinner.center = CGPoint(x: toggle.frame.minX-21, y: bounds.midY)
        // Without an icon, the title starts where the icon would.
        let iconColumn: CGFloat = 28, textX: CGFloat = symbol.image == nil ? 16 : 16+iconColumn+10
        symbol.frame = CGRect(x: 16+(iconColumn-iconSide)/2, y: bounds.midY-iconSide/2,
                              width: iconSide, height: iconSide)
        label.frame = CGRect(x: textX, y: 0, width: max(0, toggle.frame.minX-12-textX), height: bounds.height)
    }
}
