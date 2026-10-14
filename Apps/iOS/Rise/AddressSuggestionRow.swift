import UIKit

/// Reused rows keep their press state when an icon or remote answer arrives.
final class AddressSuggestionRow: UIButton {
    let icon = UIImageView()
    let titleLabelView = UILabel()
    let addressLabel = UILabel()
    private var iconSide: CGFloat = 20
    var choose: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        titleLabelView.font = SearchPanel.font
        titleLabelView.textColor = .label
        addressLabel.font = SearchPanel.roundedFont(ofSize: 12, weight: .regular)
        addressLabel.textColor = .secondaryLabel
        for label in [titleLabelView, addressLabel] {
            label.adjustsFontForContentSizeCategory = true; label.lineBreakMode = .byTruncatingTail
        }
        [icon, titleLabelView, addressLabel].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        layer.cornerRadius = SearchPanel.cornerRadius; layer.cornerCurve = .continuous
        shrinksWhenPressed(to: SearchPanel.pressedScale, filled: true, restingFill: .clear)
        addAction(UIAction { [weak self] _ in self?.choose?() }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ candidate: AddressCandidate, image: UIImage?) {
        titleLabelView.attributedText = nil
        titleLabelView.font = SearchPanel.font
        titleLabelView.text = candidate.title
        addressLabel.text = candidate.symbol == "globe" && candidate.title != candidate.subtitle
            ? candidate.subtitle.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression) : nil
        icon.image = image ?? (candidate.symbol == "globe" ? UIImage(systemName: "globe") : SearchPanel.searchIcon)
        iconSide = candidate.symbol == "globe" ? 20 : 16
        icon.tintColor = image == nil ? SearchPanel.iconColor : nil
        accessibilityLabel = [candidate.title, addressLabel.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = candidate.tabID == nil ? "Open page" : "Switch to open tab"
        setNeedsLayout()
    }
    func showSite(_ site: PopularSite, image: UIImage?, color: UIColor?) {
        let font = SearchPanel.font
        titleLabelView.font = font
        let title = NSMutableAttributedString(string: "Search in ", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        title.append(NSAttributedString(string: site.name, attributes: [.font: font, .foregroundColor: color ?? UIColor.label]))
        titleLabelView.attributedText = title; addressLabel.text = nil
        icon.image = image ?? UIImage(systemName: "globe")
        iconSide = 20
        icon.tintColor = image == nil ? color ?? SearchPanel.iconColor : nil
        accessibilityLabel = "Search in \(site.name)"; accessibilityHint = "Enter a search for this website"
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: SearchPanel.rowIndent+(20-iconSide)/2, y: bounds.midY-iconSide/2, width: iconSide, height: iconSide)
        let x = SearchPanel.rowIndent+20+12, width = max(0, bounds.width-x-12)
        if (addressLabel.text ?? "").isEmpty {
            titleLabelView.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            addressLabel.frame = .zero
        } else {
            titleLabelView.frame = CGRect(x: x, y: 4, width: width, height: 24)
            addressLabel.frame = CGRect(x: x, y: 27, width: width, height: 16)
        }
    }
}
