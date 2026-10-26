import UIKit

/// App settings' AI options: the AI switch, provider and key, then a row into each feature's
/// prompt.
final class AIOptionsPanel: UIView {
    static var height: CGFloat {
        let prompts = CGFloat(AIPrompt.allCases.count)*SettingsNavigationRow.height+8
        return PanelHeader.height+MenuPanel.top+3*SiteSettingsPanel.rowHeight+64+SiteSettingsPanel.groupGap+prompts+4
    }
    private let header = PanelHeader(title: "AI Options")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let ai = AISettingsGroup()
    let promptRows = AIPrompt.allCases.map { SettingsNavigationRow($0.title) }
    private let scroll = UIScrollView()
    var buttons: [UIButton] { [closeButton]+promptRows+ai.buttons }
    var keyboardInset: CGFloat = 0 {
        didSet { setNeedsLayout(); layoutIfNeeded(); revealKey() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        header.closeButton.accessibilityLabel = "Back to Settings"
        addSubview(header)
        addSubview(scroll)
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = false
        scroll.addSubview(ai)
        promptRows.forEach(scroll.addSubview)
        ai.onChanged = { [weak self] in self?.setNeedsLayout() }
        ai.onEditing = { [weak self] in self?.revealKey() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func revealKey() {
        guard ai.keyField.isFirstResponder else { return }
        scroll.scrollRectToVisible(ai.keyField.convert(ai.keyField.bounds, to: scroll).insetBy(dx: 0, dy: -16), animated: true)
    }

    func canPullToClose(at point: CGPoint, velocity: CGPoint) -> Bool {
        guard scroll.bounds.contains(convert(point, to: scroll)) else { return true }
        return !ai.keyField.isFirstResponder && velocity.y > abs(velocity.x)
            && scroll.contentOffset.y <= -scroll.adjustedContentInset.top+1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: PanelHeader.height)
        scroll.frame = CGRect(x: 0, y: PanelHeader.height, width: bounds.width, height: max(0, bounds.height-PanelHeader.height))
        scroll.contentInset.bottom = keyboardInset
        scroll.verticalScrollIndicatorInsets.bottom = keyboardInset
        let width = 4*MenuPanel.tileSize(width: bounds.width).width+3*MenuPanel.spacing
        let x = (bounds.width-width)/2
        ai.frame = CGRect(x: x, y: MenuPanel.top, width: width, height: ai.height(for: width))
        var y = ai.frame.maxY+SiteSettingsPanel.groupGap
        for row in promptRows {
            row.frame = CGRect(x: x, y: y, width: width, height: SettingsNavigationRow.height)
            y = row.frame.maxY
        }
        scroll.contentSize = CGSize(width: bounds.width, height: y+12)
    }
}
