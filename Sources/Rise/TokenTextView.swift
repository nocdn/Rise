import AppKit
import CoreImage

/// Keeps TextKit's native layout, selection and accessibility. Only the glyph drawing
/// moves: a word's line breaks, advance and baseline never change during its entrance.
final class TokenTextView: NSTextView {
    let tokenLayout = TokenLayoutManager()
    private let backingStorage = NSTextStorage()
    init() {
        let container = NSTextContainer(containerSize: .zero)
        backingStorage.addLayoutManager(tokenLayout); tokenLayout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Where a control drawn over the text, such as a ⋯ at the end of its last line, keeps the
    /// pointer a hand: the text's own I-beam would otherwise cover it. In this view's coordinates.
    var handCursorRect: (() -> NSRect?)?
    private func overHandRect(_ event: NSEvent) -> Bool {
        guard let rect = handCursorRect?() else { return false }
        return rect.contains(convert(event.locationInWindow, from: nil))
    }
    override func cursorUpdate(with event: NSEvent) { if overHandRect(event) { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) } }
    override func mouseMoved(with event: NSEvent) { if overHandRect(event) { NSCursor.pointingHand.set() } else { super.mouseMoved(with: event) } }
    /// A double-click while the text can't be edited, as a card's description turns editable.
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, !isEditable, let onDoubleClick { onDoubleClick(); return }
        super.mouseDown(with: event)
    }
}

final class TokenLayoutManager: NSLayoutManager {
    private static let imageContext: CIContext = {
        let context = CIContext(options: [.cacheIntermediates: false])
        // Compile the small blur pipeline before a response starts, so the first word
        // doesn't pay Core Image's initial setup cost on its first animation frame.
        if let bitmap = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
            if let image = bitmap.makeImage() {
                let source = CIImage(cgImage: image)
                _ = context.createCGImage(source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2]), from: source.extent)
            }
        }
        return context
    }()
    override init() { super.init(); _ = Self.imageContext }
    required init?(coder: NSCoder) { super.init(coder: coder); _ = Self.imageContext }
    private(set) var entrances: [TokenStream.Entrance] = []
    /// Whether entering words slide in from the right as they sharpen, or only sharpen in place.
    var travels = true

    func setEntrances(_ next: [TokenStream.Entrance]) {
        guard next != entrances else { return }
        let previous = entrances; entrances = next
        let length = textStorage?.length ?? 0
        for effect in previous+next where NSMaxRange(effect.range) <= length {
            invalidateDisplay(forCharacterRange: effect.range)
            let glyphs = glyphRange(forCharacterRange: effect.range, actualCharacterRange: nil)
            if glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil), let view = container.textView {
                let origin = view.textContainerOrigin
                // Redraw the effect's overhang too, including the last frame when it
                // disappears, so no shifted/blurred pixels remain beside native text.
                view.setNeedsDisplay(boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -6, dy: -4))
            }
        }
    }

    override func drawGlyphs(forGlyphRange range: NSRange, at origin: NSPoint) {
        guard !entrances.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            super.drawGlyphs(forGlyphRange: range, at: origin); return
        }
        let length = textStorage?.length ?? 0
        let moving = entrances.filter { NSMaxRange($0.range) <= length }.compactMap { effect -> (NSRange, Double)? in
            let glyphs = NSIntersectionRange(range, glyphRange(forCharacterRange: effect.range, actualCharacterRange: nil))
            return glyphs.length > 0 ? (glyphs, effect.progress) : nil
        }.sorted { $0.0.location < $1.0.location }
        var cursor = range.location
        for (glyphs, progress) in moving {
            if cursor < glyphs.location { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: glyphs.location-cursor), at: origin) }
            drawEntrance(glyphs, at: origin, progress: progress)
            cursor = NSMaxRange(glyphs)
        }
        if cursor < NSMaxRange(range) { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(range)-cursor), at: origin) }
    }

    private func drawEntrance(_ glyphs: NSRange, at origin: NSPoint, progress: Double) {
        guard let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
        let scale = container.textView?.window?.backingScaleFactor ?? 2
        // Padding keeps the blur's edge and italic overhangs from being clipped.
        let ink = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: -4)
        let rect = NSRect(x: floor(ink.minX*scale)/scale, y: floor(ink.minY*scale)/scale,
                          width: ceil(ink.maxX*scale)/scale-floor(ink.minX*scale)/scale,
                          height: ceil(ink.maxY*scale)/scale-floor(ink.minY*scale)/scale)
        guard let image = entranceImage(glyphs, origin: origin, rect: rect, scale: scale, blur: CGFloat(TokenMotion.blur*(1-progress))) else {
            super.drawGlyphs(forGlyphRange: glyphs, at: origin); return
        }
        image.draw(in: rect.offsetBy(dx: travels ? TokenMotion.travel*(1-progress) : 0, dy: 0), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func entranceImage(_ glyphs: NSRange, origin: NSPoint, rect: NSRect, scale: CGFloat, blur: CGFloat) -> NSImage? {
        guard rect.width > 0, rect.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(rect.width*scale)), pixelsHigh: Int(ceil(rect.height*scale)),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let context = bitmapContext.cgContext
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh)); context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        super.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: origin.x-rect.minX, y: origin.y-rect.minY))
        NSGraphicsContext.restoreGraphicsState()
        guard let source = bitmap.cgImage else { return nil }
        let input = CIImage(cgImage: source)
        let softened = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur*scale])
        guard let output = Self.imageContext.createCGImage(softened, from: input.extent) else { return nil }
        return NSImage(cgImage: output, size: rect.size)
    }
}
