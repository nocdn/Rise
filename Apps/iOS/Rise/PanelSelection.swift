import UIKit

/// Native two-finger range selection, including reversal and edge autoscrolling,
/// without UIKit's table editing chrome. Both History and Downloads host their own rows.
class PanelSelectionList: UICollectionView, UICollectionViewDelegateFlowLayout {
    let rowHeight: CGFloat
    private(set) var isRangeSelecting = false
    var rangeBegan: (() -> Void)?
    var rangeEnded: (() -> Void)?
    var selectionChanged: ((Int, Bool) -> Void)?

    init(rowHeight: CGFloat) {
        self.rowHeight = rowHeight
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        super.init(frame: .zero, collectionViewLayout: layout)
        delegate = self
        allowsMultipleSelection = true
        allowsSelectionDuringEditing = true
        allowsMultipleSelectionDuringEditing = true
        contentInsetAdjustmentBehavior = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    func syncSelection(_ indices: Set<Int>) {
        for path in indexPathsForSelectedItems ?? [] where !indices.contains(path.item) {
            deselectItem(at: path, animated: false)
        }
        for index in indices where index >= 0 && index < numberOfItems(inSection: 0) {
            selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: bounds.width, height: rowHeight)
    }
    override func layoutSubviews() {
        if let layout = collectionViewLayout as? UICollectionViewFlowLayout, layout.itemSize.width != bounds.width {
            layout.itemSize = CGSize(width: bounds.width, height: rowHeight)
            layout.invalidateLayout()
        }
        super.layoutSubviews()
    }
    func collectionView(_ collectionView: UICollectionView,
                        shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0 && indexPath.item >= 0 && indexPath.item < numberOfItems(inSection: 0)
    }
    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        isRangeSelecting = true
        rangeBegan?()
    }
    func collectionViewDidEndMultipleSelectionInteraction(_ collectionView: UICollectionView) {
        isRangeSelecting = false
        rangeEnded?()
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectionChanged?(indexPath.item, true)
    }
    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        selectionChanged?(indexPath.item, false)
    }
}

/// The same check circle, blue fill and symbol replacement in both lists.
final class PanelSelectionIndicator: UIImageView {
    init() {
        super.init(image: UIImage(systemName: "circle"))
        preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        contentMode = .center
        tintColor = .tertiaryLabel
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The filled check fading out over the empty circle as it's unchecked.
    private var fading: UIImageView?
    func setChecked(_ checked: Bool, animated: Bool) {
        let image = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle")!
        let wasChecked = tintColor == SiteSettingsPanel.switchBlue
        fading?.removeFromSuperview(); fading = nil
        if checked, animated, !UIAccessibility.isReduceMotionEnabled {
            setSymbolImage(image, contentTransition: .replace)
        } else if !checked, wasChecked, animated, !UIAccessibility.isReduceMotionEnabled {
            // Unchecking shouldn't wait for the check's transition to reverse: the circle empties
            // at once and the blue check fades quickly away over it, so a swipe back feels immediate.
            let check = UIImageView(image: self.image)
            check.preferredSymbolConfiguration = preferredSymbolConfiguration
            check.contentMode = contentMode
            check.tintColor = SiteSettingsPanel.switchBlue
            check.frame = bounds
            check.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(check)
            fading = check
            self.image = image
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                check.alpha = 0
            } completion: { [weak self, weak check] _ in
                check?.removeFromSuperview()
                if self?.fading === check { self?.fading = nil }
            }
        } else { self.image = image }
        tintColor = checked ? SiteSettingsPanel.switchBlue : .tertiaryLabel
    }
}

/// The compact dots beside a panel title, with native menu presentation.
@MainActor enum PanelListMenu {
    private static let dots = UIGraphicsImageRenderer(size: CGSize(width: 12.5, height: 3)).image { context in
        UIColor.black.setFill()
        for index in 0..<3 {
            context.cgContext.fillEllipse(in: CGRect(x: CGFloat(index)*4.75, y: 0, width: 3, height: 3))
        }
    }.withRenderingMode(.alwaysTemplate)

    static func button(label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(dots, for: .normal)
        button.tintColor = .secondaryLabel
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = label
        return button
    }
}
