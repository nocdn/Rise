import UIKit

/// UIKit owns the two-finger range gesture, reversal and edge autoscrolling. Cells
/// only host Rise's existing rows; selection never introduces UIKit's editing chrome.
final class DownloadsList: PanelSelectionList, UICollectionViewDataSource {
    private var rows: [DownloadsPanel.Row] = []

    init() {
        super.init(rowHeight: DownloadsPanel.rowHeight)
        dataSource = self
        register(Cell.self, forCellWithReuseIdentifier: "Download")
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ rows: [DownloadsPanel.Row]) {
        self.rows = rows
        UIView.performWithoutAnimation { reloadData(); layoutIfNeeded() }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "Download", for: indexPath) as! Cell
        cell.show(rows[indexPath.item], last: indexPath.item == rows.count-1)
        return cell
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
