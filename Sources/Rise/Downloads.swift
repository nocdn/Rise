import AppKit
import Quartz
import UniformTypeIdentifiers
import WebKit

struct DownloadRecord: Codable, Equatable {
    var id = UUID()
    var path: String
    var date = Date()
    var url: URL { URL(fileURLWithPath: path) }
}

/// Downloads, newest first. Finished ones persist beside the session; ones in progress
/// carry their WebKit progress until they finish or fail.
@MainActor final class DownloadList {
    struct Item { var record: DownloadRecord; var progress: Progress? }
    private(set) var items: [Item] = []
    private let storeURL: URL
    private var observations: [UUID: NSKeyValueObservation] = [:]
    var onChange: (() -> Void)?
    static let limit = 200

    init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL), let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            items = records.map { Item(record: $0, progress: nil) }
        }
    }
    /// What the popover lists: downloads in progress, and finished files still where they were saved.
    var visible: [Item] {
        items.filter { $0.progress != nil || FileManager.default.fileExists(atPath: $0.record.path) }
    }
    @discardableResult func begin(_ url: URL, progress: Progress?) -> UUID {
        let record = DownloadRecord(path: url.path)
        items.insert(Item(record: record, progress: progress ?? Progress()), at: 0)
        observations[record.id] = progress?.observe(\.completedUnitCount) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
        onChange?()
        return record.id
    }
    func finish(_ id: UUID) {
        observations[id] = nil
        guard let index = items.firstIndex(where: { $0.record.id == id }) else { return }
        items[index].progress = nil
        save(); onChange?()
    }
    /// Clears a finished download from the list; the file stays where it was saved.
    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.record.id == id }), items[index].progress == nil else { return }
        items.remove(at: index)
        save(); onChange?()
    }
    func fail(_ id: UUID) {
        observations[id] = nil
        items.removeAll { $0.record.id == id }
        onChange?()
    }
    private func save() {
        let records = items.filter { $0.progress == nil }.prefix(Self.limit).map(\.record)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(records)).write(to: storeURL, options: .atomic)
        } catch { NSLog("Rise downloads save failed: %@", error.localizedDescription) }
    }
}

/// One download: the file's icon beside its name, with its size (or progress) below.
/// Clicking a finished download opens it in its default app. While highlighted (by the
/// pointer or the arrow keys), an eye previews it in Quick Look, for files Quick Look can
/// show, and an X clears it from the list.
final class DownloadRow: NSView {
    enum Pointer { case entered, exited, pressed }
    let item: DownloadList.Item
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    private let upper = RowFill(edge: .top), lower = RowFill(edge: .bottom)
    private(set) var previewButton: ChromeButton!, removeButton: ChromeButton!
    private var pressing = false
    var isHighlighted = false { didSet { if isHighlighted != oldValue { restyle() } } }
    /// Corner radii; the list's first and last rows follow the popover's rounder corners.
    var topRadius: CGFloat = 8 { didSet { needsLayout = true } }
    var bottomRadius: CGFloat = 8 { didSet { needsLayout = true } }
    var open: ((URL) -> Void)?, preview: ((URL) -> Void)?, remove: ((UUID) -> Void)?
    var pointer: ((DownloadRow, Pointer) -> Void)?
    static let height: CGFloat = 44, buttonSize: CGFloat = 28

    init(item: DownloadList.Item) {
        self.item = item
        super.init(frame: .zero)
        previewButton = ChromeButton(symbol: "eye", title: "Quick Look") { [weak self] in self?.performPreview() }
        previewButton.image = TablerIcon.image(TablerIcon.eye, size: 18, description: "Quick Look")
        removeButton = ChromeButton(symbol: "xmark", size: 15, title: "Remove from List") { [weak self] in self?.performRemove() }
        for button in [previewButton!, removeButton!] { button.layer?.cornerRadius = 7; button.layer?.cornerCurve = .continuous }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13); title.textColor = .labelColor; title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        [upper, lower, icon, title, detail, previewButton, removeButton].forEach(addSubview)
        update()
        setAccessibilityElement(true); setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    var isFinished: Bool { item.progress == nil }
    /// Quick Look shows documents, media, text and fonts; anything else would only get a file icon.
    var canPreview: Bool {
        guard isFinished, let type = UTType(filenameExtension: item.record.url.pathExtension) else { return false }
        let previewable: [UTType] = [.image, .audiovisualContent, .pdf, .text, .rtfd, .flatRTFD, .font, .threeDContent, .presentation, .spreadsheet]
        let documents = ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages", "com.apple.pages.pages"]
        return previewable.contains { type.conforms(to: $0) } || documents.contains { UTType($0).map(type.conforms) ?? false }
    }
    func performPreview() { if canPreview { preview?(item.record.url) } }
    func performRemove() { if isFinished { remove?(item.record.id) } }
    func performOpen() { if isFinished { open?(item.record.url) } }
    func update(_ progress: Progress? = nil) {
        let url = item.record.url
        title.stringValue = url.lastPathComponent
        if FileManager.default.fileExists(atPath: url.path) { icon.image = NSWorkspace.shared.icon(forFile: url.path) }
        else { icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data) }
        detail.stringValue = Self.detail(for: url, progress: progress ?? item.progress)
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
        var actions: [NSAccessibilityCustomAction] = []
        if canPreview { actions.append(NSAccessibilityCustomAction(name: "Quick Look") { [weak self] in self?.performPreview(); return true }) }
        if isFinished { actions.append(NSAccessibilityCustomAction(name: "Remove from List") { [weak self] in self?.performRemove(); return true }) }
        setAccessibilityCustomActions(actions)
    }
    static func detail(for url: URL, progress: Progress?) -> String {
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        if let progress {
            guard progress.totalUnitCount > 0 else { return progress.completedUnitCount > 0 ? "\(format(progress.completedUnitCount)) downloaded" : "Downloading…" }
            return "\(format(progress.completedUnitCount)) of \(format(progress.totalUnitCount))"
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return format(size)
    }
    override func layout() {
        super.layout()
        upper.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height/2); upper.radius = topRadius
        lower.frame = NSRect(x: 0, y: bounds.height/2, width: bounds.width, height: bounds.height/2); lower.radius = bottomRadius
        icon.frame = NSRect(x: 8, y: (bounds.height-32)/2, width: 32, height: 32)
        let side = Self.buttonSize, y = (bounds.height-side)/2
        removeButton.frame = NSRect(x: bounds.width-side-6, y: y, width: side, height: side)
        previewButton.frame = NSRect(x: removeButton.frame.minX-(canPreview ? side : 0), y: y, width: side, height: side)
        let x: CGFloat = 45
        let trailing = removeButton.isHidden ? 10 : bounds.width-(previewButton.isHidden ? removeButton : previewButton).frame.minX+2
        let width = max(0, bounds.width-x-trailing)
        title.frame = NSRect(x: x, y: 6, width: width, height: 17)
        detail.frame = NSRect(x: x, y: 23, width: width, height: 14)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { pointer?(self, .entered) }
    override func mouseExited(with event: NSEvent) { pressing = false; restyle(); pointer?(self, .exited) }
    override func mouseDown(with event: NSEvent) { pointer?(self, .pressed); pressing = true; restyle() }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressing = false; restyle()
        if inside { performOpen() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isFinished else { return false }
        performOpen(); return true
    }
    /// The highlight changes immediately, without fading.
    private func restyle() {
        let alpha: CGFloat = pressing ? 0.11 : isHighlighted ? 0.06 : 0
        var background: CGColor?, buttonHover: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            buttonHover = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
        upper.color = background; lower.color = background
        for button in [previewButton!, removeButton!] {
            button.contentTintColor = .secondaryLabelColor
            button.hoverColor = buttonHover.flatMap(NSColor.init(cgColor:)) ?? button.hoverColor
        }
        removeButton.isHidden = !isHighlighted || !isFinished
        previewButton.isHidden = removeButton.isHidden || !canPreview
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); restyle()
    }
}

/// Half of a row's highlight. Its rounded rectangle overhangs the hidden edge so only the
/// corners on its own edge show, which lets a row's top and bottom corners differ while
/// keeping continuous curves.
private final class RowFill: FlippedView {
    enum Edge { case top, bottom }
    private let edge: Edge, shape = NSView()
    var radius: CGFloat = 8 { didSet { needsLayout = true } }
    var color: CGColor? {
        didSet { CATransaction.begin(); CATransaction.setDisableActions(true); shape.layer?.backgroundColor = color; CATransaction.commit() }
    }
    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        shape.wantsLayer = true; shape.layer?.cornerCurve = .continuous
        addSubview(shape)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let overhang = radius+1
        shape.frame = NSRect(x: 0, y: edge == .top ? 0 : -overhang, width: bounds.width, height: bounds.height+overhang)
        shape.layer?.cornerRadius = radius
    }
}

/// The popover's content. It takes the keyboard, and reports pointer moves so arrow-key
/// focus can hand back to the mouse.
private final class DownloadsListView: NSView {
    var key: ((NSEvent) -> Bool)?, moved: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if key?(event) != true { super.keyDown(with: event) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { moved?() }
}

/// The archive popover: just the list of downloads. One row at a time is highlighted,
/// either under the pointer or, after an arrow key, by the keyboard, which ignores the
/// pointer until it moves. Return opens the highlighted download, Space previews it and
/// Delete clears it from the list.
@MainActor final class DownloadsController: NSViewController, NSPopoverDelegate {
    private let list: DownloadList
    private let stack = FlippedView(), scroll = NSScrollView(), listView = DownloadsListView()
    private(set) var rows: [DownloadRow] = []
    private(set) var highlightedID: UUID? { didSet { applyHighlight() } }
    private(set) var usesKeyboard = false
    /// Where the pointer was when the keyboard took over, so only a real move hands back.
    private var keyboardPointer = NSPoint.zero
    var open: ((URL) -> Void)?, preview: ((URL) -> Void)?, dismiss: (() -> Void)?
    fileprivate var afterClose: (() -> Void)?
    static let width: CGFloat = 300, inset: CGFloat = 6, visibleRows = 5
    /// Concentric with the popover's corners, which are about 18 pt, across the inset.
    static let outerRadius: CGFloat = 12

    init(list: DownloadList) { self.list = list; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    func popoverDidClose(_ notification: Notification) {
        let completion = afterClose
        afterClose = nil
        completion?()
    }
    override func loadView() {
        listView.frame = NSRect(x: 0, y: 0, width: Self.width, height: DownloadRow.height+2*Self.inset)
        listView.key = { [weak self] in self?.handle($0) ?? false }
        listView.moved = { [weak self] in self?.pointerMoved(to: NSEvent.mouseLocation) }
        view = listView
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.documentView = stack
        view.addSubview(scroll)
        reload()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKey(); view.window?.makeFirstResponder(listView)
        // Only now is the popover in place, so only now can a row be under the pointer.
        if usesKeyboard { reveal() } else { highlightRowUnderPointer() }
    }
    /// Restoring a preview keeps its row selected until the pointer really moves.
    func focus(_ id: UUID) {
        loadViewIfNeeded()
        guard rows.contains(where: { $0.item.record.id == id }) else { return }
        usesKeyboard = true; keyboardPointer = NSEvent.mouseLocation
        highlightedID = id
        reveal()
    }
    /// Rebuilds the rows when downloads come or go; otherwise refreshes their progress.
    func reload() {
        let items = list.visible
        if items.map(\.record.id) == rows.map(\.item.record.id), items.map({ $0.progress == nil }) == rows.map({ $0.item.progress == nil }) {
            for (row, item) in zip(rows, items) { row.update(item.progress) }
            return
        }
        stack.subviews.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = DownloadRow(item: item)
            row.open = { [weak self] in self?.open?($0) }
            row.preview = { [weak self] in self?.preview?($0) }
            row.remove = { [weak self] in self?.remove($0) }
            row.pointer = { [weak self] in self?.pointer($0, $1) }
            return row
        }
        rows.forEach(stack.addSubview)
        let inset = Self.inset, rowWidth = Self.width-2*inset
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: inset, y: CGFloat(index)*DownloadRow.height, width: rowWidth, height: DownloadRow.height)
            row.topRadius = index == 0 ? Self.outerRadius : 8
            row.bottomRadius = index == rows.count-1 ? Self.outerRadius : 8
        }
        let content = CGFloat(max(1, rows.count))*DownloadRow.height
        let height = min(content, CGFloat(Self.visibleRows)*DownloadRow.height)
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: content)
        // Padding sits outside the scrolling viewport so exactly five rows fit,
        // without a sliver of a sixth showing through the bottom inset.
        scroll.frame = NSRect(x: 0, y: inset, width: Self.width, height: height)
        preferredContentSize = NSSize(width: Self.width, height: height+2*inset)
        if !rows.contains(where: { $0.item.record.id == highlightedID }) { highlightedID = nil }
        applyHighlight()
        if rows.isEmpty {
            let empty = NSTextField(labelWithString: "No downloads yet")
            empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor; empty.alignment = .center
            empty.frame = NSRect(x: inset, y: (DownloadRow.height-17)/2, width: rowWidth, height: 17)
            stack.addSubview(empty)
        }
    }
    private var highlightedIndex: Int? { rows.firstIndex { $0.item.record.id == highlightedID } }
    private func applyHighlight() { rows.forEach { $0.isHighlighted = $0.item.record.id == highlightedID } }

    private func pointer(_ row: DownloadRow, _ event: DownloadRow.Pointer) {
        switch event {
        case .pressed: usesKeyboard = false; highlightedID = row.item.record.id
        case .entered where !usesKeyboard: highlightedID = row.item.record.id
        case .exited where !usesKeyboard && highlightedID == row.item.record.id: highlightedID = nil
        default: break
        }
    }
    /// The first real pointer move after arrow keys hands the highlight back to the pointer.
    func pointerMoved(to location: NSPoint) {
        guard usesKeyboard, location != keyboardPointer else { return }
        usesKeyboard = false
        highlightRowUnderPointer(at: location)
    }
    private func highlightRowUnderPointer(at location: NSPoint = NSEvent.mouseLocation) {
        guard let window = view.window, window.isVisible else { return }
        let point = window.convertPoint(fromScreen: location)
        let clip = scroll.contentView
        guard clip.bounds.contains(clip.convert(point, from: nil)) else { highlightedID = nil; return }
        highlightedID = rows.first { $0.frame.contains(stack.convert(point, from: nil)) }?.item.record.id
    }
    private func remove(_ id: UUID) {
        let index = rows.firstIndex { $0.item.record.id == id }
        list.remove(id)
        if usesKeyboard, let index, !rows.isEmpty { highlightedID = rows[min(index, rows.count-1)].item.record.id; reveal() }
        else if !usesKeyboard { highlightRowUnderPointer() }
    }
    private func move(by step: Int) {
        guard !rows.isEmpty else { return }
        usesKeyboard = true; keyboardPointer = NSEvent.mouseLocation
        let index = highlightedIndex.map { min(max($0+step, 0), rows.count-1) } ?? (step > 0 ? 0 : rows.count-1)
        highlightedID = rows[index].item.record.id
        reveal()
    }
    private func reveal() {
        guard let index = highlightedIndex else { return }
        stack.scrollToVisible(rows[index].frame)
    }
    /// Arrow keys move the highlight; Return, Space and Delete act on it.
    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }
        let row = highlightedIndex.map { rows[$0] }
        switch event.keyCode {
        case 125: move(by: 1)
        case 126: move(by: -1)
        case 36, 76: row?.performOpen()
        case 49: row?.performPreview()
        case 51, 117: row?.performRemove()
        case 53: dismiss?()
        default: return false
        }
        return true
    }
}

@MainActor extension BrowserController {
    @objc func toggleDownloads() { showDownloads() }
    func showDownloads(focusing id: UUID? = nil) {
        if downloadsPopover.isShown { downloadsPopover.performClose(nil); return }
        let controller = DownloadsController(list: downloads)
        controller.open = { [weak self] url in
            self?.downloadsPopover.performClose(nil)
            NSWorkspace.shared.open(url)
        }
        controller.preview = { [weak self] url in self?.quickLook(url) }
        controller.dismiss = { [weak self] in self?.downloadsPopover.performClose(nil) }
        downloads.onChange = { [weak controller] in controller?.reload() }
        downloadsPopover.contentViewController = controller
        downloadsPopover.delegate = controller
        if let id { controller.focus(id) }
        let button = sidebar.archiveButton
        if sidebarVisible && !sidebar.isHidden && button.window != nil {
            downloadsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .minY : .maxY)
        } else {
            // With the sidebar collapsed, point at the corner where downloads land on their tile.
            let side = DownloadFlightView.tileSize, margin = DownloadFlightView.tileMargin
            let tile = NSRect(x: margin, y: root.isFlipped ? root.bounds.height-margin-side : margin, width: side, height: side)
            downloadsPopover.show(relativeTo: tile, of: root, preferredEdge: root.isFlipped ? .minY : .maxY)
        }
    }

    /// Let the popover finish its native closing animation before Quick Look takes key
    /// focus. Rise then answers the panel's search along the browser's responder chain.
    func quickLook(_ url: URL) {
        if downloadsPopover.isShown, let controller = downloadsPopover.contentViewController as? DownloadsController {
            controller.afterClose = { [weak self] in
                guard let self, self.window?.isVisible == true,
                      self.window?.isMainWindow == true, NSApp.isActive else { return }
                self.quickLook(url)
            }
            downloadsPopover.performClose(nil)
            return
        }
        quickLookDownloadID = downloads.visible.first { $0.record.url == url }?.record.id
        quickLookURL = url
        window?.makeKeyAndOrderFront(nil)
        guard let panel = QLPreviewPanel.shared() else { quickLookURL = nil; quickLookDownloadID = nil; return }
        if panel.isVisible { panel.updateController(); panel.reloadData() } else { panel.makeKeyAndOrderFront(nil) }
    }
}

extension BrowserController: @preconcurrency QLPreviewPanelDataSource {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil; quickLookURL = nil
        let id = quickLookDownloadID
        quickLookDownloadID = nil
        // Quick Look relinquishes control while closing. Let it finish ordering out
        // before making the popover key, and don't reopen on a switch to another window.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let id, let panel, !panel.isVisible,
                  self.window?.isVisible == true, self.window?.isMainWindow == true, NSApp.isActive,
                  !self.downloadsPopover.isShown else { return }
            self.showDownloads(focusing: id)
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { quickLookURL.map { $0 as NSURL } }
}
