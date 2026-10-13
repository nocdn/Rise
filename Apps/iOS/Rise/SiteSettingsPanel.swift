import UIKit

/// Per-site protections, with native progress feedback while an ad-blocking change reloads.
final class SiteSettingsPanel: UIView {
    static let headerHeight = PanelHeader.height
    static let rowsTop = headerHeight+MenuPanel.top
    static let rowHeight: CGFloat = 60
    /// Between the protections and Bypass paywall, set apart below them.
    static let groupGap: CGFloat = 18
    static var height: CGFloat { rowsTop+3*rowHeight+groupGap+rowHeight }
    /// The reference screenshot's blue, sampled in its Display P3 colour space.
    static let switchBlue = UIColor(displayP3Red: 63/255, green: 141/255, blue: 247/255, alpha: 1)

    private let header = PanelHeader(title: "Site settings")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    private let group = UIView()
    private let rows = [Row("Block ads", icon: MenuIcons.blockAds, colour: .systemRed),
                        Row("Block trackers", icon: MenuIcons.blockTrackers, colour: .systemOrange, iconSide: 26),
                        Row("Block cookie banners", icon: MenuIcons.blockCookieBanners, colour: .systemGreen, iconSide: 26)]
    private let dividers = [UIView(), UIView()]
    /// Off by default, and for now it changes nothing.
    private let paywallGroup = UIView()
    private let paywallRow = Row("Bypass paywall", icon: MenuIcons.bypassPaywall, colour: .systemBlue, iconSide: 26, on: false)
    var buttons: [UIButton] { [closeButton]+rows+[paywallRow] }
    var switches: [UISwitch] { (rows+[paywallRow]).map(\.toggle) }
    var onAdBlockingChanged: ((Bool) -> Void)?
    var isUpdatingAdBlocking: Bool { rows[0].spinner.isAnimating }

    func setAdBlocking(enabled: Bool, available: Bool, busy: Bool, isYouTube: Bool = false) {
        let row = rows[0]
        row.toggle.setOn(enabled, animated: window != nil)
        row.isEnabled = available && !busy
        row.toggle.isEnabled = available && !busy
        row.toggle.accessibilityHint = isYouTube ? "Ad blocking is always disabled on YouTube." : nil
        if busy { row.spinner.startAnimating() } else { row.spinner.stopAnimating() }
        row.updateIcon()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(header)
        for group in [group, paywallGroup] {
            group.layer.cornerCurve = .continuous
            group.layer.cornerRadius = MenuPanel.cornerRadius
            group.clipsToBounds = true
            addSubview(group)
        }
        for row in rows {
            row.toggle.onTintColor = Self.switchBlue
            group.addSubview(row)
        }
        paywallRow.toggle.onTintColor = Self.switchBlue
        paywallGroup.addSubview(paywallRow)
        rows[0].onChanged = { [weak self] enabled in self?.onAdBlockingChanged?(enabled) }
        for divider in dividers {
            divider.backgroundColor = .separator
            divider.isUserInteractionEnabled = false
            group.addSubview(divider)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        // Match More's full-width action exactly, including its rounded-down tile widths.
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        group.frame = CGRect(x: bounds.midX-width/2, y: Self.rowsTop, width: width, height: 3*Self.rowHeight)
        for (index, row) in rows.enumerated() {
            row.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
            row.center = CGPoint(x: width/2, y: (CGFloat(index)+0.5)*Self.rowHeight)
        }
        paywallGroup.frame = CGRect(x: group.frame.minX, y: group.frame.maxY+Self.groupGap, width: width, height: Self.rowHeight)
        paywallRow.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
        paywallRow.center = CGPoint(x: width/2, y: Self.rowHeight/2)
        let hairline = 1/max(1, traitCollection.displayScale)
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: 16, y: CGFloat(index+1)*Self.rowHeight-hairline/2, width: width-32, height: hairline)
        }
    }

    private final class Row: UIButton {
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
            let iconColumn: CGFloat = 28, textX: CGFloat = 16+iconColumn+10
            symbol.frame = CGRect(x: 16+(iconColumn-iconSide)/2, y: bounds.midY-iconSide/2,
                                  width: iconSide, height: iconSide)
            label.frame = CGRect(x: textX, y: 0, width: max(0, toggle.frame.minX-12-textX), height: bounds.height)
        }
    }
}
