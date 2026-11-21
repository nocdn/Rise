import UIKit

/// Browsing history in the toolbar's expanding surface, using the address suggestions' exact rows.
/// Archived Tabs is the same list, of the tabs to bring back.
final class HistoryPanel: UIView, UICollectionViewDataSource {
    enum Content { case history, archivedTabs }
    var content = Content.history {
        didSet {
            let archived = content == .archivedTabs
            header.title = archived ? "Archived Tabs" : "History"
            closeButton.accessibilityLabel = archived ? "Close Archived Tabs" : "Close History"
            listMenuButton.accessibilityLabel = archived ? "Archived Tabs Options" : "History Options"
            empty.text = archived ? "Tabs you don't use for a while are kept here" : "No browsing history yet"
            // What Archived Tabs picked out isn't History's to show.
            glintStarts = [:]
            list.visibleCells.compactMap { $0 as? HistoryCell }.forEach { $0.glint.stop() }
        }
    }
    var archivedEntries: (() -> [HistoryEntry])?
    var removeArchived: ((Set<String>) -> Void)?
    var reopenArchived: ((String) -> Void)?
    static let extraHorizontalInset: CGFloat = 4
    let header = PanelHeader(title: "History")
    var closeButton: AnimatedSymbolButton { header.closeButton }
    let listMenuButton = PanelListMenu.button(label: "History Options")
    let list = HistoryList()
    private let empty = UILabel()
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    private var gapAnimator: UIViewPropertyAnimator?
    private var deferredReload = false
    weak var source: MobileAddressSuggestions?
    private(set) var entries: [HistoryEntry] = []
    private(set) var isSelecting = false
    private(set) var selected: Set<String> = []
    private(set) lazy var swipe = HistoryRowSwipe(list: list)
    var open: ((URL) -> Void)?
    /// When each row picked out starts to shimmer, so one scrolled into view or reused keeps its turn.
    private(set) var glintStarts: [String: CFTimeInterval] = [:]
    /// The first a moment after the panel opens, then down the list a little after each other.
    static let glintDelay: CFTimeInterval = 0.3, glintStagger: CFTimeInterval = 0.07

    override init(frame: CGRect) {
        super.init(frame: frame)
        closeButton.accessibilityLabel = "Close History"
        addSubview(header)
        header.accessory = listMenuButton
        updateListMenu()
        list.backgroundColor = .clear
        list.delaysContentTouches = false
        list.showsVerticalScrollIndicator = false
        list.register(HistoryCell.self, forCellWithReuseIdentifier: "Visit")
        list.dataSource = self
        list.panGestureRecognizer.addTarget(self, action: #selector(scrollHistory))
        list.rangeBegan = { [weak self] in self?.setSelecting(true, syncingList: false) }
        list.rangeEnded = { [weak self] in
            guard let self, deferredReload else { return }
            deferredReload = false
            reload(preservingScrollPosition: true)
        }
        list.selectionChanged = { [weak self] index, selected in
            guard let self, entries.indices.contains(index) else { return }
            guard isSelecting else { list.syncSelection([]); return }
            setSelected(entries[index].url, selected, syncingList: false)
        }
        addSubview(list)
        swipe.entry = { [weak self] index in
            guard let self, entries.indices.contains(index) else { return nil }
            return entries[index].url
        }
        swipe.commit = { [weak self] key in
            guard let self else { return }
            if content == .archivedTabs { removeArchived?([key]); return }
            guard let url = URL(string: key) else { return }
            source?.removeHistory(url)
        }
        swipe.remove = { [weak self] key, finished in self?.removeRow(key, finished: finished) }
        empty.text = "No browsing history yet"
        empty.font = SearchPanel.font
        empty.textColor = .secondaryLabel
        empty.textAlignment = .center
        empty.adjustsFontForContentSizeCategory = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Visits are already in memory. Only visible cells are constructed, even for a full history.
    func reload(preservingScrollPosition: Bool = false) {
        guard !list.isRangeSelecting else { deferredReload = true; return }
        cancelSwipe()
        let offset = list.contentOffset
        entries = (content == .archivedTabs ? archivedEntries?() ?? [] : source?.history.entries ?? []).sorted {
            $0.lastVisited == $1.lastVisited ? $0.url < $1.url : $0.lastVisited > $1.lastVisited
        }
        list.backgroundView = entries.isEmpty ? empty : nil
        selected.formIntersection(entries.map(\.url))
        if entries.isEmpty { setSelecting(false, animated: false) }
        list.reloadData()
        list.layoutIfNeeded()
        list.setContentOffset(preservingScrollPosition
            ? CGPoint(x: 0, y: min(offset.y, max(0, list.contentSize.height-list.bounds.height))) : .zero, animated: false)
        syncListSelection()
        updateListMenu()
    }

    func setSelecting(_ selecting: Bool, animated: Bool = true, syncingList: Bool = true) {
        guard selecting != isSelecting else { return }
        if selecting { swipe.finishForScrolling(); cancelSwipe() }
        isSelecting = selecting
        swipe.isEnabled = !selecting
        list.isEditing = selecting
        if !selecting { selected = [] }
        for case let cell as HistoryCell in list.visibleCells {
            guard let index = list.indexPath(for: cell)?.item, entries.indices.contains(index) else { continue }
            cell.setChecked(selected.contains(entries[index].url), animated: false)
            cell.setSelecting(selecting, animated: animated && window != nil)
            configureActions(entries[index], in: cell)
        }
        if syncingList { syncListSelection() }
        updateListMenu()
    }

    func toggleAll() {
        guard isSelecting else { return }
        let all = Set(entries.map(\.url))
        selected = selected == all ? [] : all
        for case let cell as HistoryCell in list.visibleCells {
            guard let index = list.indexPath(for: cell)?.item, entries.indices.contains(index) else { continue }
            cell.setChecked(selected.contains(entries[index].url), animated: true)
        }
        syncListSelection()
        updateListMenu()
    }

    private func setSelected(_ key: String, _ selecting: Bool, syncingList: Bool = true) {
        if selecting { selected.insert(key) } else { selected.remove(key) }
        if let index = entries.firstIndex(where: { $0.url == key }),
           let cell = list.cellForItem(at: IndexPath(item: index, section: 0)) as? HistoryCell {
            cell.setChecked(selecting, animated: true)
        }
        if syncingList { syncListSelection() }
        updateListMenu()
    }

    private func syncListSelection() {
        list.syncSelection(Set(entries.indices.filter { selected.contains(entries[$0].url) }))
    }

    private func updateListMenu() {
        let count = isSelecting ? selected.count : entries.count
        let title = isSelecting ? (count == 0 ? (content == .archivedTabs ? "Select Tabs" : "Select History") : "\(count) selected")
            : count == 1 ? "1 item" : "\(count) items"
        listMenuButton.menu = UIMenu(title: title, children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.selectionMenu() ?? [])
        }])
    }

    func selectionMenu() -> [UIMenuElement] {
        guard isSelecting else {
            return [UIAction(title: "Multi Select", image: UIImage(systemName: "checkmark.circle"),
                             attributes: entries.isEmpty ? .disabled : []) { [weak self] _ in self?.setSelecting(true) }]
        }
        let all = selected.count == entries.count
        return [
            UIAction(title: all ? "Deselect All" : "Select All", image: UIImage(systemName: all ? "circle" : "checkmark.circle.fill")) {
                [weak self] _ in self?.toggleAll()
            },
            UIAction(title: "Done", image: UIImage(systemName: "checkmark")) { [weak self] _ in self?.setSelecting(false) },
            UIAction(title: "Delete Selected", image: UIImage(systemName: "trash"),
                     attributes: selected.isEmpty ? [.destructive, .disabled] : .destructive) { [weak self] _ in self?.deleteSelected() },
        ]
    }

    func deleteSelected() {
        guard isSelecting, !selected.isEmpty, !list.isRangeSelecting else { return }
        let keys = selected
        if content == .archivedTabs { removeArchived?(keys) } else { source?.removeHistory(keys.compactMap(URL.init(string:))) }
        selected = []
        removeRows(keys) { [weak self] in self?.setSelecting(false) }
    }

    func cancelSwipe() {
        swipe.cancel()
        gapAnimator?.stopAnimation(true); gapAnimator = nil
        list.visibleCells.compactMap { $0 as? HistoryCell }.forEach { $0.swipeContent.transform = .identity }
    }

    @objc private func scrollHistory(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .began else { return }
        // A new vertical scroll takes over without carrying a reused cell's old pose.
        swipe.finishForScrolling()
        cancelSwipe()
    }

    private func removeRow(_ key: String, finished: @escaping () -> Void) {
        removeRows([key], finished: finished)
    }

    private func removeRows(_ keys: Set<String>, finished: @escaping () -> Void) {
        let indices = entries.indices.filter { keys.contains(entries[$0].url) }
        guard let first = indices.first else { finished(); return }
        let previous = Dictionary(uniqueKeysWithValues: list.visibleCells.compactMap { cell -> (String, CGFloat)? in
            guard let row = list.indexPath(for: cell)?.item, entries.indices.contains(row) else { return nil }
            return (entries[row].url, cell.frame.minY-list.contentOffset.y)
        })
        selected.subtract(keys)
        entries.removeAll { keys.contains($0.url) }
        list.backgroundView = entries.isEmpty ? empty : nil
        UIView.performWithoutAnimation {
            list.performBatchUpdates { list.deleteItems(at: indices.map { IndexPath(item: $0, section: 0) }) }
            list.layoutIfNeeded()
        }
        syncListSelection()
        updateListMenu()
        guard !UIAccessibility.isReduceMotionEnabled else { finished(); return }
        let cells = list.visibleCells.compactMap { $0 as? HistoryCell }
        for cell in cells {
            guard let row = list.indexPath(for: cell)?.item, entries.indices.contains(row) else { continue }
            let top = cell.frame.minY-list.contentOffset.y
            let from = previous[entries[row].url] ?? (top+(row >= first ? CGFloat(indices.count)*SearchPanel.rowHeight : 0))
            cell.swipeContent.transform = CGAffineTransform(translationX: 0, y: from-top)
        }
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.9) {
            cells.forEach { $0.swipeContent.transform = .identity }
        }
        animator.addCompletion { [weak self] _ in self?.gapAnimator = nil; finished() }
        gapAnimator = animator
        animator.startAnimation()
    }

    /// Shimmers the rows for `keys` in the accent colour, top to bottom, as Archived Tabs opens from
    /// its toast to show which tabs just went. No keys stops any still to come.
    func highlight(_ keys: Set<String>) {
        let now = CACurrentMediaTime()
        let order = entries.map(\.url).filter(keys.contains)
        glintStarts = Dictionary(order.enumerated().map { ($1, now+Self.glintDelay+Double($0)*Self.glintStagger) },
                                 uniquingKeysWith: min)
        for case let cell as HistoryCell in list.visibleCells {
            guard let index = list.indexPath(for: cell)?.item, entries.indices.contains(index) else { continue }
            cell.glint.stop()
            showGlint(entries[index], in: cell)
        }
    }
    /// A row whose turn is yet to come waits for it; one already crossing carries on.
    private func showGlint(_ entry: HistoryEntry, in cell: HistoryCell) {
        guard cell.glint.key != entry.url else { return }
        cell.glint.stop()
        guard let start = glintStarts[entry.url], start > CACurrentMediaTime() else { return }
        cell.glint.run(on: cell.row.titleLabelView, key: entry.url, at: start)
    }

    /// A favicon arriving never replaces rows, moves the scroll position, or interrupts a press.
    func refreshIcons() {
        for case let cell as HistoryCell in list.visibleCells {
            guard let index = list.indexPath(for: cell)?.item, entries.indices.contains(index) else { continue }
            show(entries[index], in: cell)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.extraHorizontalInset, width = max(0, bounds.width-2*inset)
        header.frame = CGRect(x: inset, y: 0, width: width, height: PanelHeader.height)
        let top = PanelHeader.height+SearchPanel.rowsGap
        list.frame = CGRect(x: inset, y: top, width: width, height: max(0, bounds.height-top))
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "Visit", for: indexPath) as! HistoryCell
        show(entries[indexPath.item], in: cell)
        return cell
    }
    private func show(_ entry: HistoryEntry, in cell: HistoryCell) {
        let url = URL(string: entry.url)
        let title = entry.title.isEmpty ? AddressSuggestionRow.displayAddress(entry.url) : entry.title
        cell.row.show(AddressCandidate(title: title, url: url), image: source?.icons.image(for: url))
        cell.row.addressLabel.text = nil
        cell.row.addressLabel.isHidden = true
        cell.setSelecting(isSelecting, animated: false)
        cell.setChecked(selected.contains(entry.url), animated: false)
        configureActions(entry, in: cell)
        showGlint(entry, in: cell)
    }
    private func configureActions(_ entry: HistoryEntry, in cell: HistoryCell) {
        let url = URL(string: entry.url)
        cell.row.choose = { [weak self] in
            guard let self, !swipe.isActive else { return }
            click.impactOccurred(intensity: 0.5)
            if isSelecting { setSelected(entry.url, !selected.contains(entry.url)) }
            else if content == .archivedTabs { reopenArchived?(entry.url) }
            else if let url { open?(url) }
        }
        cell.checkButton.addAction(UIAction(identifier: UIAction.Identifier("HistorySelection")) { [weak self] _ in
            guard let self, isSelecting else { return }
            click.impactOccurred(intensity: 0.5)
            setSelected(entry.url, !selected.contains(entry.url))
        }, for: .primaryActionTriggered)
        cell.row.accessibilityHint = isSelecting ? "Toggles selection" : content == .archivedTabs ? "Reopen tab" : "Open page"
        cell.row.accessibilityCustomActions = isSelecting ? nil : [UIAccessibilityCustomAction(name: content == .archivedTabs ? "Delete from Archived Tabs" : "Delete from history") { [weak self, weak cell] _ in
            guard let self, let cell else { return false }
            return swipe.delete(cell)
        }]
    }
}

/// The panel resists downward pulls at the list's top; other gestures scroll visits normally.
final class HistoryList: PanelSelectionList {
    init() { super.init(rowHeight: SearchPanel.rowHeight) }
    required init?(coder: NSCoder) { fatalError() }
    func canRubberBandPanel(velocity: CGPoint) -> Bool {
        velocity.y > abs(velocity.x) && contentOffset.y <= -adjustedContentInset.top+1
    }
}
