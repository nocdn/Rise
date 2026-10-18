import AppKit

/// A title that can grow beyond its sidebar row. The small leading corner points back
/// toward the pointer; it never takes clicks or delays the row's hover exit.
@MainActor final class TabTitleTooltip: FlippedView {
    static let inset = NSSize(width: 10, height: 8)
    static let radius: CGFloat = 14, leadingRadius: CGFloat = 2
    static let maximumWidth: CGFloat = 520
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let hint = label("Double-click to rename", size: 12)
    let shape = CAShapeLayer()
    private var anchor = NSPoint.zero
    /// Pinned tiles can't be renamed in place, so theirs leaves the hint out.
    var showsHint = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true; wantsLayer = true; clipsToBounds = false
        layer?.addSublayer(shape)
        shape.lineWidth = 0.5
        shape.shadowColor = NSColor.black.cgColor; shape.shadowOpacity = 0.18
        shape.shadowRadius = 8; shape.shadowOffset = NSSize(width: 0, height: -3)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        titleLabel.cell?.truncatesLastVisibleLine = true
        [titleLabel, hint].forEach { $0.setAccessibilityElement(false); addSubview($0) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Placement and visibility change together, without a fade or a size animation.
    func present(title: String, near pointer: NSPoint, theme: RiseTheme) {
        anchor = pointer
        update(title: title, theme: theme)
        isHidden = false
    }
    func update(title: String, theme: RiseTheme) {
        guard let host = superview else { return }
        let available = host.bounds.insetBy(dx: 8, dy: 8)
        let font = titleLabel.font!
        let textWidth = max(1, min(Self.maximumWidth, available.width)-2*Self.inset.width)
        // NSTextField's cell leaves two points on either side of its glyphs.
        let naturalWidth = max((title as NSString).size(withAttributes: [.font: font]).width, showsHint ? hint.intrinsicContentSize.width : 0)+4
        let width = ceil(min(textWidth, naturalWidth))
        let textHeight = ceil((title as NSString).boundingRect(with: NSSize(width: max(1, width-4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
        let hintHeight = showsHint ? 1+ceil(hint.intrinsicContentSize.height) : 0
        let titleHeight = max(1, min(textHeight, available.height-2*Self.inset.height-hintHeight))
        let size = NSSize(width: width+2*Self.inset.width, height: titleHeight+hintHeight+2*Self.inset.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = NSRect(x: max(available.minX, min(anchor.x+12, available.maxX-size.width)),
                       y: max(available.minY, min(anchor.y+12, available.maxY-size.height)), width: size.width, height: size.height)
        titleLabel.stringValue = title; titleLabel.textColor = theme.text; hint.textColor = theme.muted
        titleLabel.frame = NSRect(origin: NSPoint(x: Self.inset.width, y: Self.inset.height), size: NSSize(width: width, height: titleHeight))
        hint.frame = NSRect(x: Self.inset.width, y: titleLabel.frame.maxY+1, width: width, height: max(0, hintHeight-1))
        hint.isHidden = !showsHint
        shape.frame = bounds
        let path = Self.outline(in: bounds)
        shape.path = path; shape.shadowPath = path
        shape.fillColor = (theme == .dark ? theme.page : TabAppearance.selectedFill(theme)).cgColor
        shape.strokeColor = theme.border.cgColor
        CATransaction.commit()
    }
    func dismiss() { isHidden = true }

    static func outline(in rect: NSRect) -> CGPath {
        let path = CGMutablePath(), r = min(radius, min(rect.width, rect.height)/2), leading = min(leadingRadius, r)
        path.move(to: CGPoint(x: rect.minX+leading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX-r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY+r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY-r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX-r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX+r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY-r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY+leading))
        path.addQuadCurve(to: CGPoint(x: rect.minX+leading, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
