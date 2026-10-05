import AppKit

/// Preserve the system glyph's shape and optical sizing while adding a fractional
/// amount of ink. SF Symbols' named weights make a larger jump than these tweaks.
enum NavigationIcon {
    static let back = strengthenedSymbol("arrow.left", strokeIncrease: 0.05)
    static let forward = strengthenedSymbol("arrow.right", strokeIncrease: 0.05)
    static let reload = strengthenedSymbol("arrow.clockwise", strokeIncrease: 0.12)
    static let stop = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop loading")?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))

    private static func strengthenedSymbol(_ name: String, strokeIncrease: CGFloat) -> NSImage? {
        guard let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) else { return nil }
        let density: CGFloat = 8
        let width = Int(ceil(source.size.width*density)), height = Int(ceil(source.size.height*density))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width*4, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: density, y: density)
        source.draw(in: NSRect(origin: .zero, size: source.size))
        NSGraphicsContext.restoreGraphicsState()
        let alpha = (0..<width*height).map { bytes[$0*4+3] }
        let radius = strokeIncrease*density/2
        let offsets = (0..<8).map { angle -> CGPoint in
            let radians = CGFloat(angle) * .pi / 4
            return CGPoint(x: cos(radians)*radius, y: sin(radians)*radius)
        }
        func sample(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let left = Int(floor(x)), top = Int(floor(y)), dx = x-CGFloat(left), dy = y-CGFloat(top)
            func pixel(_ x: Int, _ y: Int) -> CGFloat {
                (0..<width).contains(x) && (0..<height).contains(y) ? CGFloat(alpha[y*width+x]) : 0
            }
            return (pixel(left, top)*(1-dx)+pixel(left+1, top)*dx)*(1-dy)
                + (pixel(left, top+1)*(1-dx)+pixel(left+1, top+1)*dx)*dy
        }
        for y in 0..<height { for x in 0..<width {
            var ink = CGFloat(alpha[y*width+x])
            for offset in offsets { ink = max(ink, sample(CGFloat(x)+offset.x, CGFloat(y)+offset.y)) }
            let index = (y*width+x)*4
            bytes[index] = 0; bytes[index+1] = 0; bytes[index+2] = 0; bytes[index+3] = UInt8(min(255, ink.rounded()))
        } }
        bitmap.size = source.size
        let result = NSImage(size: source.size); result.addRepresentation(bitmap); result.isTemplate = true
        return result
    }
}
