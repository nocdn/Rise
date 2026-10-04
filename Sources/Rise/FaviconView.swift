import AppKit

/// Dia's subtle clipping on a 16-point favicon, scaled with the displayed icon.
/// Keep the cached image intact; transparent and circular logos retain theirs.
final class FaviconView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true; clipsToBounds = true
        layer?.masksToBounds = true; layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = min(bounds.width, bounds.height) * (4.0 / 16.0)
        CATransaction.commit()
    }
}
