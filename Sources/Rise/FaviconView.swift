import AppKit

/// Simple circular corners, shared by sidebar and address-panel favicons:
/// a 4-point radius at 16 points, scaled with the displayed icon.
/// Keep the cached image intact; transparent and circular logos retain theirs.
final class FaviconView: NSImageView {
    private let emptyPlaceholder = CALayer()
    /// A search or command glyph can share the slot without clipping its strokes.
    var roundsImage = true { didSet { if roundsImage != oldValue { needsLayout = true } } }
    override var image: NSImage? {
        didSet { emptyPlaceholder.isHidden = true }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true; clipsToBounds = true
        layer?.masksToBounds = true; layer?.cornerCurve = .circular
        emptyPlaceholder.cornerCurve = .circular
        emptyPlaceholder.isHidden = true
        layer?.addSublayer(emptyPlaceholder)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Dia's empty favicon: a 14-point square centered in the 16-point icon slot.
    func showEmptyPlaceholder(theme: RiseTheme) {
        image = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        emptyPlaceholder.backgroundColor = NSColor(hex: theme == .dark ? 0x666666 : 0xD5D5D5).cgColor
        emptyPlaceholder.isHidden = false
        CATransaction.commit()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = roundsImage ? min(bounds.width, bounds.height) * (4.0 / 16.0) : 0
        let scale = min(bounds.width, bounds.height) / 16
        let size = 14 * scale
        emptyPlaceholder.frame = NSRect(x: bounds.midX-size/2, y: bounds.midY-size/2, width: size, height: size)
        emptyPlaceholder.cornerRadius = 3 * scale
        CATransaction.commit()
    }
}
