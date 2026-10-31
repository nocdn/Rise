import UIKit

/// App-wide settings, with matching toggle rows and explanatory subtitles.
final class AppSettingsPanel: UIView {
    static var height: CGFloat { SiteSettingsPanel.height+120 }
    private let header = PanelHeader(title: "Settings")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let syncRow = SettingsToggleRow("Sync tabs with iCloud", icon: MenuIcons.syncTabs, colour: .systemBlue, iconSide: 26)
    let autoplayRow = SettingsToggleRow("Autoplay videos", icon: MenuIcons.video, colour: .systemGreen, iconSide: 26)
    let incognitoLockRow = SettingsToggleRow("Locked incognito mode", icon: MenuIcons.lockedIncognito, colour: .systemPurple,
                                             iconSide: 26, on: IncognitoLock.isEnabled)
    let currencyRow = SettingsMenuRow("Primary currency", icon: MenuIcons.currency, colour: AppSettingsPanel.currencyPink)
    /// A deep pink, lighter in Dark to read as strongly.
    static let currencyPink = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(displayP3Red: 232/255, green: 72/255, blue: 132/255, alpha: 1)
        : UIColor(displayP3Red: 196/255, green: 30/255, blue: 98/255, alpha: 1) }
    let aiOptionsRow = SettingsNavigationRow("AI Options")
    let privacyRow = SettingsNavigationRow("Privacy Policy")
    private let scroll = UIScrollView()
    var buttons: [UIButton] { [closeButton, syncRow, autoplayRow, incognitoLockRow, currencyRow.button, aiOptionsRow, privacyRow] }
    private let detail = UILabel()
    private let autoplayDetail = UILabel()
    private let incognitoLockDetail = UILabel()
    private let currencyDetail = UILabel()
    var onSyncChanged: ((Bool) -> Void)?
    var onAutoplayChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.closeButton.accessibilityLabel = "Back to Site settings"
        addSubview(header)
        addSubview(scroll)
        scroll.alwaysBounceVertical = false
        currencyRow.layer.cornerCurve = .continuous
        currencyRow.layer.cornerRadius = MenuPanel.cornerRadius
        currencyRow.clipsToBounds = true
        scroll.addSubview(currencyRow)
        scroll.addSubview(aiOptionsRow)
        scroll.addSubview(privacyRow)
        for row in [syncRow, autoplayRow, incognitoLockRow] {
            row.layer.cornerCurve = .continuous
            row.layer.cornerRadius = MenuPanel.cornerRadius
            row.clipsToBounds = true
            row.toggle.onTintColor = SiteSettingsPanel.switchBlue
            scroll.addSubview(row)
        }
        syncRow.onChanged = { [weak self] enabled in self?.onSyncChanged?(enabled) }
        autoplayRow.onChanged = { [weak self] enabled in self?.onAutoplayChanged?(enabled) }
        incognitoLockRow.onChanged = { enabled in IncognitoLock.isEnabled = enabled }
        for label in [detail, autoplayDetail, incognitoLockDetail, currencyDetail] {
            label.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            scroll.addSubview(label)
        }
        detail.text = "Tabs sync automatically through your iCloud account."
        autoplayDetail.text = "Videos play automatically within the page. Turn off to tap Play instead."
        autoplayRow.toggle.accessibilityHint = autoplayDetail.text
        incognitoLockDetail.text = "Uses Face ID to lock your incognito tabs."
        incognitoLockRow.toggle.accessibilityHint = incognitoLockDetail.text
        currencyDetail.text = "Amounts you select in other currencies are converted to this one."
        currencyRow.button.accessibilityHint = currencyDetail.text
        showCurrency()
    }

    /// The person's currency, and every one there's a rate for to choose from instead.
    func showCurrency() {
        let primary = PrimaryCurrency.code()
        let codes = ExchangeRateStore.shared.rates.map { Array($0.rates.keys) } ?? Locale.commonISOCurrencyCodes
        let currencies = CurrencyAmounts.currencies(codes)
        // The most traded first, then every other by name, each in a section of its own.
        currencyRow.show(primary, menu: UIMenu(options: .singleSelection, children: [currencies.popular, currencies.others].map { group in
            UIMenu(options: .displayInline, children: group.map { currency in
                let action = UIAction(title: currency.name, state: currency.code == primary ? .on : .off) { [weak self] _ in
                    PrimaryCurrency.set(currency.code)
                    self?.showCurrency()
                }
                action.subtitle = currency.code
                return action
            })
        }))
        ExchangeRateStore.shared.refreshIfStale()
    }

    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard scroll.bounds.contains(convert(point, to: scroll)) else { return true }
        return velocity.y > abs(velocity.x)
            && scroll.contentOffset.y <= -scroll.adjustedContentInset.top+1
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAutoplay(enabled: Bool) {
        autoplayRow.toggle.setOn(enabled, animated: window != nil)
        autoplayRow.updateIcon()
    }

    func showSync(enabled: Bool, message: String) {
        syncRow.toggle.setOn(enabled, animated: window != nil)
        syncRow.updateIcon()
        detail.text = message
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        scroll.frame = CGRect(x: 0, y: PanelHeader.height, width: bounds.width, height: max(0,bounds.height-PanelHeader.height))
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        syncRow.bounds = CGRect(x: 0, y: 0, width: width, height: SiteSettingsPanel.rowHeight)
        syncRow.center = CGPoint(x: bounds.midX, y: MenuPanel.top+SiteSettingsPanel.rowHeight/2)
        let textWidth = max(0, width-32)
        let size = detail.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        detail.frame = CGRect(x: syncRow.frame.minX+16, y: syncRow.frame.maxY+12, width: textWidth, height: size.height)
        autoplayRow.bounds = syncRow.bounds
        autoplayRow.center = CGPoint(x: bounds.midX, y: detail.frame.maxY+SiteSettingsPanel.groupGap+SiteSettingsPanel.rowHeight/2)
        let autoplaySize = autoplayDetail.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        autoplayDetail.frame = CGRect(x: detail.frame.minX, y: autoplayRow.frame.maxY+12, width: textWidth, height: autoplaySize.height)
        incognitoLockRow.bounds = syncRow.bounds
        incognitoLockRow.center = CGPoint(x: bounds.midX, y: autoplayDetail.frame.maxY+SiteSettingsPanel.groupGap+SiteSettingsPanel.rowHeight/2)
        let lockSize = incognitoLockDetail.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        incognitoLockDetail.frame = CGRect(x: detail.frame.minX, y: incognitoLockRow.frame.maxY+12, width: textWidth, height: lockSize.height)
        currencyRow.frame = CGRect(x: syncRow.frame.minX, y: incognitoLockDetail.frame.maxY+SiteSettingsPanel.groupGap,
                                   width: width, height: SiteSettingsPanel.rowHeight)
        let currencySize = currencyDetail.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        currencyDetail.frame = CGRect(x: detail.frame.minX, y: currencyRow.frame.maxY+12, width: textWidth, height: currencySize.height)
        aiOptionsRow.frame = CGRect(x: syncRow.frame.minX, y: currencyDetail.frame.maxY+SiteSettingsPanel.groupGap,
                                    width: width, height: SettingsNavigationRow.height)
        privacyRow.frame = aiOptionsRow.frame.offsetBy(dx: 0, dy: SettingsNavigationRow.height+12)
        scroll.contentSize = CGSize(width: bounds.width, height: privacyRow.frame.maxY+12)
    }
}
