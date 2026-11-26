import UIKit

/// Per-site protections, with native progress feedback while an ad-blocking change reloads.
final class SiteSettingsPanel: UIView {
    static let headerHeight = PanelHeader.height
    static let rowsTop = headerHeight+MenuPanel.top
    static let rowHeight: CGFloat = 60
    static let appSettingsRowHeight: CGFloat = 68
    /// Between the protections and Bypass paywall, set apart below them.
    static let groupGap: CGFloat = 18
    static var height: CGFloat { rowsTop+4*rowHeight+2*groupGap+appSettingsRowHeight }
    /// The reference screenshot's blue, sampled in its Display P3 colour space.
    static let switchBlue = UIColor(displayP3Red: 63/255, green: 141/255, blue: 247/255, alpha: 1)

    private let header = PanelHeader(title: "Site settings")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    private let group = UIView()
    private let rows = [SettingsToggleRow("Block ads", icon: MenuIcons.blockAds, colour: .systemRed),
                        SettingsToggleRow("Block popups", icon: MenuIcons.blockPopups, colour: .systemOrange, iconSide: 26),
                        SettingsToggleRow("Block cookie banners", icon: MenuIcons.blockCookieBanners, colour: .systemGreen, iconSide: 26)]
    private let dividers = [UIView(), UIView()]
    private let paywallGroup = UIView()
    private let paywallRow = SettingsToggleRow("Bypass paywall", icon: MenuIcons.bypassPaywall, colour: .systemBlue, iconSide: 26, on: false)
    let appSettingsRow = SettingsNavigationRow("App settings")
    var buttons: [UIButton] { [closeButton]+rows+[paywallRow, appSettingsRow] }
    var switches: [UISwitch] { (rows+[paywallRow]).map(\.toggle) }
    var onAdBlockingChanged: ((Bool) -> Void)?
    var onCookieBannersChanged: ((Bool) -> Void)?
    var onPopupsChanged: ((Bool) -> Void)?
    var onPaywallBypassChanged: ((Bool) -> Void)?
    var isUpdatingAdBlocking: Bool { rows[0].spinner.isAnimating }
    var isUpdatingCookieBanners: Bool { rows[2].spinner.isAnimating }

    func setPaywallBypass(enabled: Bool, available: Bool) {
        paywallRow.toggle.setOn(enabled, animated: window != nil)
        paywallRow.isEnabled = available
        paywallRow.toggle.isEnabled = available
        paywallRow.toggle.accessibilityHint = "Reveals article content already loaded by compatible sites and reloads this page."
        paywallRow.updateIcon()
    }

    func setPopups(enabled: Bool, available: Bool) {
        let row = rows[1]
        row.toggle.setOn(enabled, animated: window != nil)
        row.isEnabled = available; row.toggle.isEnabled = available
        row.toggle.accessibilityHint = "Blocks unwanted new windows and advertising popunders."
        row.updateIcon()
    }

    func setCookieBanners(enabled: Bool, available: Bool, busy: Bool) {
        let row = rows[2]
        row.toggle.setOn(enabled, animated: window != nil)
        row.isEnabled = available && !busy
        row.toggle.isEnabled = available && !busy
        row.toggle.accessibilityHint = "Automatically accepts cookie banners."
        if busy { row.spinner.startAnimating() } else { row.spinner.stopAnimating() }
        row.updateIcon()
    }

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
        addSubview(appSettingsRow)
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
        paywallRow.onChanged = { [weak self] enabled in self?.onPaywallBypassChanged?(enabled) }
        rows[0].onChanged = { [weak self] enabled in self?.onAdBlockingChanged?(enabled) }
        rows[1].onChanged = { [weak self] enabled in self?.onPopupsChanged?(enabled) }
        rows[2].onChanged = { [weak self] enabled in self?.onCookieBannersChanged?(enabled) }
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
        group.frame = CGRect(x: bounds.midX-width/2, y: Self.rowsTop, width: width, height: CGFloat(rows.count)*Self.rowHeight)
        for (index, row) in rows.enumerated() {
            row.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
            row.center = CGPoint(x: width/2, y: (CGFloat(index)+0.5)*Self.rowHeight)
        }
        paywallGroup.frame = CGRect(x: group.frame.minX, y: group.frame.maxY+Self.groupGap, width: width, height: Self.rowHeight)
        paywallRow.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
        paywallRow.center = CGPoint(x: width/2, y: Self.rowHeight/2)
        appSettingsRow.bounds = CGRect(x: 0, y: 0, width: width, height: Self.appSettingsRowHeight)
        appSettingsRow.center = CGPoint(x: bounds.midX, y: paywallGroup.frame.maxY+Self.groupGap+Self.appSettingsRowHeight/2)
        let hairline = 1/max(1, traitCollection.displayScale)
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: 16, y: CGFloat(index+1)*Self.rowHeight-hairline/2, width: width-32, height: hairline)
        }
    }

}
