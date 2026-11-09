import UIKit

/// A restored page has a real destination even before WebKit commits its first document.
final class BrowserNavigationStatus: UIView {
    let spinner = UIActivityIndicatorView(style: .medium)
    let title = UILabel()
    let detail = UILabel()
    let retryButton = UIButton(type: .system)
    var retry: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = .systemBackground
        title.font = PanelHeader.font("OpenRunde-Semibold", size: 20, fallbackWeight: .semibold)
        title.textColor = .label
        detail.font = SearchPanel.font; detail.textColor = .secondaryLabel
        for label in [title, detail] { label.numberOfLines = 0; label.textAlignment = .center }
        retryButton.setTitle("Try again", for: .normal)
        retryButton.titleLabel?.font = SearchPanel.font
        retryButton.layer.cornerRadius = SearchPanel.cornerRadius
        retryButton.shrinksWhenPressed(to: SearchPanel.pressedScale, filled: true)
        retryButton.addAction(UIAction { [weak self] _ in self?.retry?() }, for: .primaryActionTriggered)
        [spinner, title, detail, retryButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(address: URL?, committed: Bool, error: Error?, stopped: Bool = false) {
        guard address != nil, !committed else { isHidden = true; spinner.stopAnimating(); return }
        isHidden = false
        let failed = error != nil
        title.text = stopped ? "Loading stopped" : failed ? "Couldn't open this page" : nil
        detail.text = stopped ? nil : error?.localizedDescription
        retryButton.setTitle(stopped ? "Reload" : "Try again", for: .normal)
        retryButton.isHidden = !failed && !stopped
        if failed || stopped { spinner.stopAnimating() } else { spinner.startAnimating() }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(320, max(0, bounds.width-48)), x = (bounds.width-width)/2
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let titleHeight = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let detailHeight = min(120, detail.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let y = max(24, bounds.midY-(titleHeight+12+detailHeight+24+44)/2)
        title.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        detail.frame = CGRect(x: x, y: title.frame.maxY+12, width: width, height: detailHeight)
        retryButton.bounds = CGRect(x: 0, y: 0, width: 140, height: 44)
        retryButton.center = CGPoint(x: bounds.midX, y: detail.frame.maxY+24+22)
    }
}
