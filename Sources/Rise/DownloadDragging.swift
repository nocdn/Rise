import AppKit
@preconcurrency import QuickLookThumbnailing

/// Dragging a finished download out of the list, as a file is dragged out of Finder: its Quick Look
/// thumbnail or icon under the pointer, sliding back if nothing takes it. Wherever it's dropped gets
/// a copy, so the download stays in Downloads and on the list.
extension DownloadRow: NSDraggingSource {
    /// How far the pointer moves before a press is a drag and not a click.
    static let dragDistance: CGFloat = 4
    /// The picture's longest side.
    static let dragPictureSize: CGFloat = 64

    static func isDrag(from start: NSPoint, to end: NSPoint) -> Bool { hypot(end.x-start.x, end.y-start.y) >= dragDistance }
    /// A finished download whose file is still there.
    var canDragFile: Bool { isFinished && FileManager.default.fileExists(atPath: item.record.url.path) }

    /// Readies a sharper picture than the row's, so it's there by the time the pointer has moved.
    func prepareDrag(from event: NSEvent) {
        guard canDragFile else { dragStart = nil; return }
        dragStart = event
        guard dragPicture == nil, dragPictureRequest == nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.record.url, size: CGSize(width: Self.dragPictureSize, height: Self.dragPictureSize),
                                                  scale: scale, representationTypes: .thumbnail)
        dragPictureRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let thumbnail, thumbnail.type == .thumbnail else { return }
            let image = thumbnail.nsImage
            Task { @MainActor [weak self] in self?.dragPictureArrived(image) }
        }
    }
    private func dragPictureArrived(_ image: NSImage) {
        dragPicture = image
        guard let dragSession else { return }
        // It came after the drag began: the picture changes under the pointer.
        dragSession.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { [self] draggingItem, _, _ in
            let middle = NSPoint(x: draggingItem.draggingFrame.midX, y: draggingItem.draggingFrame.midY)
            draggingItem.setDraggingFrame(frame(for: image, around: middle), contents: image)
        }
    }
    private func frame(for image: NSImage, around middle: NSPoint) -> NSRect {
        let longest = max(1, max(image.size.width, image.size.height)), fit = Self.dragPictureSize/longest
        let size = NSSize(width: image.size.width*fit, height: image.size.height*fit)
        return NSRect(x: middle.x-size.width/2, y: middle.y-size.height/2, width: size.width, height: size.height)
    }
    /// The picture for now: Quick Look's if it's come, or else the file's own icon, at full size.
    private var currentDragPicture: NSImage {
        dragPicture ?? NSWorkspace.shared.icon(forFile: item.record.url.path)
    }
    @discardableResult func beginFileDrag(from event: NSEvent) -> NSDraggingSession? {
        guard canDragFile else { return nil }
        let url = item.record.url
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let picture = currentDragPicture
        draggingItem.setDraggingFrame(frame(for: picture, around: convert(event.locationInWindow, from: nil)), contents: picture)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        dragSession = session
        return session
    }
    /// A copy wherever it goes, in Rise or out of it, so Finder never moves the file off the list.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSession = nil
    }
}
