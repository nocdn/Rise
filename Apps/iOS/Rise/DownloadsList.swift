import UIKit

/// UIKit owns the two-finger range gesture, reversal and edge autoscrolling. Cells
/// only host Rise's existing rows; selection never introduces UIKit's editing chrome.
final class DownloadsList: UICollectionView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private var rows: [DownloadsPanel.Row] = []
    private(set) var isRangeSelecting = false
    var rangeBegan: (() -> Void)?
    var rangeEnded: (() -> Void)?
    var selectionChanged: ((Int, Bool) -> Void)?

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.scrollDirection = .vertical
        super.init(frame: .zero, collectionViewLayout: layout)
        dataSource = self; delegate = self
        allowsMultipleSelection = true
        allowsSelectionDuringEditing = true
        allowsMultipleSelectionDuringEditing = true
        contentInsetAdjustmentBehavior = .never
        register(Cell.self, forCellWithReuseIdentifier: "Download")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    func reload(_ rows: [DownloadsPanel.Row]) {
        self.rows = rows
        UIView.performWithoutAnimation { reloadData(); layoutIfNeeded() }
    }

    func syncSelection(_ indices: Set<Int>) {
        for path in indexPathsForSelectedItems ?? [] where !indices.contains(path.item) {
            deselectItem(at: path, animated: false)
        }
        for index in indices where rows.indices.contains(index) {
            selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "Download", for: indexPath) as! Cell
        cell.show(rows[indexPath.item], last: indexPath.item == rows.count-1)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: bounds.width, height: DownloadsPanel.rowHeight)
    }
    override func layoutSubviews() {
        if let layout = collectionViewLayout as? UICollectionViewFlowLayout, layout.itemSize.width != bounds.width {
            layout.itemSize = CGSize(width: bounds.width, height: DownloadsPanel.rowHeight)
            layout.invalidateLayout()
        }
        super.layoutSubviews()
    }
    func collectionView(_ collectionView: UICollectionView,
                        shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        rows.indices.contains(indexPath.item)
    }
    func collectionView(_ collectionView: UICollectionView,
                        didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
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

    private final class Cell: UICollectionViewCell {
        private weak var row: DownloadsPanel.Row?
        private let divider = UIView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            divider.backgroundColor = .separator
            divider.isUserInteractionEnabled = false
            contentView.addSubview(divider)
        }
        required init?(coder: NSCoder) { fatalError() }
        func show(_ row: DownloadsPanel.Row, last: Bool) {
            if self.row !== row || row.superview !== contentView {
                if self.row?.superview === contentView { self.row?.removeFromSuperview() }
                self.row = row
                contentView.insertSubview(row, belowSubview: divider)
            }
            divider.isHidden = last
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            row?.bounds = CGRect(origin: .zero, size: contentView.bounds.size)
            row?.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
            let hairline = 1/max(1, traitCollection.displayScale)
            divider.frame = CGRect(x: 16, y: bounds.height-hairline/2, width: max(0,bounds.width-32), height: hairline)
        }
    }
}
