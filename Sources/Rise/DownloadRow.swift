import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// One download: the file's icon beside its name, with its size (or progress) below.
/// Clicking a finished download opens it in its default app. While highlighted (by the
/// pointer or the arrow keys), an eye previews it in Quick Look, for files Quick Look can
/// show, and an X clears it from the list.
final class DownloadRow: NSView {
    enum Pointer { case entered, exited, pressed }
    let item: DownloadList.Item
    private let icon = NSImageView(), title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    let progressRing = DownloadProgressRing()
    private let upper = RowFill(edge: .top), lower = RowFill(edge: .bottom)
    private(set) var previewButton: ChromeButton!, removeButton: ChromeButton!
    private(set) var pauseButton: DownloadPauseButton!
    private var pressing = false
    var isHighlighted = false { didSet { if isHighlighted != oldValue { restyle() } } }
    /// Corner radii; the list's first and last rows follow the popover's rounder corners.
    var topRadius: CGFloat = 8 { didSet { needsLayout = true } }
    var bottomRadius: CGFloat = 8 { didSet { needsLayout = true } }
    var open: ((URL) -> Void)?, preview: ((URL) -> Void)?, remove: ((UUID) -> Void)?
    var togglePause: ((UUID) -> Void)?, cancel: ((UUID) -> Void)?
    var reveal: ((URL) -> Void)?, deleteFromDisk: ((UUID) -> Void)?
    var pointer: ((DownloadRow, Pointer) -> Void)?
    static let height: CGFloat = 44, buttonSize: CGFloat = 28

    init(item: DownloadList.Item) {
        self.item = item
        super.init(frame: .zero)
        previewButton = ChromeButton(symbol: "eye", title: "Quick Look") { [weak self] in self?.performPreview() }
        previewButton.image = TablerIcon.image(TablerIcon.eye, size: 18, description: "Quick Look")
        pauseButton = DownloadPauseButton { [weak self] in self?.performPause() }
        removeButton = ChromeButton(symbol: "xmark", size: 15, title: "Remove from List") { [weak self] in self?.performRemove() }
        for button in [previewButton!, removeButton!, pauseButton!] { button.layer?.cornerRadius = 7; button.layer?.cornerCurve = .continuous }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13); title.textColor = .labelColor; title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        [upper, lower, icon, progressRing, title, detail, previewButton, pauseButton, removeButton].forEach(addSubview)
        update()
        setAccessibilityElement(true); setAccessibilityRole(.button)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    var isFinished: Bool { item.isFinished }
    /// Quick Look shows documents, media, text and fonts; anything else would only get a file icon.
    var canPreview: Bool {
        guard isFinished, let type = UTType(filenameExtension: item.record.url.pathExtension) else { return false }
        let previewable: [UTType] = [.image, .audiovisualContent, .pdf, .text, .rtfd, .flatRTFD, .font, .threeDContent, .presentation, .spreadsheet]
        let documents = ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages", "com.apple.pages.pages"]
        return previewable.contains { type.conforms(to: $0) } || documents.contains { UTType($0).map(type.conforms) ?? false }
    }
    func performPreview() { if canPreview { preview?(item.record.url) } }
    func performRemove() { if isFinished { remove?(item.record.id) } else { cancel?(item.record.id) } }
    func performPause() { if item.canTogglePause { togglePause?(item.record.id) } }
    func performOpen() { if isFinished { open?(item.record.url) } }
    func update() {
        let url = item.record.url
        title.stringValue = url.lastPathComponent
        if isFinished, icon.image == nil {
            if FileManager.default.fileExists(atPath: url.path) { icon.image = NSWorkspace.shared.icon(forFile: url.path) }
            else { icon.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data) }
        }
        icon.isHidden = !isFinished; progressRing.isHidden = isFinished
        progressRing.update(fraction: item.fraction, paused: item.state != .downloading)
        if isFinished { detail.stringValue = Self.detail(for: url, progress: nil) }
        else {
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            let size = item.totalBytes > 0 ? "\(format(item.receivedBytes)) of \(format(item.totalBytes))" : "\(format(item.receivedBytes)) downloaded"
            let status: String
            switch item.state {
            case .paused, .pausing: status = "Paused"
            case .resuming: status = "Resuming…"
            case .cancelling: status = "Cancelling…"
            default: status = "\(format(Int64(item.bytesPerSecond)))/s"
            }
            detail.stringValue = "\(size) · \(status)"
        }
        pauseButton.update(paused: item.showsResume); pauseButton.isEnabled = item.canTogglePause
        let removeTitle = isFinished ? "Remove from List" : "Cancel Download"
        removeButton.toolTip = removeTitle; removeButton.setAccessibilityLabel(removeTitle)
        removeButton.isEnabled = item.state != .cancelling
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
        var actions: [NSAccessibilityCustomAction] = []
        if canPreview { actions.append(NSAccessibilityCustomAction(name: "Quick Look") { [weak self] in self?.performPreview(); return true }) }
        if isFinished { actions.append(NSAccessibilityCustomAction(name: "Remove from List") { [weak self] in self?.performRemove(); return true }) }
        else {
            actions.append(NSAccessibilityCustomAction(name: item.showsResume ? "Resume Download" : "Pause Download") { [weak self] in self?.performPause(); return true })
            actions.append(NSAccessibilityCustomAction(name: "Cancel Download") { [weak self] in self?.performRemove(); return true })
        }
        setAccessibilityCustomActions(actions)
        restyle()
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
        progressRing.frame = icon.frame
        let side = Self.buttonSize, y = (bounds.height-side)/2
        removeButton.frame = NSRect(x: bounds.width-side-6, y: y, width: side, height: side)
        previewButton.frame = NSRect(x: removeButton.frame.minX-(canPreview ? side : 0), y: y, width: side, height: side)
        pauseButton.frame = NSRect(x: removeButton.frame.minX-side, y: y, width: side, height: side)
        let x: CGFloat = 45
        let firstControl = !pauseButton.isHidden ? pauseButton! : previewButton.isHidden ? removeButton! : previewButton!
        let trailing = removeButton.isHidden ? 10 : bounds.width-firstControl.frame.minX+2
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
        for button in [previewButton!, removeButton!, pauseButton!] {
            button.contentTintColor = .secondaryLabelColor
            button.hoverColor = buttonHover.flatMap(NSColor.init(cgColor:)) ?? button.hoverColor
        }
        let showsControls = isHighlighted || (!isFinished && item.showsResume)
        removeButton.isHidden = !showsControls
        previewButton.isHidden = !isFinished || removeButton.isHidden || !canPreview
        pauseButton.isHidden = isFinished || !showsControls
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); restyle()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        pointer?(self, .pressed)
        let menu = NSMenu()
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: "")
        reveal.target = self; menu.addItem(reveal)
        if isFinished {
            let delete = NSMenuItem(title: "Delete from disk", action: #selector(deleteFile), keyEquivalent: "")
            delete.target = self; menu.addItem(delete)
        }
        let rename = NSMenuItem(title: "Smart Rename", action: #selector(smartRename), keyEquivalent: "")
        rename.target = self; menu.addItem(rename)
        return menu
    }
    @objc private func revealFile() { reveal?(item.record.url) }
    @objc private func deleteFile() { if isFinished { deleteFromDisk?(item.record.id) } }
    @objc private func smartRename() {}
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
