import AppKit
import Quartz

/// The popover's content. It takes the keyboard, and reports pointer moves so arrow-key
/// focus can hand back to the mouse.
private final class DownloadsListView: NSView {
    var key: ((NSEvent) -> Bool)?, moved: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if key?(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), [51, 117].contains(event.keyCode), key?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { moved?() }
    var modifiers: ((NSEvent.ModifierFlags) -> Void)?
    override func flagsChanged(with event: NSEvent) { modifiers?(event.modifierFlags); super.flagsChanged(with: event) }
}

/// The archive popover: just the list of downloads. One row at a time is highlighted,
/// either under the pointer or, after an arrow key, by the keyboard, which ignores the
/// pointer until it moves. Return opens the highlighted download, Space previews it and
/// Delete clears it from the list; Command-Delete moves a completed file to the Bin.
@MainActor final class DownloadsController: NSViewController, NSPopoverDelegate {
    private let list: DownloadList
    private let stack = FlippedView(), scroll = PopoverScrollView(), listView = DownloadsListView()
    private(set) var rows: [DownloadRow] = []
    private(set) var highlightedID: UUID? { didSet { applyHighlight() } }
    private(set) var usesKeyboard = false
    /// The popover it's shown in, whose size follows its rows.
    weak var popover: NSPopover?
    /// Shift turns finished rows' X into a bin that deletes the file.
    private var shiftHeld = false { didSet { if shiftHeld != oldValue { rows.forEach { $0.deletesFromDisk = shiftHeld } } } }
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
        if let closed = notification.object as? NSPopover, closed === errorPopover {
            errorPopover = nil
            rows.forEach { $0.holdsControls = false; $0.deletesFromDisk = shiftHeld }
            return
        }
        let completion = afterClose
        afterClose = nil
        completion?()
    }
    override func loadView() {
        listView.frame = NSRect(x: 0, y: 0, width: Self.width, height: DownloadRow.height+2*Self.inset)
        listView.key = { [weak self] in self?.handle($0) ?? false }
        listView.moved = { [weak self] in self?.pointerMoved(to: NSEvent.mouseLocation) }
        listView.modifiers = { [weak self] in self?.shiftHeld = $0.contains(.shift) }
        view = listView
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.documentView = stack
        view.addSubview(scroll)
        reload()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKey(); view.window?.makeFirstResponder(listView)
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
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
        // The initial empty list still needs its layout and empty-state label.
        if !stack.subviews.isEmpty, items.map(\.record.id) == rows.map(\.item.record.id) {
            // Finished rows only need one final update when their ring disappears.
            rows.filter { !$0.isFinished || !$0.progressRing.isHidden }.forEach { $0.update() }
            return
        }
        stack.subviews.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = DownloadRow(item: item)
            row.open = { [weak self] in self?.open?($0) }
            row.preview = { [weak self] in self?.preview?($0) }
            row.remove = { [weak self] in self?.remove($0) }
            row.togglePause = { [weak self] in self?.list.togglePause($0) }
            row.cancel = { [weak self] in self?.list.cancel($0) }
            row.reveal = { [weak self] url in
                // Off to Finder: the list closes, and stays closed.
                self?.dismiss?()
                if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
            }
            row.deleteFromDisk = { [weak self] in self?.remove($0, fromDisk: true) }
            row.pointer = { [weak self] in self?.pointer($0, $1) }
            row.deletesFromDisk = shiftHeld
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
        let size = NSSize(width: Self.width, height: height+2*inset)
        if let popover, popover.isShown, popover.contentSize != size, NSEvent.modifierFlags.contains(.shift) {
            // AppKit plays a popover's resize in slow motion while Shift is down, a debugging aid
            // that left a ghost of the taller popover behind the bin, which is pressed with Shift.
            // Then the new size applies at once.
            let animates = popover.animates
            popover.animates = false; popover.contentSize = size; popover.animates = animates
        }
        preferredContentSize = size
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
    /// The row goes at once, deleting its file from disk too behind it when asked.
    private func remove(_ id: UUID, fromDisk: Bool = false) {
        let index = rows.firstIndex { $0.item.record.id == id }
        if fromDisk { list.deleteFromDisk(id) { [weak self] error in if let error { self?.showDeleteError(error, for: id) } } }
        else { list.remove(id) }
        if usesKeyboard, let index, !rows.isEmpty { highlightedID = rows[min(index, rows.count-1)].item.record.id; reveal() }
        else if !usesKeyboard { highlightRowUnderPointer() }
    }
    /// The popover out of a download's bin when its file couldn't go to the Bin, whose row is back.
    private(set) var errorPopover: NSPopover?
    private func showDeleteError(_ error: Error, for id: UUID) {
        guard view.window?.isVisible == true, let row = rows.first(where: { $0.item.record.id == id }) else { return }
        errorPopover?.close()
        highlightedID = id; row.holdsControls = true; row.deletesFromDisk = true
        // The list has grown back for the row: the popover takes its size now, so the message
        // comes out of the bin where it ends up, not where it was.
        if let popover, popover.contentSize != preferredContentSize {
            let animates = popover.animates
            popover.animates = false; popover.contentSize = preferredContentSize; popover.animates = animates
        }
        stack.scrollToVisible(row.frame); view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self, weak row] in
            guard let self, let row, row.superview != nil, self.view.window?.isVisible == true else { return }
            self.presentDeleteError(error, from: row)
        }
    }
    private func presentDeleteError(_ error: Error, from row: DownloadRow) {
        let label = NSTextField(wrappingLabelWithString: Self.deleteFailure(error))
        label.font = .systemFont(ofSize: NSFont.systemFontSize); label.textColor = Self.errorRed
        label.preferredMaxLayoutWidth = 240
        let size = label.sizeThatFits(NSSize(width: 240, height: 200))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: ceil(size.width)+24, height: ceil(size.height)+16))
        label.frame = NSRect(x: 12, y: 8, width: ceil(size.width), height: ceil(size.height)); content.addSubview(label)
        let controller = NSViewController(); controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = controller; popover.contentSize = content.frame.size
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        errorPopover = popover
        let button = row.removeButton!
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.errorDuration) { [weak popover] in popover?.close() }
    }
    static let errorDuration: TimeInterval = 6
    /// The system's red in Light; in Dark, a lighter coral that reads clearly on the dark popover.
    static let errorRed = NSColor(name: "RiseDownloadError") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.50, blue: 0.47, alpha: 1) : .systemRed
    }
    /// What went wrong, in a line: why the file couldn't go to the Bin.
    static func deleteFailure(_ error: Error) -> String {
        let error = error as NSError, underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : error.domain == NSPOSIXErrorDomain ? error.code : nil
        let reason: String
        if [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) && error.domain == NSCocoaErrorDomain
            || posix == Int(EACCES) || posix == Int(EPERM) {
            reason = "Rise isn’t allowed to move it."
        } else if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteVolumeReadOnlyError || posix == Int(EROFS) {
            reason = "Its disk is read-only."
        } else if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            reason = "It’s no longer there."
        } else {
            reason = error.localizedFailureReason ?? error.localizedDescription
        }
        return "Couldn’t move it to the Bin. "+reason
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
        let row = highlightedIndex.map { rows[$0] }
        if modifiers == .command, [51, 117].contains(event.keyCode) {
            row?.performDeleteFromDisk()
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125: move(by: 1)
        case 126: move(by: -1)
        case 36, 76: row?.performOpen()
        case 49: if row?.isFinished == true { row?.performPreview() } else { row?.performPause() }
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
        reloadDownloadsList = { [weak controller] in controller?.reload() }
        downloadsPopover.contentViewController = controller; controller.popover = downloadsPopover
        downloadsPopover.delegate = controller
        if let id { controller.focus(id) }
        showFromSidebarCorner(downloadsPopover)
    }
    /// From the sidebar's downloads button.
    func showFromSidebarCorner(_ popover: NSPopover) {
        let button = sidebar.archiveButton
        if isSidebarShown && !sidebar.isHidden && button.window != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .minY : .maxY)
        } else {
            // With the sidebar collapsed, point at the corner where downloads land on their tile.
            let side = DownloadFlight.tileSize, margin = DownloadFlight.tileMargin
            let tile = NSRect(x: margin, y: root.isFlipped ? root.bounds.height-margin-side : margin, width: side, height: side)
            popover.show(relativeTo: tile, of: root, preferredEdge: root.isFlipped ? .minY : .maxY)
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
