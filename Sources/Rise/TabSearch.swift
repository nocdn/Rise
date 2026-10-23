import AppKit

/// Searching tabs (⇧⌘A): a row at the top of the list, a tab's size and padding with no fill,
/// an icon in its favicon's place, a field and a close button that always shows. Typing leaves only
/// the tabs that match; the arrow keys light one as hovering does, and Enter or a click chooses
/// it, which ends the search with that tab selected.
@MainActor final class TabSearchRow: FlippedView, NSTextFieldDelegate {
    static let gap: CGFloat = 8
    let field = NSTextField()
    let icon = NSImageView(image: TablerIcon.image(TablerIcon.tabSearch, size: 16))
    let close: ChromeButton
    var onChange: ((String) -> Void)?
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onEnd: (() -> Void)?
    init() {
        close = ChromeButton(symbol: "xmark", size: 13, title: "Stop Searching Tabs", action: {})
        super.init(frame: .zero)
        icon.imageScaling = .scaleNone; icon.setAccessibilityElement(false)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.delegate = self; field.setAccessibilityLabel("Search tabs")
        close.actionBlock = { [weak self] in self?.onEnd?() }
        addSubview(icon); addSubview(field); addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }
    func apply(_ theme: RiseTheme) {
        icon.contentTintColor = theme.sidebarIcon
        field.textColor = TabAppearance.text(theme, selected: true)
        field.placeholderAttributedString = NSAttributedString(string: "Search tabs", attributes: [
            .font: field.font ?? .systemFont(ofSize: 13), .foregroundColor: theme.muted])
        close.contentTintColor = theme == .dark ? NSColor.white.withAlphaComponent(0.8) : theme.sidebarIcon
        close.hoverColor = theme == .dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)
    }
    // Where a tab row puts its favicon, title and close button.
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height-16)/2, width: 16, height: 16)
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 30, y: (bounds.height-height)/2, width: max(0, bounds.width-62), height: height)
        close.frame = NSRect(x: bounds.width-28.5, y: (bounds.height-24)/2-0.5, width: 24, height: 24)
    }
    func controlTextDidChange(_ notification: Notification) { onChange?(field.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): onMove?(-1)
        case #selector(NSResponder.moveDown(_:)): onMove?(1)
        case #selector(NSResponder.insertNewline(_:)): onSubmit?()
        case #selector(NSResponder.cancelOperation(_:)): onEnd?()
        default: return false
        }
        return true
    }
}

@MainActor extension SidebarView {
    var isSearchingTabs: Bool { tabSearch != nil }

    /// Opens the search row at the top of the list, as a new tab's row appears there, or goes back
    /// to it when it's open.
    func beginTabSearch() {
        if searchRow.superview !== self {
            addSubview(searchRow)
            searchRow.onChange = { [weak self] text in self?.searchTabs(for: text) }
            searchRow.onMove = { [weak self] step in self?.moveSearchFocus(by: step) }
            searchRow.onSubmit = { [weak self] in self?.chooseSearchedTab() }
            searchRow.onEnd = { [weak self] in self?.endTabSearch(); self?.onTabSearchEnded?() }
        }
        if !isSearchingTabs {
            cancelTabInteractions()
            if let appliedTheme { searchRow.apply(appliedTheme) }
            searchRow.field.stringValue = ""; searchRow.isHidden = false
            tabSearch = ""; searchFocusID = nil
            relayoutForSearch(sliding: true)
        }
        window?.makeFirstResponder(searchRow.field)
        searchRow.field.currentEditor()?.selectAll(nil)
    }
    /// Shows every tab again and closes the row, the list sliding back up under it.
    func endTabSearch() {
        guard isSearchingTabs else { return }
        tabSearch = nil; searchFocusID = nil; searchRow.isHidden = true
        if window?.firstResponder === searchRow.field.currentEditor() { window?.makeFirstResponder(nil) }
        relayoutForSearch(sliding: true)
    }
    func searchTabs(for text: String) {
        guard isSearchingTabs else { return }
        tabSearch = text
        relayoutForSearch(sliding: false)
    }
    /// The list for what's searched: the rows that match, in order, the rest hidden.
    func filterForSearch() {
        let words = (tabSearch ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ id: UUID) -> Bool {
            guard let tab = tabsByID[id] else { return false }
            var address = tab.url?.absoluteString ?? ""
            if let scheme = address.range(of: "://") { address = String(address[scheme.upperBound...]) }
            let text = tab.title + " " + address
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var rows: [NSView] = [], ids: [UUID] = []
        for (row, id) in zip(unfilteredRows, unfilteredIDs) {
            let pair = row as? SplitTabRow
            let shown = words.isEmpty || matches(id) || pair.map { matches($0.right.tabID) } == true
            row.isHidden = !shown
            if shown { rows.append(row); ids.append(id) }
        }
        displayedRows = rows; orderedIDs = ids
        if let focus = searchFocusID, !ids.contains(focus) { searchFocusID = nil }
        showSearchFocus()
    }
    func moveSearchFocus(by step: Int) {
        guard !orderedIDs.isEmpty else { return }
        let index = searchFocusID.flatMap { orderedIDs.firstIndex(of: $0) }.map { $0+step } ?? (step > 0 ? 0 : orderedIDs.count-1)
        searchFocusID = orderedIDs[min(max(index, 0), orderedIDs.count-1)]
        showSearchFocus()
        if let id = searchFocusID, let row = displayedRow(for: id) { row.scrollToVisible(row.bounds) }
    }
    /// Enter chooses the lit tab, or the first that matches what's typed.
    func chooseSearchedTab() {
        guard let id = searchFocusID ?? (tabSearch?.isEmpty == false ? orderedIDs.first : nil) else { return }
        onSelect?(id)
    }
    private func showSearchFocus() {
        for row in rows.values { row.isKeyboardFocused = false }
        guard let id = searchFocusID else { return }
        if let pair = displayedRow(for: id) as? SplitTabRow { pair.left.isKeyboardFocused = true; pair.right.isKeyboardFocused = true }
        else { rows[id]?.isKeyboardFocused = true }
    }
    /// Filtering lands at once; opening and closing slide the list as a new tab's row does.
    private func relayoutForSearch(sliding: Bool) {
        let before = scroll.frame.minY
        filterForSearch()
        relayout(animated: false)
        let shift = scroll.frame.minY-before
        if sliding, shift != 0, window != nil { PinnedLayout.slideVertically(scroll, from: -shift) }
    }
}
