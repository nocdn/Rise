import AppKit

/// A small, bounded PNG keeps session restoration independent of network/cache
/// availability without embedding a site's original, potentially large image.
@MainActor enum FaviconSnapshot {
    static let maximumBytes = 64 * 1024
    static func encode(_ image: NSImage?) -> Data? {
        guard let image, image.isValid, image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= maximumBytes else { return nil }
        return data
    }
}
