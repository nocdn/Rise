import AppKit
import WebKit

/// The page's fill, clipping edge and shadow share one outline. Clearing the
/// rectangular backing removes the stationary border beside a compressed edge.
final class PageSurface: Surface {
    private let shapedFill = CAShapeLayer()
    private let shapedMask = CAShapeLayer()
    private var pageColor: NSColor
    private let radius: CGFloat
    private(set) var clothOutline: CGPath?
    private var clipsContents = false
    /// The resting shape when it isn't one rounded rectangle, such as two pages side by side.
    /// A history swipe's outline takes over from it while the swipe lasts.
    private(set) var restingOutline: CGPath?
    private var restingClips = false
    private var outline: CGPath? { clothOutline ?? restingOutline }

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
    func setClothOutline(_ path: CGPath?, clipContents: Bool = false) {
        clothOutline = path; clipsContents = clipContents; refreshOutline()
    }
    func setRestingOutline(_ path: CGPath?, clipContents: Bool = false) {
        restingOutline = path; restingClips = clipContents; refreshOutline()
    }
    func refreshOutline() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shapedFill.frame = bounds; shapedMask.frame = bounds
        let outline = outline, clips = clothOutline != nil ? clipsContents : restingClips
        shapedFill.path = outline; shapedFill.isHidden = outline == nil
        super.fill = outline == nil ? pageColor : .clear
        shapedMask.path = outline
        layer?.mask = clips && outline != nil ? shapedMask : nil
        layer?.shadowPath = outline ?? PageOutline.path(in: bounds, radius: radius, continuous: layer?.cornerCurve == .continuous)
        CATransaction.commit()
    }
    override func layout() { super.layout(); refreshOutline() }
}

@MainActor extension BrowserController {
    func updateClothFrame(for web: WKWebView, pull: Double, forward: Bool) {
        let shadow: PageSurface, clip: PageSurface
        if web.superview === pageClip {
            shadow = pageShadow; clip = pageClip
        } else if let card = peekCard as? PageSurface, let inner = web.superview as? PageSurface, inner.superview === card {
            shadow = card; clip = inner
        } else { return }
        // Side by side, only the swiped page's card gives way at its leading edge; the other stays put.
        if clip === pageClip, let group = activeSplitGroup {
            let split = splitFrames(in: pageBody, fraction: group.fraction)
            var frames = [split.left, split.right]
            if let index = frames.firstIndex(where: { abs($0.minX-web.frame.minX) < 0.5 }) {
                let depth = frames[index].width*0.05*pull
                if !forward { frames[index].origin.x += depth }
                frames[index].size.width -= depth
            }
            let path = pageOutline(around: frames)
            shadow.setClothOutline(path); clip.setClothOutline(path, clipContents: true)
            return
        }
        let path = ClothMotion.frameOutline(size: clip.bounds.size, sheet: web.frame, pull: pull, forward: forward,
            corner: clip.layer?.cornerRadius ?? 7, continuous: clip.layer?.cornerCurve == .continuous)
        shadow.setClothOutline(path)
        clip.setClothOutline(path, clipContents: true)
        if clip === pageClip {
            let depth = path == nil ? 0 : web.frame.width * 0.05 * pull
            let scale = 1-depth/max(1,clip.bounds.width)
            let anchor = (developerBar.layer?.anchorPoint.x ?? 0.5) * developerBar.bounds.width
            CATransaction.begin(); CATransaction.setDisableActions(true)
            developerBar.layer?.setAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: 1,
                tx: (forward ? 0 : depth) - (1-scale)*anchor, ty: 0))
            CATransaction.commit()
        }
    }
    func resetClothFrame() {
        pageShadow.setClothOutline(nil); pageClip.setClothOutline(nil)
        (peekCard as? PageSurface)?.setClothOutline(nil)
        (peekCard?.subviews.first as? PageSurface)?.setClothOutline(nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        developerBar.layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }
}
