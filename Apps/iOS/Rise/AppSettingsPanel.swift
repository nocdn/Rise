import UIKit

/// App-wide settings, with matching toggle rows and explanatory subtitles.
final class AppSettingsPanel: UIView {
    static var height: CGFloat { SiteSettingsPanel.height+338 }
    private let header = PanelHeader(title: "Settings")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let syncRow = SettingsToggleRow("Sync tabs with iCloud", icon: MenuIcons.syncTabs, colour: .systemBlue, iconSide: 26)
    let autoplayRow = SettingsToggleRow("Autoplay videos", icon: MenuIcons.video, colour: .systemGreen, iconSide: 26)
    let incognitoLockRow = SettingsToggleRow("Locked incognito mode", icon: MenuIcons.lockedIncognito, colour: .systemPurple,
                                             iconSide: 26, on: IncognitoLock.isEnabled)
    let ai = AISettingsGroup()
    let privacyRow = SettingsNavigationRow("Privacy Policy")
    let popupDiagnosticsRow = SettingsNavigationRow("Share popup diagnostics")
    private let scroll = UIScrollView()
    var buttons: [UIButton] { [closeButton, syncRow, autoplayRow, incognitoLockRow, privacyRow, popupDiagnosticsRow]+ai.buttons }
    var keyboardInset: CGFloat = 0 {
        didSet { setNeedsLayout(); layoutIfNeeded(); revealKey() }
    }
    private let detail = UILabel()
    private let autoplayDetail = UILabel()
    private let incognitoLockDetail = UILabel()
    var onSyncChanged: ((Bool) -> Void)?
    var onAutoplayChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.closeButton.accessibilityLabel = "Back to Site settings"
        addSubview(header)
        addSubview(scroll)
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = false
        scroll.addSubview(ai)
        scroll.addSubview(privacyRow)
        scroll.addSubview(popupDiagnosticsRow)
        popupDiagnosticsRow.accessibilityHint = "Share recent popup decisions and reasons to diagnose a broken website. URL query values are redacted."
        ai.onChanged = { [weak self] in self?.setNeedsLayout() }
        ai.onEditing = { [weak self] in self?.revealKey() }
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
        for label in [detail, autoplayDetail, incognitoLockDetail] {
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
    }

    private func revealKey() {
        guard ai.keyField.isFirstResponder else { return }
        scroll.scrollRectToVisible(ai.keyField.convert(ai.keyField.bounds, to: scroll).insetBy(dx: 0, dy: -16), animated: true)
    }

    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard scroll.bounds.contains(convert(point, to: scroll)) else { return true }
        return !ai.keyField.isFirstResponder && velocity.y > abs(velocity.x)
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
        scroll.contentInset.bottom = keyboardInset
        scroll.verticalScrollIndicatorInsets.bottom = keyboardInset
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
        ai.frame = CGRect(x: syncRow.frame.minX, y: incognitoLockDetail.frame.maxY+SiteSettingsPanel.groupGap,
                          width: width, height: ai.height(for: width))
        privacyRow.frame = CGRect(x: ai.frame.minX, y: ai.frame.maxY+SiteSettingsPanel.groupGap,
                                  width: width, height: SiteSettingsPanel.rowHeight)
        popupDiagnosticsRow.frame = CGRect(x: privacyRow.frame.minX, y: privacyRow.frame.maxY+8,
            width: width, height: SiteSettingsPanel.rowHeight)
        scroll.contentSize = CGSize(width: bounds.width, height: popupDiagnosticsRow.frame.maxY+12)
    }
}
