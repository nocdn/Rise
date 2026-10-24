import AppKit
import UniformTypeIdentifiers

/// The camera button's captures of the whole page, as a JPEG or a PDF: saved to the captures
/// folder (Downloads unless chosen in settings) or wherever the save sheet says, copied to the
/// clipboard unless that's off, and told in a notice with a preview of the picture.
@MainActor extension BrowserController {
    static let savesCapturesKey = "savesPageCapturesAutomatically", copiesCapturesKey = "copiesPageCaptures"
    static let capturesFolderKey = "pageCapturesFolder"

    var savesCapturesAutomatically: Bool { preferences.object(forKey: Self.savesCapturesKey) as? Bool ?? true }
    func setSavesCapturesAutomatically(_ value: Bool) { preferences.set(value, forKey: Self.savesCapturesKey) }
    var copiesCaptures: Bool { preferences.object(forKey: Self.copiesCapturesKey) as? Bool ?? true }
    func setCopiesCaptures(_ value: Bool) { preferences.set(value, forKey: Self.copiesCapturesKey) }
    var capturesFolder: URL { preferences.url(forKey: Self.capturesFolderKey) ?? downloadsFolder }

    /// JPEG and PDF, in a popover from the camera button `anchor`.
    func showCaptureChoices(from anchor: NSView) {
        if capturePopover.isShown { capturePopover.performClose(nil); return }
        let content = CaptureChoicesView(theme: theme) { [weak self] format in
            self?.capturePopover.performClose(nil)
            self?.captureWholePage(format)
        } cancel: { [weak self] in self?.capturePopover.performClose(nil) }
        let controller = NSViewController(); controller.view = content
        capturePopover.contentViewController = controller
        capturePopover.behavior = .transient
        capturePopover.appearance = theme.appearance
        capturePopover.contentSize = content.frame.size
        capturePopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // Escape closes just this popover.
        content.window?.makeKey(); content.window?.makeFirstResponder(content)
    }

    func captureWholePage(_ format: PageCaptureFormat) {
        guard let page = selectedTab?.page else { return }
        let title = selectedTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { [weak self] in
            let data = await page.capture(format)
            guard let self else { return }
            guard let data else { self.showMessage("Couldn’t capture the page", "The page couldn’t be drawn."); return }
            if self.copiesCaptures { Self.copyCapture(data, format: format) }
            let name = Self.captureName(title, format: format)
            if self.savesCapturesAutomatically {
                do {
                    let folder = self.capturesFolder
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = Self.downloadDestination(for: name, in: folder) { FileManager.default.fileExists(atPath: $0.path) }
                    try data.write(to: url)
                    self.announceCapture(format: format, file: url)
                } catch {
                    self.showMessage("Couldn’t save the capture", error.localizedDescription)
                }
                return
            }
            guard let window = self.window else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .jpeg ? .jpeg : .pdf]
            panel.nameFieldStringValue = name
            panel.directoryURL = self.capturesFolder
            panel.beginSheetModal(for: window) { [weak self] result in
                guard let self, result == .OK, let url = panel.url else { return }
                do { try data.write(to: url); self.announceCapture(format: format, file: url) }
                catch { self.showMessage("Couldn’t save the capture", error.localizedDescription) }
            }
        }
    }

    /// Picks the folder captures save to, from settings.
    func chooseCapturesFolder(then done: @escaping () -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choose"; panel.message = "Where page captures are saved"
        panel.directoryURL = capturesFolder
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            self.preferences.set(url, forKey: Self.capturesFolderKey)
            done()
        }
    }

    /// Where it went, for two seconds, in the page bar: the folder's name shows the file in Finder.
    private func announceCapture(format: PageCaptureFormat, file: URL) {
        let place = FileManager.default.displayName(atPath: file.deletingLastPathComponent().path)
        let folder = BarNotice.Link(text: place) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        switch format {
        case .jpeg: selectedBar.showNotice("Saved to", image: BarNotice.photoImage, link: folder, hold: 2)
        case .pdf: selectedBar.showNotice("Saved as PDF to", image: BarNotice.documentImage, link: folder, hold: 2)
        }
    }

    private static func copyCapture(_ data: Data, format: PageCaptureFormat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch format {
        case .jpeg:
            if let image = NSImage(data: data) { pasteboard.writeObjects([image]) }
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        case .pdf:
            pasteboard.setData(data, forType: .pdf)
        }
    }

    /// The page's title, made safe for a file name, or “Rise Capture”.
    private static func captureName(_ title: String, format: PageCaptureFormat) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Rise Capture" : String(cleaned.prefix(120))) + (format == .jpeg ? ".jpg" : ".pdf")
    }
}

/// The capture popover: JPEG and PDF, side by side, as the settings popover's top row looks.
@MainActor final class CaptureChoicesView: FlippedView {
    private let cancel: () -> Void
    init(theme: RiseTheme, choose: @escaping (PageCaptureFormat) -> Void, cancel: @escaping () -> Void) {
        self.cancel = cancel
        let scale = SiteControlsLayout.scale
        let size = NSSize(width: (52*scale).rounded(), height: (34*scale).rounded()), gap: CGFloat = 4, inset: CGFloat = 10
        super.init(frame: NSRect(x: 0, y: 0, width: inset*2+size.width*2+gap, height: inset*2+size.height))
        for (index, (label, format)) in [("JPEG", PageCaptureFormat.jpeg), ("PDF", .pdf)].enumerated() {
            let button = PopoverActionButton(label: label, scale: scale, title: "Capture the whole page as \(label)", theme: theme) { choose(format) }
            button.frame = NSRect(x: inset+CGFloat(index)*(size.width+gap), y: inset, width: size.width, height: size.height)
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { cancel() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { cancel() } else { super.keyDown(with: event) } }
}
