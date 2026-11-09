import Photos
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Copy and Save to Photos for an image on a page, in place of WebKit's own. WebKit's copy also
/// puts the image's address, and a surrounding link's, on the pasteboard, which apps such as
/// Messages may paste instead of the picture (Google's results are images in links). These put
/// only the image there, or in the photo library, and say so in a toast showing the image itself.
@MainActor enum PageImageActions {
    /// The image a menu was opened on, taken as the menu opens: it's cleared as the menu closes.
    struct Target {
        let source: URL?
        let frame: WKFrameInfo?
        /// Where it shows in the page's view, for a picture of it when its file can't be had.
        let rect: CGRect?
        let pageURL: URL?
    }
    struct Picture {
        let data: Data
        let type: UTType
        let image: UIImage
    }
    enum Action { case copy, save }

    static func copyAction(_ target: Target, in page: WKWebView, title: String = "Copy", image: UIImage?) -> UIAction {
        UIAction(title: title, image: image ?? UIImage(systemName: "doc.on.doc")) { [weak page] _ in
            guard let page else { return }
            Task { await perform(.copy, on: target, in: page) }
        }
    }
    static func saveAction(_ target: Target, in page: WKWebView, title: String = "Save to Photos", image: UIImage?) -> UIAction {
        UIAction(title: title, image: image ?? UIImage(systemName: "square.and.arrow.down")) { [weak page] _ in
            guard let page else { return }
            Task { await perform(.save, on: target, in: page) }
        }
    }

    static func perform(_ action: Action, on target: Target, in page: WKWebView) async {
        guard let picture = await picture(of: target, in: page) else {
            show(action == .copy ? "Couldn’t copy image" : "Couldn’t save image", picture: nil, in: page)
            return
        }
        switch action {
        case .copy:
            copy(picture)
            UISelectionFeedbackGenerator().selectionChanged()
            show("Copied image", picture: picture, in: page)
        case .save:
            let saved = await save(picture)
            if saved { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            show(saved ? "Saved image" : "Couldn’t save image", picture: saved ? picture : nil, in: page)
        }
    }

    // MARK: The image's file

    /// The image's own file: a data address decoded, the file as the page's session loads it,
    /// or the page's own copy of it (a blob, or one it may read); failing all of those, what
    /// the page shows of it.
    static func picture(of target: Target, in page: WKWebView) async -> Picture? {
        if let source = target.source {
            switch source.scheme?.lowercased() {
            case "data":
                if let data = try? Data(contentsOf: source), let picture = picture(from: data) { return picture }
            case "http", "https":
                if let data = await PageImageDownload.data(from: source, referrer: target.pageURL, in: page), let picture = picture(from: data) {
                    return picture
                }
                fallthrough
            default:
                if let data = await pageCopy(of: source, frame: target.frame, in: page), let picture = picture(from: data) { return picture }
            }
        }
        return await snapshot(of: target, in: page)
    }

    /// What a file holds, if it's an image: its type from its own bytes, not its address.
    static func picture(from data: Data) -> Picture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              let image = UIImage(data: data) else { return nil }
        return Picture(data: data, type: type, image: image)
    }

    /// The page's own fetch of it, which can read a blob or an image it's allowed to.
    private static func pageCopy(of source: URL, frame: WKFrameInfo?, in page: WKWebView) async -> Data? {
        let script = """
        const response = await fetch(source, {credentials: 'include'});
        if (!response.ok && response.type !== 'basic') return null;
        const bytes = new Uint8Array(await response.arrayBuffer());
        let text = '';
        for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i+0x8000));
        return btoa(text);
        """
        let result = try? await page.callAsyncJavaScript(script, arguments: ["source": source.absoluteString], in: frame, contentWorld: ImageContextMenus.world)
        return (result as? String).flatMap { Data(base64Encoded: $0) }
    }

    /// What the page shows of it, at the screen's scale.
    private static func snapshot(of target: Target, in page: WKWebView) async -> Picture? {
        guard let rect = target.rect?.intersection(page.bounds), !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let configuration = WKSnapshotConfiguration(); configuration.rect = rect
        guard let image = try? await page.takeSnapshot(configuration: configuration), let data = image.pngData() else { return nil }
        return Picture(data: data, type: .png, image: image)
    }

    // MARK: Copying and saving

    /// Only the image goes on the pasteboard: its own file, and a PNG beside a type other apps
    /// may not read.
    static func copy(_ picture: Picture) {
        var item: [String: Any] = [picture.type.identifier: picture.data]
        if ![UTType.png, .jpeg, .gif].contains(picture.type), let png = picture.image.pngData() { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item])
    }

    /// Into the photo library, as its own file where Photos takes that type, or else a PNG.
    static func save(_ picture: Picture) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let kept: [UTType] = [.jpeg, .png, .gif, .heic, .heif, .tiff]
        let data = kept.contains(picture.type) ? picture.data : picture.image.pngData()
        guard let data else { return false }
        return await addToLibrary(data)
    }
    /// Photos makes the change on a queue of its own, so off the main actor.
    nonisolated private static func addToLibrary(_ data: Data) async -> Bool {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch { return false }
    }

    // MARK: The toast

    /// The size of the toasts' own icons.
    static let thumbnailSide: CGFloat = 24

    /// The image cropped to fill a rounded square the size of a toast's icon.
    static func thumbnail(of image: UIImage, side: CGFloat = thumbnailSide) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred(); format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let square = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(roundedRect: square, cornerRadius: side*0.25).addClip()
            let size = image.size, scale = max(side/max(size.width, 1), side/max(size.height, 1))
            let drawn = CGSize(width: size.width*scale, height: size.height*scale)
            image.draw(in: CGRect(x: (side-drawn.width)/2, y: (side-drawn.height)/2, width: drawn.width, height: drawn.height))
        }
        return rendered.withRenderingMode(.alwaysOriginal)
    }

    static func show(_ message: String, picture: Picture?, in page: WKWebView) {
        var responder: UIResponder? = page
        while let current = responder, !(current is BrowserViewController) { responder = current.next }
        guard let browser = responder as? BrowserViewController else { return }
        let glyph = picture.map { thumbnail(of: $0.image) } ?? UIImage(systemName: "exclamationmark.circle")
        // A picture in the icon's place is busier, so less past the text.
        let toast = Toast(message: message, glyph: glyph, name: "page-image-\(UUID().uuidString)", trailingInset: picture == nil ? 22 : 14)
        browser.showToast(toast); toast.leave(after: 2)
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// An image's file as the page's own WebKit session loads it: its cookies, cache and partition.
@MainActor final class PageImageDownload: NSObject, WKDownloadDelegate {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var destination: URL?
    /// Images on a page are a few megabytes at most; anything far past that isn't one.
    static let limit: Int64 = 64 << 20
    private static var running = Set<PageImageDownload>()

    static func data(from url: URL, referrer: URL?, in page: WKWebView) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referrer, ["http", "https"].contains(referrer.scheme?.lowercased() ?? "") {
            request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let loader = PageImageDownload()
        running.insert(loader)
        defer { running.remove(loader) }
        return await withCheckedContinuation { continuation in
            loader.continuation = continuation
            page.startDownload(using: request) { download in download.delegate = loader }
        }
    }

    private func finish(_ data: Data?) {
        if let destination { try? FileManager.default.removeItem(at: destination) }
        continuation?.resume(returning: data); continuation = nil
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        if response.expectedContentLength > Self.limit { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("RiseImage-\(UUID().uuidString)")
        self.destination = destination
        return destination
    }
    func downloadDidFinish(_ download: WKDownload) {
        finish(destination.flatMap { try? Data(contentsOf: $0) })
    }
    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        finish(nil)
    }
}
