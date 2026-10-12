import AppKit

/// The page's fill, clipping edge and shadow share one outline, such as two pages side by
/// side. Clearing the rectangular backing keeps a border from showing outside it.
final class PageSurface: Surface {
    private let shapedFill = CAShapeLayer()
    private let shapedMask = CAShapeLayer()
    private var pageColor: NSColor
    private let radius: CGFloat
    /// The resting shape when it isn't one rounded rectangle, such as two pages side by side.
    private(set) var restingOutline: CGPath?
    private var restingClips = false
    private var outline: CGPath? { restingOutline }

    override var fill: NSColor {
        get { pageColor }
        set {
            pageColor = newValue
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shapedFill.fillColor = newValue.cgColor
            super.fill = outline == nil ? newValue : .clear
            CATransaction.commit()
        }
    }
    override init(color: NSColor = .clear, radius: CGFloat = 0) {
        pageColor = color; self.radius = radius
        super.init(color: color, radius: radius)
        shapedFill.isHidden = true; shapedFill.fillColor = color.cgColor
        shapedMask.fillColor = NSColor.white.cgColor
        layer?.insertSublayer(shapedFill, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setRestingOutline(_ path: CGPath?, clipContents: Bool = false) {
        restingOutline = path; restingClips = clipContents; refreshOutline()
    }
    func refreshOutline() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapedFill.frame = bounds; shapedMask.frame = bounds
        let outline = outline, clips = restingClips
        shapedFill.path = outline; shapedFill.isHidden = outline == nil
        super.fill = outline == nil ? pageColor : .clear
        shapedMask.path = outline
        layer?.mask = clips && outline != nil ? shapedMask : nil
        layer?.shadowPath = outline ?? PageOutline.path(in: bounds, radius: radius, continuous: layer?.cornerCurve == .continuous)
        CATransaction.commit()
    }
    override func layout() { super.layout(); refreshOutline() }
}
