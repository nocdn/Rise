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
    /// Kero's dark surface shadow (elevation.go): three tight layers, as CSS writes them, down,
    /// blur, spread and black's opacity, in place of the page's own. The page hides them under it.
    var darkShadows = false { didSet { if darkShadows != oldValue { setDarkShadows() } } }
    private static let darkShadowSpecs: [(y: CGFloat, blur: CGFloat, spread: CGFloat, opacity: Float)] = [(1, 1, 0, 0.2), (2, 2, -1, 0.2), (4, 6, -3, 0.24)]
    private var shadowLayers: [CALayer] = []

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
    private func setDarkShadows() {
        shadowLayers.forEach { $0.removeFromSuperlayer() }
        shadowLayers = darkShadows ? Self.darkShadowSpecs.map { spec in
            let shadow = CALayer()
            shadow.shadowColor = NSColor.black.cgColor; shadow.shadowOpacity = spec.opacity
            shadow.shadowRadius = spec.blur/2; shadow.shadowOffset = CGSize(width: 0, height: spec.y)
            layer?.insertSublayer(shadow, at: 0)
            return shadow
        } : []
        refreshOutline()
    }
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
        let shape = outline ?? PageOutline.path(in: bounds, radius: radius, continuous: layer?.cornerCurve == .continuous)
        layer?.shadowPath = shape
        for (shadow, spec) in zip(shadowLayers, Self.darkShadowSpecs) {
            // A spread grows or shrinks the shape that casts it: drawn from the page's outline,
            // inset by as much as it shrinks.
            shadow.frame = bounds
            var inset = CGAffineTransform(translationX: 0, y: 0)
            if spec.spread != 0, bounds.width > 0, bounds.height > 0 {
                let sx = (bounds.width+2*spec.spread)/bounds.width, sy = (bounds.height+2*spec.spread)/bounds.height
                inset = CGAffineTransform(translationX: bounds.midX, y: bounds.midY).scaledBy(x: sx, y: sy).translatedBy(x: -bounds.midX, y: -bounds.midY)
            }
            shadow.shadowPath = shape.copy(using: &inset)
        }
        CATransaction.commit()
    }
    override func layout() { super.layout(); refreshOutline() }
}
