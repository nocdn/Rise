import UIKit

/// Reused rows keep their press state when an icon or remote answer arrives.
final class AddressSuggestionRow: UIButton {
    /// Temporary single-line preview; retain the URL and its layout for an easy switch back.
    static let showsURLSubtitles = false
    let pressBackground = UIView()
    let icon = UIImageView()
    let titleLabelView = UILabel()
    let addressLabel = UILabel()
    let fillButton = UIButton(type: .custom)
    let fillGlyph = UIImageView(image: SearchPanel.fillIcon)
    private var iconSide: CGFloat = 22
    private var iconOffset: CGFloat = 0
    private var roundsIconCorners = false
    var choose: (() -> Void)?
    var fill: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.clipsToBounds = true
        icon.layer.cornerCurve = .continuous
        titleLabelView.font = SearchPanel.font
        titleLabelView.textColor = .label
        addressLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        addressLabel.textColor = UIColor { $0.userInterfaceStyle == .dark ? .secondaryLabel : UIColor(white: 0.42, alpha: 1) }
        for label in [titleLabelView, addressLabel] {
            label.adjustsFontForContentSizeCategory = true; label.lineBreakMode = .byTruncatingTail
        }
        pressBackground.layer.cornerRadius = SearchPanel.cornerRadius
        pressBackground.layer.cornerCurve = .continuous
        [pressBackground, icon, titleLabelView, addressLabel].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        fillGlyph.isUserInteractionEnabled = false
        fillGlyph.tintColor = SearchPanel.iconColor
        fillButton.addSubview(fillGlyph)
        fillButton.shrinksWhenPressed(to: 0.9)
        fillButton.addAction(UIAction { [weak self] _ in self?.fill?() }, for: .primaryActionTriggered)
        addSubview(fillButton)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Fill in search field") { [weak self] _ in
            guard let self, let fill else { return false }
            fill(); return true
        }]
        layer.cornerRadius = SearchPanel.cornerRadius; layer.cornerCurve = .continuous
        clipsToBounds = false
        shrinksWhenPressed(to: SearchPanel.pressedScale, filled: true, restingFill: .clear, fillView: pressBackground)
        addAction(UIAction { [weak self] _ in self?.choose?() }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ candidate: AddressCandidate, image: UIImage?) {
        titleLabelView.attributedText = nil
        titleLabelView.font = SearchPanel.font
        titleLabelView.text = candidate.title
        addressLabel.text = candidate.symbol == "globe" && candidate.title != candidate.subtitle
            ? Self.displayAddress(candidate.subtitle) : nil
        addressLabel.isHidden = !Self.showsURLSubtitles || addressLabel.text == nil
        icon.image = image ?? (candidate.symbol == "globe" ? UIImage(systemName: "globe") : SearchPanel.searchIcon)
        roundsIconCorners = image != nil
        iconSide = candidate.symbol == "globe" ? 20 : 16
        iconOffset = candidate.symbol == "globe" ? 1 : 0
        icon.tintColor = image == nil ? SearchPanel.iconColor : nil
        accessibilityLabel = [candidate.title, addressLabel.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = candidate.tabID == nil ? "Open page" : "Switch to open tab"
        fillButton.accessibilityLabel = "Fill \(candidate.title) in search field"
        setNeedsLayout()
    }
    func showSite(_ site: PopularSite, image: UIImage?, color: UIColor?) {
        let font = SearchPanel.font
        titleLabelView.font = font
        let title = NSMutableAttributedString(string: "Search in ", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        title.append(NSAttributedString(string: site.name, attributes: [.font: font, .foregroundColor: color ?? UIColor.label]))
        titleLabelView.attributedText = title; addressLabel.text = nil
        addressLabel.isHidden = true
        icon.image = image ?? UIImage(systemName: "globe")
        roundsIconCorners = image != nil
        iconSide = 20
        iconOffset = 1
        icon.tintColor = image == nil ? color ?? SearchPanel.iconColor : nil
        accessibilityLabel = "Search in \(site.name)"; accessibilityHint = "Enter a search for this website"
        fillButton.accessibilityLabel = "Fill \(site.homeURL.absoluteString) in search field"
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // More breathing room around the pressed fill; row bounds and content stay put.
        pressBackground.frame = bounds.insetBy(dx: -6, dy: 0)
        icon.frame = CGRect(x: SearchPanel.rowIndent+(22-iconSide)/2+iconOffset, y: bounds.midY-iconSide/2, width: iconSide, height: iconSide)
        icon.layer.cornerRadius = roundsIconCorners ? iconSide*FaviconView.cornerRadiusFraction : 0
        fillButton.bounds = CGRect(x: 0, y: 0, width: 44, height: bounds.height)
        fillButton.center = CGPoint(x: bounds.width-22, y: bounds.midY)
        let glyphSide = SearchPanel.searchIcon.size.width
        let glyphInset = SearchPanel.rowIndent+(22-glyphSide)/2+1
        fillGlyph.frame = CGRect(x: fillButton.bounds.width-glyphInset-glyphSide, y: bounds.midY-glyphSide/2,
                                 width: glyphSide, height: glyphSide)
        let x = SearchPanel.rowIndent+22+8, width = max(0, bounds.width-44-x)
        if !Self.showsURLSubtitles || (addressLabel.text ?? "").isEmpty {
            let height = min(bounds.height, titleLabelView.font.lineHeight.rounded(.up))
            titleLabelView.frame = CGRect(x: x, y: bounds.midY-height/2, width: width, height: height)
            addressLabel.frame = .zero
        } else {
            // Match the reference's standard 17-point title and 12-point medium URL.
            let y = (bounds.height-38)/2
            titleLabelView.frame = CGRect(x: x, y: y, width: width, height: 24)
            addressLabel.frame = CGRect(x: x, y: y+20, width: width, height: 18)
        }
    }

    static func displayAddress(_ address: String) -> String {
        var text = address.replacingOccurrences(of: "^https?://", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "^www\\.", with: "", options: [.regularExpression, .caseInsensitive])
        if let url = URLComponents(string: address), url.host != nil,
           url.path == "/", url.query == nil, url.fragment == nil, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
