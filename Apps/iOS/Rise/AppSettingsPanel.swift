import UIKit

/// App-wide settings, with room below the first row for settings added later.
final class AppSettingsPanel: UIView {
    static var height: CGFloat { SiteSettingsPanel.height+100 }
    private let header = PanelHeader(title: "Settings")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let syncRow = SettingsToggleRow("Sync tabs with iCloud", icon: MenuIcons.syncTabs, colour: .systemBlue, iconSide: 26)
    var buttons: [UIButton] { [closeButton, syncRow] }
    private let detail = UILabel()
    var onSyncChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.closeButton.accessibilityLabel = "Back to Site settings"
        addSubview(header)
        syncRow.layer.cornerCurve = .continuous
        syncRow.layer.cornerRadius = MenuPanel.cornerRadius
        syncRow.clipsToBounds = true
        syncRow.toggle.onTintColor = SiteSettingsPanel.switchBlue
        syncRow.onChanged = { [weak self] enabled in self?.onSyncChanged?(enabled) }
        addSubview(syncRow)
        detail.font = PanelHeader.font("OpenRunde-Regular", size: 13, fallbackWeight: .regular)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.text = "Tabs sync automatically through your iCloud account."
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSync(enabled: Bool, message: String) {
        syncRow.toggle.setOn(enabled, animated: window != nil)
        syncRow.updateIcon()
        detail.text = message
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        syncRow.bounds = CGRect(x: 0, y: 0, width: width, height: SiteSettingsPanel.rowHeight)
        syncRow.center = CGPoint(x: bounds.midX, y: SiteSettingsPanel.rowsTop+SiteSettingsPanel.rowHeight/2)
        let textWidth = max(0, width-32)
        let size = detail.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        detail.frame = CGRect(x: syncRow.frame.minX+16, y: syncRow.frame.maxY+12, width: textWidth, height: size.height)
    }
}
