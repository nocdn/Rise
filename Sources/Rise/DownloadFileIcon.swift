import AppKit
import ImageIO
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A finished file's thumbnail, with its normal file icon while Quick Look works
/// or when that file has no thumbnail. Generation never blocks the download list.
@MainActor final class DownloadFileIcon: NSImageView {
    private var fileURL: URL?
    private var request: QLThumbnailGenerator.Request?
    private var requestedScale: CGFloat?
    private let thumbnailMask = CAShapeLayer()
    static let maximumPreviewWidth: CGFloat = 24, previewRadius: CGFloat = 2
    private(set) var hasThumbnail = false { didSet { needsLayout = true } }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    /// Preserve the proportional fit, then crop only the extra width. Portrait
    /// documents keep their shape; wide previews share a compact, rounded edge.
    var previewBounds: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(bounds.width/image.size.width, bounds.height/image.size.height)
        let size = NSSize(width: min(Self.maximumPreviewWidth, image.size.width*fit), height: image.size.height*fit)
        return NSRect(x: bounds.midX-size.width/2, y: bounds.midY-size.height/2, width: size.width, height: size.height)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumbnailMask.frame = bounds
        thumbnailMask.path = CGPath(roundedRect: previewBounds, cornerWidth: Self.previewRadius, cornerHeight: Self.previewRadius, transform: nil)
        layer?.mask = hasThumbnail ? thumbnailMask : nil
        CATransaction.commit()
    }

    func showFile(_ url: URL) {
        let scale = window?.backingScaleFactor ?? 2
        guard fileURL != url || requestedScale != scale else { return }
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        fileURL = url; requestedScale = scale; hasThumbnail = false
        let exists = FileManager.default.fileExists(atPath: url.path)
        image = exists ? NSWorkspace.shared.icon(forFile: url.path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
        guard exists else { request = nil; return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 32, height: 32),
                                                  scale: scale, representationTypes: .thumbnail)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            Task { @MainActor [weak self] in
                guard let self, self.request === request else { return }
                if let thumbnail, thumbnail.type == .thumbnail {
                    self.image = thumbnail.nsImage; self.hasThumbnail = true
                } else {
                    // Quick Look can reject an image whose extension doesn't match
                    // its bytes. ImageIO recognizes the data and downsamples directly.
                    let bitmap = await Task.detached(priority: .utility) { Self.imageThumbnail(url, scale: scale) }.value
                    guard self.request === request, let bitmap else { return }
                    self.image = NSImage(cgImage: bitmap, size: NSSize(width: CGFloat(bitmap.width)/scale, height: CGFloat(bitmap.height)/scale))
                    self.hasThumbnail = true
                }
            }
        }
    }
    private nonisolated static func imageThumbnail(_ url: URL, scale: CGFloat) -> CGImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: Int(32*scale)] as CFDictionary)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let fileURL { showFile(fileURL) }
    }
    deinit { if let request { QLThumbnailGenerator.shared.cancel(request) } }
}
