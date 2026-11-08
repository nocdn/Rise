import AppKit
import QuartzCore

/// A page a held swipe can go to, nearest first.
struct HistoryListEntry {
    let title: String
    let icon: NSImage?
}

/// Dia's swipe indicator, in Rise's tab styling: a round button with a chevron that comes out
/// from behind the page's edge as a swipe pulls, at the page's middle, and slows as it passes
/// the threshold. Held there, it grows into a short list of the pages that way, the nearest level
/// with where the circle was; pulling further picks pages further away, and the list slides so
/// the chosen one stays there. Letting go, it slides back behind the edge. It sits over the page,
/// cut off at its edges, and takes no clicks.
///
/// Measured from a 60 fps recording of Dia: the circle is a little over two tab rows across,
/// rests about its own radius in from the edge, comes in within 100 ms, and turns into the list
/// after about 0.7 s held. Sizes are scaled from Dia's 38 pt rows to Rise's 34 pt ones.
@MainActor final class HistorySwipeIndicator: FlippedView {
    static let diameter: CGFloat = 72
    /// From the page's edge to the circle's, at rest.
    static let margin: CGFloat = 32
    /// How much further the circle goes past the threshold, at the most, as the swipe resists.
    static let overpull: CGFloat = 26
    static let listInset = TabAppearance.inset
    static let rowHeight = TabAppearance.height
    static let rowSpacing: CGFloat = 2
    static var listRadius: CGFloat { TabAppearance.radius+listInset }
    /// Long titles truncate, rather than the list reaching far across the page.
    static let maximumListWidth: CGFloat = 236

    private(set) var direction: HistoryDirection = .back
    private(set) var entries: [HistoryListEntry] = []
    private(set) var selection = 0
    private var theme = RiseTheme.neutral

    // The circle's centre, in from the edge it comes from: exactly where the swipe puts it while
    // fingers are down, so it never trails them, and a spring once they lift, which carries on at
    // the speed they let go with. Then the circle-to-list morph; the chosen row, in rows from the
    // list's nearest end; and the circle's size, which pops on arming.
    private var position = MotionSpring(), morph = MotionSpring(), chosen = MotionSpring(), scale = MotionSpring(1)
    /// Following the fingers; carrying on into view after they lift; blurring and fading away once
    /// all of it shows; or, for a swipe that hardly moved, back behind the edge.
    private enum Phase { case hidden, dragging, coasting, leaving, returning }
    private var phase = Phase.hidden
    private var armed = false
    private var phaseStart: CFTimeInterval = 0
    /// The last few positions the swipe put the circle at, for the speed it lets go with.
    private var samples: [(time: CFTimeInterval, position: Double)] = []
    /// How far the fade out has gone, 0 to 1.
    private var fade = 0.0
    static let fadeDuration = 0.24
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    var isShowing: Bool { !isHidden }
    var isListShown: Bool { morph.target == 1 }

    private let bubble = FlippedView()
    private let fill = CALayer(), ring = CALayer()
    private let litEdge = CAGradientLayer(), litEdgeShape = CAShapeLayer()
    private var shadows: [CALayer] = []
    private let chevron = CAShapeLayer()
    private let rows = FlippedView()
    private let rowsMask = CALayer()
    private let highlight = PlainTabBackground()
    private var rowViews: [(icon: FaviconView, title: NSTextField)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; clipsToBounds = true; layer?.masksToBounds = true
        isHidden = true
        bubble.wantsLayer = true; bubble.layer?.masksToBounds = false
        bubble.layerUsesCoreImageFilters = true
        addSubview(bubble)
        for layer in [fill, ring] { layer.cornerCurve = .continuous }
        ring.borderWidth = KeroLitEdge.ringWidth; ring.borderColor = KeroLitEdge.ringColor
        litEdge.startPoint = CGPoint(x: 0.5, y: 0); litEdge.endPoint = CGPoint(x: 0.5, y: 1)
        litEdge.colors = KeroLitEdge.colors; litEdgeShape.fillRule = .evenOdd; litEdge.mask = litEdgeShape
        chevron.fillColor = nil; chevron.lineCap = .round; chevron.lineJoin = .round; chevron.lineWidth = 2.6
        bubble.layer?.addSublayer(fill); bubble.layer?.addSublayer(ring)
        rows.wantsLayer = true
        rowsMask.backgroundColor = NSColor.black.cgColor; rowsMask.cornerCurve = .continuous
        rows.layer?.mask = rowsMask
        rows.addSubview(highlight)
        highlight.show(chosen: true, hovered: false, animated: false)
        bubble.addSubview(rows)
        bubble.layer?.addSublayer(litEdge)
        bubble.layer?.addSublayer(chevron)
        resetSprings()
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func resetSprings() {
        // Quick, about a quarter of a second, with a subtle give as it lands.
        morph = MotionSpring(); morph.configure(response: 0.25, bounce: 0.12)
        chosen = MotionSpring(); chosen.configure(response: 0.22, bounce: 0.15)
        scale = MotionSpring(1); scale.configure(response: 0.34, bounce: 0.45)
    }

    func setTheme(_ theme: RiseTheme) {
        guard theme != self.theme else { return }
        self.theme = theme; applyTheme()
    }
    private func applyTheme() {
        let dark = theme == .dark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The sidebar's own colour, a touch lifted in Dark so it stands off a dark page; in Light,
        // the thin border Rise's cards wear, so it holds its shape on a white page.
        fill.backgroundColor = (dark ? NSColor(hex: 0x232328) : theme.background).cgColor
        ring.borderColor = theme.border.cgColor
        ring.isHidden = dark; litEdge.isHidden = !dark
        chevron.strokeColor = theme.selectedText.withAlphaComponent(0.88).cgColor
        highlight.dark = dark
        shadows.forEach { $0.removeFromSuperlayer() }
        // Kero's raised surface (PageSurface), a little deeper as it floats over the page.
        let specs: [(y: CGFloat, blur: CGFloat, opacity: Float)] = dark
            ? [(1, 1, 0.25), (2, 4, 0.22), (8, 20, 0.3)] : [(1, 2, 0.08), (2, 6, 0.06), (8, 22, 0.1)]
        shadows = specs.map { spec in
            let shadow = CALayer()
            shadow.shadowColor = NSColor.black.cgColor; shadow.shadowOpacity = spec.opacity
            shadow.shadowRadius = spec.blur/2; shadow.shadowOffset = CGSize(width: 0, height: spec.y)
            bubble.layer?.insertSublayer(shadow, at: 0)
            return shadow
        }
        CATransaction.commit()
        if !isHidden { render() }
    }

    // MARK: Driving

    /// Follows the swipe: `pull` is the arrow's, 1 at the threshold. The circle goes exactly where
    /// the pull puts it, drawn at once, rather than chasing it.
    func drag(direction: HistoryDirection, pull: Double, armed: Bool) {
        if phase == .hidden || self.direction != direction {
            self.direction = direction
            resetSprings(); entries = []; rebuildRows(); samples = []
            isHidden = false
        }
        // A swipe that starts again catches the circle wherever it was going.
        if phase != .dragging { setFade(0); samples = [] }
        phase = .dragging
        if armed, !self.armed, !reduceMotion { scale.velocity += 1.6 }
        self.armed = armed
        let target = restingPosition(pull: pull), now = CACurrentMediaTime()
        position.value = target; position.target = target; position.velocity = 0
        samples.append((now, target)); samples.removeAll { now - $0.time > 0.08 }
        render()
        if !scale.isResting(within: 0.001) || !morph.isResting(within: 0.002) || !chosen.isResting(within: 0.002) { startTicking() }
    }
    /// The circle grows into the list of `entries`, nearest first.
    func showList(_ entries: [HistoryListEntry]) {
        guard phase == .dragging, !entries.isEmpty else { return }
        self.entries = entries; selection = 0
        chosen.value = 0; chosen.velocity = 0; chosen.target = 0
        rebuildRows()
        morph.target = 1
        startTicking()
    }
    /// Back under the threshold: the list folds into the circle again.
    func hideList() {
        morph.target = 0; selection = 0; chosen.target = 0
        startTicking()
    }
    func select(_ index: Int) {
        let index = max(0, min(entries.count-1, index))
        guard index != selection else { return }
        selection = index; chosen.target = Double(index)
        startTicking()
    }
    /// The swipe ended. A circle not yet all out carries on into view at the speed the fingers
    /// let go with, so even a quick flick shows all of it; just before it's all out, or at once if
    /// it already is, it blurs and fades away where it is, any list folding back into it.
    func release() {
        guard phase == .dragging else { return }
        armed = false; morph.target = 0
        guard !reduceMotion else { hide(); return }
        let now = CACurrentMediaTime()
        let velocity = releaseVelocity(now)
        let travelled = (position.value - hiddenPosition) / (rest - hiddenPosition)
        phaseStart = now
        if position.value >= rest - Self.leadIn {
            beginLeaving()
        } else if travelled >= 0.12 || velocity >= 250 {
            // A spring towards the resting place, starting at the fingers' speed: a fast flick
            // overshoots a little, as a thrown thing would, a slow one eases in.
            phase = .coasting
            position.configure(response: 0.3, bounce: 0.1)
            position.target = rest; position.velocity = min(velocity, 2400)
        } else {
            phase = .returning
            position.configure(response: 0.26, bounce: 0)
            position.target = hiddenPosition; position.velocity = min(0, velocity)
        }
        startTicking()
    }
    func hide() {
        stopTicking(); isHidden = true; phase = .hidden; armed = false
        setFade(0); samples = []
        entries = []; rebuildRows()
    }
    /// How far before it's all out the circle starts to fade.
    static let leadIn = 6.0
    private func beginLeaving() {
        phase = .leaving; phaseStart = CACurrentMediaTime()
        // It settles where it rests, from past it if the swipe pulled it further.
        position.configure(response: 0.3, bounce: 0.1); position.target = rest
        if bubble.layer?.filters?.isEmpty != false, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"; blur.setValue(0, forKey: kCIInputRadiusKey); bubble.layer?.filters = [blur]
        }
    }
    private func setFade(_ value: Double) {
        fade = value
        if value == 0, bubble.layer?.filters != nil { bubble.layer?.filters = nil }
    }
    /// The swipe's speed over its last 80 ms, outwards from the edge positive.
    private func releaseVelocity(_ now: CFTimeInterval) -> Double {
        let recent = samples.filter { now - $0.time <= 0.08 }
        guard let first = recent.first, let last = recent.last, last.time - first.time > 0.008 else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var hiddenPosition: Double { -Double(Self.diameter)/2 - 14 }
    private var rest: Double { Double(Self.margin + Self.diameter/2) }
    /// In step with the swipe to the threshold, then slowing as the arrow's pull does past it.
    private func restingPosition(pull: Double) -> Double {
        let hidden = hiddenPosition
        if pull <= 1 { return hidden + (rest-hidden)*pull }
        return rest + Double(Self.overpull) * min(1, (pull-1)/0.5)
    }

    private func startTicking() {
        if reduceMotion {
            morph.value = morph.target; chosen.value = chosen.target; scale.value = 1
            render(); return
        }
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link; lastTick = CACurrentMediaTime()
    }
    private func stopTicking() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(1.0/30, max(0, now-lastTick)); lastTick = now
        if phase != .dragging { position.step(dt) }
        morph.step(dt); chosen.step(dt); scale.step(dt)
        switch phase {
        case .coasting:
            // Just before it's all out, or if a slow release takes too long getting there.
            if position.value >= rest - Self.leadIn || now - phaseStart > 0.45 { beginLeaving() }
        case .leaving:
            let t = min(1, (now - phaseStart) / Self.fadeDuration)
            setFade(t*t*(3-2*t))
            if t >= 1 { hide(); return }
        case .returning:
            if position.value <= hiddenPosition + 1, morph.value < 0.02 { hide(); return }
        case .dragging, .hidden: break
        }
        render()
        if phase == .dragging, morph.isResting(within: 0.002), chosen.isResting(within: 0.002), scale.isResting(within: 0.001) { stopTicking() }
    }

    // MARK: Drawing

    private var listWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widest = entries.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // The row's own padding, a 16 pt icon and its gap, as a tab row lays them out.
        return min(Self.maximumListWidth, max(196, ceil(widest) + 16 + 8 + 10 + 14 + Self.listInset*2))
    }
    private var listHeight: CGFloat {
        let count = CGFloat(entries.count)
        return Self.listInset*2 + count*Self.rowHeight + max(0, count-1)*Self.rowSpacing
    }
    /// Where a row sits in the list, top down: Back lists the furthest page first, so the
    /// nearest is at the bottom by the circle; Forward lists the nearest first.
    private func displayRow(_ choice: Double) -> Double {
        direction == .back ? Double(entries.count-1) - choice : choice
    }
    private func rowTop(_ row: Double) -> CGFloat {
        Self.listInset + CGFloat(row) * (Self.rowHeight+Self.rowSpacing)
    }

    private func render() {
        let anchorY = (bounds.height/2).rounded()
        let x = CGFloat(position.value)
        let centerX = direction == .back ? x : bounds.width - x
        // Fading away, it softens and shrinks a little as it goes.
        let d = Self.diameter * CGFloat(scale.value) * CGFloat(1 - 0.1*fade)
        let circle = NSRect(x: centerX - d/2, y: anchorY - d/2, width: d, height: d)
        let m = CGFloat(morph.value)
        var shape = circle, radius = d/2
        var list = NSRect.zero
        if !entries.isEmpty {
            let width = listWidth, height = listHeight
            let restX = direction == .back ? centerX - Self.diameter/2 : centerX + Self.diameter/2 - width
            var top = anchorY - rowTop(displayRow(chosen.value)) - Self.rowHeight/2
            // A long list stays on the page, rather than its far end going off it.
            top = min(max(top, 8), max(8, bounds.height - 8 - height))
            list = NSRect(x: restX, y: top, width: width, height: height)
            shape = NSRect(x: lerp(circle.minX, list.minX, m), y: lerp(circle.minY, list.minY, m),
                           width: max(1, lerp(circle.width, list.width, m)), height: max(1, lerp(circle.height, list.height, m)))
            radius = max(0, min(lerp(d/2, Self.listRadius, m), min(shape.width, shape.height)/2))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Solid all the way in, so even a hard flick shows it the whole way; only leaving fades it.
        bubble.alphaValue = CGFloat(1-fade)
        if bubble.layer?.filters?.isEmpty == false { bubble.layer?.setValue(fade * 9, forKeyPath: "filters.blur.inputRadius") }
        bubble.frame = shape
        let local = NSRect(origin: .zero, size: shape.size)
        fill.frame = local; fill.cornerRadius = radius
        ring.frame = local.insetBy(dx: -ring.borderWidth, dy: -ring.borderWidth); ring.cornerRadius = radius+ring.borderWidth
        litEdge.frame = local; litEdgeShape.frame = local
        litEdgeShape.path = KeroLitEdge.path(in: local, radius: radius)
        let outline = PageOutline.path(in: local, radius: radius, continuous: true)
        for shadow in shadows { shadow.frame = local; shadow.shadowPath = outline }
        // The chevron stays where the circle's middle is, fading as the list takes its place.
        let ink = chevronPath(center: CGPoint(x: circle.midX - shape.minX, y: circle.midY - shape.minY), size: d)
        chevron.frame = local; chevron.path = ink
        chevron.opacity = Float(max(0, 1 - m*2.2))
        // Rows keep their place in the list as the shape opens over them, sharpening as they come.
        rows.frame = local
        rowsMask.frame = local; rowsMask.cornerRadius = radius
        let rowsOrigin = NSPoint(x: list.minX - shape.minX, y: list.minY - shape.minY)
        let rowWidth = list.width - Self.listInset*2
        for (index, row) in rowViews.enumerated() {
            let y = rowsOrigin.y + rowTop(displayRow(Double(index)))
            let frame = NSRect(x: rowsOrigin.x + Self.listInset, y: y, width: rowWidth, height: Self.rowHeight)
            row.icon.frame = NSRect(x: frame.minX + 10, y: frame.midY - 8, width: 16, height: 16)
            let titleHeight = row.title.intrinsicContentSize.height
            row.title.frame = NSRect(x: frame.minX + 10 + 16 + 8, y: frame.midY - titleHeight/2,
                                     width: max(0, frame.width - 10 - 16 - 8 - 10), height: titleHeight)
            row.title.textColor = TabAppearance.text(theme, selected: index == selection)
        }
        let highlightY = rowsOrigin.y + rowTop(displayRow(chosen.value))
        highlight.frame = NSRect(x: rowsOrigin.x + Self.listInset, y: highlightY, width: rowWidth, height: Self.rowHeight)
        let content = max(0, min(1, (m - 0.35) / 0.65))
        rows.alphaValue = CGFloat(content)
        if rows.layer?.filters?.isEmpty == false { rows.layer?.setValue((1-content) * 6, forKeyPath: "filters.blur.inputRadius") }
        CATransaction.commit()
    }
    /// Dia's chevron: a heavy arrowhead a third of the circle tall.
    private func chevronPath(center: CGPoint, size: CGFloat) -> CGPath {
        let facing: CGFloat = direction == .back ? -1 : 1
        let height = size * 0.3, width = height * 0.5
        // Optically centred: a chevron reads as the triangle its ends and point make, whose weight
        // sits a third of the way from its open side. That point goes at the circle's middle,
        // which moves the ink a sixth of its width towards where it points.
        let tip = CGPoint(x: center.x + facing * width*2/3, y: center.y)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tip.x - facing*width, y: tip.y - height/2))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x - facing*width, y: tip.y + height/2))
        return path
    }
    private func rebuildRows() {
        rowViews.forEach { $0.icon.removeFromSuperview(); $0.title.removeFromSuperview() }
        rowViews = entries.map { entry in
            let icon = FaviconView(frame: .zero)
            if let image = entry.icon { icon.image = image } else { icon.showEmptyPlaceholder(theme: theme) }
            let title = NSTextField(labelWithString: entry.title)
            title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail; title.maximumNumberOfLines = 1
            title.textColor = TabAppearance.text(theme, selected: false)
            rows.addSubview(icon); rows.addSubview(title)
            return (icon, title)
        }
        highlight.isHidden = entries.isEmpty
        rows.layerUsesCoreImageFilters = true
        if rows.layer?.filters == nil, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"; blur.setValue(0, forKey: kCIInputRadiusKey); rows.layer?.filters = [blur]
        }
    }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b-a)*t }
}
