import AppKit
import RiseCore

@MainActor final class CalculationSwatch: FlippedView {
    private let fill = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The colour on the palette's `background`: its ring is the colour, faint, or a shade of it
    /// that parts it from the background where the colour itself would hardly show there.
    func show(_ color: AddressCalculation.Color, on background: NSColor) {
        func rgb(_ color: AddressCalculation.Color) -> NSColor {
            NSColor(srgbRed: CGFloat(color.red)/255, green: CGFloat(color.green)/255, blue: CGFloat(color.blue)/255, alpha: 1)
        }
        let value = rgb(color), back = background.usingColorSpace(.sRGB) ?? .white
        let ring = color.swatchRing(on: AddressCalculation.Color(red: Int((back.redComponent*255).rounded()),
                                                                 green: Int((back.greenComponent*255).rounded()),
                                                                 blue: Int((back.blueComponent*255).rounded())))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.borderColor = rgb(ring).cgColor
        // A translucent colour shows the row through it, as it would show a page.
        fill.backgroundColor = value.withAlphaComponent(CGFloat(color.alpha)).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height/2
        fill.frame = bounds.insetBy(dx: 2, dy: 2)
        fill.cornerRadius = fill.bounds.height/2
        CATransaction.commit()
    }
}

/// The copy glyph at the end of a calculation's row, as the row copies its answer, in the grey of
/// a quick answer's text (`AddressAnswerPreview`), such as an age, saying so on hover.
/// CodeX Icons' copy (MIT, © 2022 CodeX, © 2026 davidabou), its corners 3 rather than 3.5.
@MainActor final class CalculationCopyIcon: HoverHintView {
    static let size: CGFloat = 16
    /// On a 24-point grid: the front square, then what shows of the one behind.
    private static let glyph = TablerIcon.path("M11.5 8.5H16A3 3 0 0 1 19 11.5V16A3 3 0 0 1 16 19H11.5A3 3 0 0 1 8.5 16V11.5A3 3 0 0 1 11.5 8.5Z"
                                               + "M15.5 8.5V8A3 3 0 0 0 12.5 5H8A3 3 0 0 0 5 8V12.5A3 3 0 0 0 8 15.5H8.5")
    private let shape = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shape.fillColor = nil; shape.lineCap = .round; shape.lineJoin = .round
        layer?.addSublayer(shape)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: RiseTheme) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.strokeColor = CenteredPaletteStyle.detail(theme).cgColor
        CATransaction.commit()
        setHoverHint("Copy to clipboard", theme: theme)
    }

    override func layout() {
        super.layout()
        let scale = bounds.width/24
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = Self.glyph.copy(using: &transform)
        shape.lineWidth = 2*scale
        shape.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
}
