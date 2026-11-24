import AppKit

/// A small, bounded PNG keeps session restoration independent of network/cache
/// availability without embedding a site's original, potentially large image.
@MainActor enum FaviconSnapshot {
    static let maximumBytes = 64 * 1024
    /// Older SVG decoders could save a valid PNG with no visible pixels. Ignore it
    /// on restoration so a blank dark variant cannot hide the working light icon.
    static func decode(_ data: Data) -> NSImage? {
        guard data.count <= maximumBytes, let image = NSImage(data: data), visibleBitmap(image) != nil else { return nil }
        return image
    }
    static func encode(_ image: NSImage?) -> Data? {
        guard let bitmap = visibleBitmap(image),
              let data = bitmap.representation(using: .png, properties: [:]), data.count <= maximumBytes else { return nil }
        return data
    }
    /// The image drawn at up to 32 pixels, if anything in it shows.
    private static func visibleBitmap(_ image: NSImage?) -> NSBitmapImageRep? {
        guard let image, image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
        // Don't turn a 16px fallback into a misleading "32px" cache entry.
        let size = min(32, FaviconImage.pixels(image))
        guard size > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        guard let pixels = bitmap.bitmapData,
              (0..<size).contains(where: { row in
                  stride(from: 3, to: size*4, by: 4).contains { pixels[row*bitmap.bytesPerRow+$0] > 0 }
              }) else { return nil }
        return bitmap
    }
}
