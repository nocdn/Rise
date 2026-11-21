import UIKit

/// The favicon and title travel together, leaving a check circle in the favicon's
/// original column. Swipe motion stays on its owned container, independent of cell layout.
final class HistoryCell: UICollectionViewCell {
    static let selectionShift: CGFloat = 32
    let swipeContent = UIView()
    let row = AddressSuggestionRow()
    let checkbox = PanelSelectionIndicator()
    let checkButton = UIButton(type: .custom)
    /// Picks out the title, as Archived Tabs does the tabs its toast named.
    let glint = TextGlint()
    private(set) var isSelecting = false
    private var isChecked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        row.showsFillButton = false
        contentView.addSubview(swipeContent)
        for view in [row, checkbox, checkButton] { swipeContent.addSubview(view) }
        checkButton.isHidden = true
        checkButton.shrinksWhenPressed(to: 0.9)
        // The row itself is the single accessibility target for selection.
        checkButton.isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelecting(_ selecting: Bool, animated: Bool) {
        guard selecting != isSelecting else { return }
        layoutIfNeeded()
        isSelecting = selecting
        row.accessibilityValue = selecting ? (isChecked ? "Selected" : "Not selected") : nil
        checkButton.isHidden = !selecting
        setNeedsLayout()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            BlurCrossfade.stop(in: swipeContent)
            row.layer.removeAllAnimations()
            checkbox.alpha = selecting ? 1 : 0
            checkbox.transform = .identity
            layoutIfNeeded()
            return
        }
        BlurCrossfade.swap(from: selecting ? nil : checkbox, to: selecting ? checkbox : nil, style: .symbol)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) { self.layoutIfNeeded() }
    }

    func setChecked(_ checked: Bool, animated: Bool) {
        isChecked = checked
        checkbox.setChecked(checked, animated: animated)
        row.accessibilityTraits = checked ? [.button, .selected] : .button
        row.accessibilityValue = isSelecting ? (checked ? "Selected" : "Not selected") : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        glint.stop()
        setSelecting(false, animated: false)
        setChecked(false, animated: false)
        transform = .identity
        swipeContent.transform = .identity
        swipeContent.alpha = 1
        row.accessibilityCustomActions = nil
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        swipeContent.bounds = contentView.bounds
        swipeContent.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let shift = isSelecting ? Self.selectionShift : 0
        let width = max(0, swipeContent.bounds.width-2*SearchPanel.inset-shift)
        row.bounds = CGRect(x: 0, y: 0, width: width, height: SearchPanel.rowHeight)
        row.center = CGPoint(x: SearchPanel.inset+shift+width/2, y: swipeContent.bounds.midY)
        checkbox.bounds = CGRect(x: 0, y: 0, width: 22, height: 32)
        checkbox.center = CGPoint(x: SearchPanel.inset+SearchPanel.rowIndent+11, y: swipeContent.bounds.midY)
        checkButton.bounds = CGRect(x: 0, y: 0, width: 44, height: SearchPanel.rowHeight)
        checkButton.center = checkbox.center
    }
}
