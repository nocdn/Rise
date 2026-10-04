import AppKit
import QuartzCore

/// Tabler's "archive" icon (MIT, Paweł Kuna), split into a lid and a box so it can
/// open to catch a download. Geometry is in the icon's 24-unit space, y down, drawn
/// 20 pt wide in the middle of a 28 pt button.
enum ArchiveGlyph {
    enum Hinge { case left, right }
    /// How the archive is displaced while catching downloads; the default is at rest.
    struct Pose {
        var offset = CGPoint.zero
        var rotation = 0.0
        var squash = 0.0
        var open = 0.0
        var hinge = Hinge.left
    }
    static let unit: CGFloat = 20.0/24
    static let lineWidth = 2*unit
    /// The box's rim, in points below the top of its 28 pt button.
    static let rim = 14 - 10 + 8*unit
    static let lid = CGPath(roundedRect: CGRect(x: 3, y: 4, width: 18, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil)
    static let box: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5, y: 8)); path.addLine(to: CGPoint(x: 5, y: 18))
        path.addArc(tangent1End: CGPoint(x: 5, y: 20), tangent2End: CGPoint(x: 7, y: 20), radius: 2)
        path.addLine(to: CGPoint(x: 17, y: 20))
        path.addArc(tangent1End: CGPoint(x: 19, y: 20), tangent2End: CGPoint(x: 19, y: 18), radius: 2)
        path.addLine(to: CGPoint(x: 19, y: 8))
        return path
    }()
    static let handle: CGPath = {
        let path = CGMutablePath(); path.move(to: CGPoint(x: 10, y: 12)); path.addLine(to: CGPoint(x: 14, y: 12)); return path
    }()

    /// Maps icon units into a button whose top-left corner is `origin`, for the lid and the box.
    /// The lid tilts back on the hinge away from the download while the box tips forward
    /// from the same side; the whole archive recoils about a point 3/4 down its button.
    static func transforms(_ pose: Pose, origin: CGPoint) -> (lid: CGAffineTransform, box: CGAffineTransform) {
        let place = CGAffineTransform(scaleX: unit, y: unit).concatenating(CGAffineTransform(translationX: 4, y: 4))
        let recoil = CGAffineTransform(translationX: -14, y: -21)
            .concatenating(CGAffineTransform(scaleX: 1+pose.squash*0.45, y: 1-pose.squash))
            .concatenating(CGAffineTransform(rotationAngle: pose.rotation * .pi/180))
            .concatenating(CGAffineTransform(translationX: 14+pose.offset.x+origin.x, y: 21+pose.offset.y+origin.y))
        let left = pose.hinge == .left
        let angle = pose.open*DownloadMotion.lidAngle*(left ? -1 : 1)
        let tip = DownloadMotion.lidAngle == 0 ? 0 : -angle/DownloadMotion.lidAngle*DownloadMotion.bodyAngle
        let lidHinge = CGPoint(x: left ? 3 : 21, y: 8), boxHinge = CGPoint(x: left ? 5 : 19, y: 8)
        let lid = CGAffineTransform(translationX: -lidHinge.x, y: -lidHinge.y)
            .concatenating(CGAffineTransform(rotationAngle: angle * .pi/180))
            .concatenating(CGAffineTransform(translationX: lidHinge.x, y: lidHinge.y-pose.open*DownloadMotion.lidLift/unit))
        let box = CGAffineTransform(translationX: -boxHinge.x, y: -boxHinge.y)
            .concatenating(CGAffineTransform(rotationAngle: tip * .pi/180))
            .concatenating(CGAffineTransform(translationX: boxHinge.x, y: boxHinge.y))
        return (lid.concatenating(place).concatenating(recoil), box.concatenating(place).concatenating(recoil))
    }
    /// Everything the archive covers, including the inside of the box, so a download
    /// passing behind it disappears as if dropped in.
    static func silhouette(_ pose: Pose, origin: CGPoint) -> CGPath {
        var (lidTransform, boxTransform) = transforms(pose, origin: origin)
        let lidShape = lid.copy(using: &lidTransform)!, boxShape = box.copy(using: &boxTransform)!
        let stroke = { (path: CGPath) in path.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10) }
        return lidShape.union(stroke(lidShape)).union(boxShape).union(stroke(boxShape))
    }
}

/// Draws ``ArchiveGlyph`` in a pose. A flipped view's drawing is always y-down, unlike
/// hand-made sublayers, whose orientation AppKit may change after the window appears.
final class ArchiveGlyphView: FlippedView {
    var pose = ArchiveGlyph.Pose() { didSet { needsDisplay = true } }
    var tint = NSColor(hex: 0x7D7B7B) { didSet { needsDisplay = true } }
    /// Where the 28 pt button's top-left corner sits in this view.
    var buttonOrigin = CGPoint.zero { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let (lid, box) = ArchiveGlyph.transforms(pose, origin: buttonOrigin)
        let path = CGMutablePath()
        path.addPath(ArchiveGlyph.box, transform: box); path.addPath(ArchiveGlyph.handle, transform: box)
        path.addPath(ArchiveGlyph.lid, transform: lid)
        context.addPath(path)
        context.setStrokeColor(tint.cgColor); context.setLineWidth(ArchiveGlyph.lineWidth)
        context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
    }
}

/// The sidebar's archive button, drawn from ``ArchiveGlyph`` so a download can open it.
final class ArchiveButton: ChromeButton {
    private let glyph = ArchiveGlyphView()
    /// Hidden while a download flight draws a moving copy above the page.
    var isGlyphHidden: Bool {
        get { glyph.isHidden }
        set { glyph.isHidden = newValue }
    }
    override var contentTintColor: NSColor? {
        didSet { glyph.tint = contentTintColor ?? NSColor(hex: 0x7D7B7B) }
    }
    init(title: String, action: @escaping () -> Void) {
        super.init(symbol: "archivebox", size: 15, title: title, action: action)
        image = nil; self.title = ""
        addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    var secondaryAction: (() -> Void)?
    override func layout() { super.layout(); glyph.frame = bounds }
    override func rightMouseDown(with event: NSEvent) {
        if let secondaryAction { secondaryAction() } else { super.rightMouseDown(with: event) }
    }
}
