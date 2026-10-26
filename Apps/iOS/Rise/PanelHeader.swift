import UIKit

/// The title and X along the top of a panel that More turns into, such as Site settings and
/// Downloads. The X sits where Reload does in the address, and returns to More.
final class PanelHeader: UIView {
    static let height = SearchPanel.fieldHeight
    let closeButton = AnimatedSymbolButton(symbol: "xmark", pointSize: 14, weight: .bold)
    private let titleLabel = UILabel()
    /// A control just after the title, such as Downloads' menu.
    var accessory: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory { addSubview(accessory) }
            setNeedsLayout()
        }
    }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = Self.font("OpenRunde-Semibold", size: 17, fallbackWeight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        closeButton.accessibilityLabel = "Back to More"
        closeButton.shrinksWhenPressed(to: AddressBar.pressedScale)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String? {
        get { titleLabel.text }
        set { titleLabel.text = newValue; setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        closeButton.bounds = CGRect(x: 0, y: 0, width: AddressBar.buttonWidth, height: Self.height)
        closeButton.center = CGPoint(x: bounds.width-SearchPanel.inset-AddressBar.outerCentre, y: Self.height/2)
        let titleInset = SearchPanel.inset+AddressBar.outerCentre
        let room = max(0, closeButton.frame.minX-12-titleInset)
        guard let accessory else {
            titleLabel.frame = CGRect(x: titleInset, y: 0, width: room, height: Self.height)
            return
        }
        let side = AddressBar.buttonWidth, gap: CGFloat = 6
        let width = min(ceil(titleLabel.intrinsicContentSize.width), max(0, room-gap-side))
        titleLabel.frame = CGRect(x: titleInset, y: 0, width: width, height: Self.height)
        // By bounds and center, as a pressed button is scaled.
        accessory.bounds = CGRect(x: 0, y: 0, width: side, height: Self.height)
        accessory.center = CGPoint(x: titleLabel.frame.maxX+gap+side/2, y: Self.height/2)
    }

    static func font(_ name: String, size: CGFloat, fallbackWeight: UIFont.Weight) -> UIFont {
        let font = UIFont(name: name, size: size) ?? SearchPanel.roundedFont(ofSize: size, weight: fallbackWeight, scaled: false)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }
}
