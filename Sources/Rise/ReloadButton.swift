import AppKit
import QuartzCore

/// Reload, which becomes Stop while the page loads: Chromium's toolbar animation (as Helium shows
/// it), where the arrow's circle unwinds into the strokes of the X and winds back. As in Chromium,
/// the swap animates after Reload or Stop is used; other loads swap the glyph at once. Unlike
/// Chromium, a press shows Stop at once: a second click of a double click is ignored instead.
final class ReloadButton: ChromeButton {
    enum Mode { case reload, stop }
    private(set) var mode: Mode = .reload
    private var reloadShortcut = "⌘R", stopShortcut = "⌘."
    private let glyph = CAShapeLayer()
    private let morph = ReloadMorph.shared
    /// The animation's frame on show; reload rests at 0, stop at 123.
    private var shownFrame = 0.0
    /// What's left to play: stretches of the animation's frames, each with its own duration.
    private var queue: [(from: Double, to: Double, duration: CFTimeInterval)] = []
    private var segmentStart: CFTimeInterval = 0
    private var link: CADisplayLink?
    /// Set by a press, so the swap that follows animates.
    private var animatesNext = false
    /// The load stopped while the pointer was over Stop: Reload waits for it to leave, so a
    /// second click doesn't reload by accident.
    private var pendingReload: Timer?
    /// When Reload was last pressed, and when the pointer last came over the button.
    private var reloadPressedAt: CFTimeInterval = -.infinity
    private var enteredAt: CFTimeInterval = -.infinity
    private var stopShownAt: CFTimeInterval = -.infinity
    override var contentTintColor: NSColor? {
        didSet {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            glyph.strokeColor = (contentTintColor ?? .secondaryLabelColor).cgColor
            CATransaction.commit()
        }
    }
    init(title: String, action: @escaping () -> Void) {
        super.init(symbol: "arrow.clockwise", size: 16, title: title, action: action)
        updateHint()
        image = nil
        glyph.fillColor = nil; glyph.lineCap = .round; glyph.lineJoin = .round
        glyph.strokeColor = (contentTintColor ?? .secondaryLabelColor).cgColor
        layer?.addSublayer(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// A press that does nothing itself, being that second click, but is still someone reloading.
    var onRepeatedPress: (() -> Void)?
    override func runAction() {
        let now = CACurrentMediaTime()
        // The second click of a double click on Reload doesn't stop the load it started.
        if mode == .stop, now-reloadPressedAt < NSEvent.doubleClickInterval { onRepeatedPress?(); return }
        if mode == .reload { reloadPressedAt = now }
        super.runAction()
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        enteredAt = CACurrentMediaTime()
    }
    /// Reload or Stop was used, here or with ⌘R: the swap that follows animates.
    func armAnimation() { animatesNext = true }
    func setHintShortcuts(reload: String, stop: String) {
        reloadShortcut = reload; stopShortcut = stop; updateHint()
    }
    private func updateHint() {
        setHoverHint(mode == .reload ? "Reload" : "Stop Loading", shortcut: mode == .reload ? reloadShortcut : stopShortcut)
    }
    override func layout() { super.layout(); draw() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); draw() }

    /// Shows reload or stop: animated after a press (or `animated`), at once otherwise.
    func setMode(_ next: Mode, animated: Bool = false, force: Bool = false) {
        let animate = (animated || animatesNext) && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if next == .reload { animatesNext = false }
        pendingReload?.invalidate(); pendingReload = nil
        guard next != mode else { return }
        if !force, next == .reload, hover, enteredAt > stopShownAt {
            // Chromium's guard: the pointer came over Stop, perhaps to click it, so a load that
            // finishes keeps Stop there until the pointer leaves or a moment passes.
            pendingReload = .scheduledTimer(withTimeInterval: 1.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setMode(.reload, animated: animate, force: true) }
            }
            return
        }
        mode = next
        if next == .stop { stopShownAt = CACurrentMediaTime() }
        updateHint()
        guard animate else { stopAnimation(); shownFrame = next == .stop ? ReloadMorph.stopFrame : 0; draw(); return }
        let time = ReloadMorph.duration
        if next == .stop {
            // Reload to stop, starting over if stop to reload was still under way, as Chromium does.
            queue = [(0, ReloadMorph.stopFrame, time)]
        } else if (0..<ReloadMorph.stopFrame).contains(shownFrame), link != nil {
            // Cut short on the way to stop: finish it quickly, then wind back, as Chromium does.
            let scale = 0.66+(1-0.66)*shownFrame/ReloadMorph.stopFrame
            queue = [(shownFrame, ReloadMorph.stopFrame, scale*time), (ReloadMorph.returnStart, ReloadMorph.returnEnd, scale*time)]
        } else {
            queue = [(ReloadMorph.returnStart, ReloadMorph.returnEnd, time)]
        }
        segmentStart = CACurrentMediaTime(); shownFrame = queue[0].from
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common); self.link = link
        }
        draw()
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if pendingReload != nil { setMode(.reload, force: true) }
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let segment = queue.first else { stopAnimation(); return }
        let progress = min(1, (CACurrentMediaTime()-segmentStart)/max(0.001, segment.duration))
        shownFrame = segment.from+(segment.to-segment.from)*ReloadMorph.ease(progress)
        if progress >= 1 {
            queue.removeFirst(); segmentStart = CACurrentMediaTime()
            if queue.isEmpty { shownFrame = mode == .stop ? ReloadMorph.stopFrame : 0; stopAnimation() }
        }
        draw()
    }
    private func stopAnimation() { link?.invalidate(); link = nil; queue = [] }
    /// The middle of the glyph's ink, up and down, in the button's space: what the page bar's
    /// notices centre their glyphs on.
    var inkMidY: CGFloat { glyph.path.map { $0.boundingBoxOfPath.midY } ?? bounds.midY }
    private func draw() {
        let path = morph.path(at: shownFrame, center: CGPoint(x: bounds.midX, y: bounds.midY), flipped: isFlipped)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.frame = bounds; glyph.path = path; glyph.lineWidth = ReloadMorph.lineWidth
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}

/// Plays a Lottie file's stroked shapes, as much of the format as Chromium's reload animation uses:
/// precompositions, shape layers and groups, paths (still or moving), trim paths, strokes and
/// transforms, with eased keyframes.
@MainActor final class ReloadMorph {
    static let shared = ReloadMorph(json: ReloadLottie.json)
    /// Chromium's stretches of the timeline (reload_button.cc): reload to stop over 0–123, stop to
    /// reload over 200–300, each in 300 ms with its FAST_OUT_SLOW_IN_3 curve.
    static let stopFrame = 123.0, returnStart = 200.0, returnEnd = 300.0, duration: CFTimeInterval = 0.3
    static func ease(_ x: Double) -> Double { CubicBezierCurve(x1: 0.2, y1: 0, x2: 0, y2: 1).y(at: x) }
    /// The size Reload already had: the circle's ink about as wide as the circle of the
    /// arrow.clockwise glyph it replaces (11.6 pt at 13.5 pt), drawn with about its weight.
    static let lineWidth: CGFloat = 1.35
    static let inkHeight: CGFloat = 12
    private var scale: CGFloat { (Self.inkHeight-Self.lineWidth)/2/70 }
    private let root: [String: Any]
    private var assets: [String: [[String: Any]]] = [:]
    private let canvas: CGSize

    init(json: String) {
        root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            if let id = asset["id"] as? String, let layers = asset["layers"] as? [[String: Any]] { assets[id] = layers }
        }
        canvas = CGSize(width: root["w"] as? Double ?? 240, height: root["h"] as? Double ?? 240)
    }

    /// The strokes at `frame`, centred on `center`, as a path to stroke with `lineWidth`.
    func path(at frame: Double, center: CGPoint, flipped: Bool) -> CGPath {
        var lines: [[CGPoint]] = []
        let toView = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: flipped ? scale : -scale)
            .translatedBy(x: -canvas.width/2, y: -canvas.height/2)
        render(root["layers"] as? [[String: Any]] ?? [], at: frame, transform: toView, into: &lines)
        let path = CGMutablePath()
        for line in lines where line.count > 1 { path.addLines(between: line) }
        return path
    }
    private func render(_ layers: [[String: Any]], at time: Double, transform: CGAffineTransform, into lines: inout [[CGPoint]]) {
        // Later layers sit below earlier ones; strokes of one colour can go in any order.
        for layer in layers {
            let start = layer["ip"] as? Double ?? 0, end = layer["op"] as? Double ?? .infinity
            guard time >= start, time < end else { continue }
            let matrix = self.transform(layer["ks"] as? [String: Any] ?? [:], at: time).concatenating(transform)
            if let id = layer["refId"] as? String, let inner = assets[id] {
                render(inner, at: time-(layer["st"] as? Double ?? 0), transform: matrix, into: &lines)
            } else if let shapes = layer["shapes"] as? [[String: Any]] {
                _ = group(shapes, at: time, transform: matrix, into: &lines)
            }
        }
    }
    /// A group's paths, in the view's space: trimmed by the trims after them and drawn by the
    /// strokes after them, as a Lottie group does.
    private func group(_ items: [[String: Any]], at time: Double, transform outer: CGAffineTransform, into lines: inout [[CGPoint]]) -> [[CGPoint]] {
        let local = items.first { $0["ty"] as? String == "tr" }.map { self.transform($0, at: time) } ?? .identity
        let matrix = local.concatenating(outer)
        var paths: [[CGPoint]] = []
        for item in items {
            switch item["ty"] as? String {
            case "sh": if let shape = shapeValue(item["ks"], at: time) { paths.append(flatten(shape, matrix)) }
            case "gr": paths += group(item["it"] as? [[String: Any]] ?? [], at: time, transform: matrix, into: &lines)
            case "tm":
                let start = value(item["s"], at: time)[0]/100, end = value(item["e"], at: time)[0]/100
                let offset = value(item["o"], at: time)[0]/360
                paths = trim(paths, from: min(start, end)+offset, to: max(start, end)+offset, together: item["m"] as? Int == 2)
            case "st": lines += paths
            default: break
            }
        }
        return paths
    }

    // MARK: Values

    /// An animatable property's numbers at `time`.
    private func value(_ property: Any?, at time: Double) -> [Double] {
        guard let property = property as? [String: Any] else { return [0] }
        if property["a"] as? Int != 1 {
            if let number = property["k"] as? Double { return [number] }
            return property["k"] as? [Double] ?? [0]
        }
        let keys = property["k"] as? [[String: Any]] ?? []
        let (from, to, progress) = segment(keys, at: time)
        let a = from["s"] as? [Double] ?? [0], b = to["s"] as? [Double] ?? a
        return zip(a, b).map { $0+($1-$0)*progress }
    }
    private func shapeValue(_ property: Any?, at time: Double) -> [String: Any]? {
        guard let property = property as? [String: Any] else { return nil }
        if property["a"] as? Int != 1 { return property["k"] as? [String: Any] }
        let keys = property["k"] as? [[String: Any]] ?? []
        let (from, to, progress) = segment(keys, at: time)
        guard let a = (from["s"] as? [[String: Any]])?.first else { return nil }
        guard let b = (to["s"] as? [[String: Any]])?.first, progress > 0 else { return a }
        var shape = a
        for key in ["v", "i", "o"] {
            let p = a[key] as? [[Double]] ?? [], q = b[key] as? [[Double]] ?? p
            shape[key] = zip(p, q).map { zip($0, $1).map { $0+($1-$0)*progress } }
        }
        return shape
    }
    /// The keyframes either side of `time`, and the eased way between them.
    private func segment(_ keys: [[String: Any]], at time: Double) -> ([String: Any], [String: Any], Double) {
        guard let first = keys.first else { return ([:], [:], 0) }
        if time <= first["t"] as? Double ?? 0 { return (first, first, 0) }
        for index in 0..<keys.count-1 {
            let from = keys[index], to = keys[index+1]
            let t0 = from["t"] as? Double ?? 0, t1 = to["t"] as? Double ?? t0
            guard time < t1 else { continue }
            if from["h"] as? Int == 1 { return (from, from, 0) }
            let x = (time-t0)/max(0.0001, t1-t0)
            func handle(_ key: String, _ axis: String) -> Double {
                let part = from[key] as? [String: Any]
                return (part?[axis] as? [Double])?.first ?? part?[axis] as? Double ?? (key == "o" ? 0 : 1)
            }
            let curve = CubicBezierCurve(x1: handle("o", "x"), y1: handle("o", "y"), x2: handle("i", "x"), y2: handle("i", "y"))
            return (from, to, curve.y(at: x))
        }
        return (keys[keys.count-1], keys[keys.count-1], 0)
    }
    private func transform(_ properties: [String: Any], at time: Double) -> CGAffineTransform {
        let position = value(properties["p"], at: time), anchor = value(properties["a"], at: time)
        let scale = properties["s"] == nil ? [100, 100] : value(properties["s"], at: time)
        let rotation = value(properties["r"], at: time)[0]
        return CGAffineTransform(translationX: -anchor[0], y: -(anchor.count > 1 ? anchor[1] : 0))
            .concatenating(CGAffineTransform(scaleX: scale[0]/100, y: (scale.count > 1 ? scale[1] : scale[0])/100))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi/180))
            .concatenating(CGAffineTransform(translationX: position[0], y: position.count > 1 ? position[1] : 0))
    }

    // MARK: Paths

    /// A Lottie path's curves as points, in the view's space.
    private func flatten(_ shape: [String: Any], _ matrix: CGAffineTransform) -> [CGPoint] {
        let vertices = shape["v"] as? [[Double]] ?? [], ins = shape["i"] as? [[Double]] ?? [], outs = shape["o"] as? [[Double]] ?? []
        guard vertices.count > 1 else { return [] }
        let closed = shape["c"] as? Bool ?? false
        func point(_ p: [Double]) -> CGPoint { CGPoint(x: p[0], y: p[1]) }
        var points = [point(vertices[0]).applying(matrix)]
        let count = closed ? vertices.count : vertices.count-1
        for index in 0..<count {
            let next = (index+1)%vertices.count
            let p0 = point(vertices[index]), p3 = point(vertices[next])
            let p1 = CGPoint(x: p0.x+outs[index][0], y: p0.y+outs[index][1])
            let p2 = CGPoint(x: p3.x+ins[next][0], y: p3.y+ins[next][1])
            for step in 1...24 {
                let t = CGFloat(step)/24, u = 1-t
                let x = u*u*u*p0.x+3*u*u*t*p1.x+3*u*t*t*p2.x+t*t*t*p3.x
                let y = u*u*u*p0.y+3*u*u*t*p1.y+3*u*t*t*p2.y+t*t*t*p3.y
                points.append(CGPoint(x: x, y: y).applying(matrix))
            }
        }
        return points
    }
    /// The part of `paths` between two fractions of their length: of each in turn, or with
    /// `together`, of all of them run end to end (Lottie's "individually").
    private func trim(_ paths: [[CGPoint]], from start: Double, to end: Double, together: Bool) -> [[CGPoint]] {
        func length(_ line: [CGPoint]) -> Double {
            zip(line, line.dropFirst()).reduce(0) { $0+Double(hypot($1.1.x-$1.0.x, $1.1.y-$1.0.y)) }
        }
        func cut(_ line: [CGPoint], _ a: Double, _ b: Double) -> [CGPoint] {
            guard b > a else { return [] }
            var result: [CGPoint] = [], walked = 0.0
            for (p, q) in zip(line, line.dropFirst()) {
                let span = Double(hypot(q.x-p.x, q.y-p.y))
                defer { walked += span }
                guard span > 0, walked+span >= a, walked <= b else { continue }
                func at(_ distance: Double) -> CGPoint {
                    let t = CGFloat(min(1, max(0, (distance-walked)/span)))
                    return CGPoint(x: p.x+(q.x-p.x)*t, y: p.y+(q.y-p.y)*t)
                }
                if result.isEmpty { result.append(at(max(a, walked))) }
                result.append(at(min(b, walked+span)))
            }
            return result
        }
        if start <= 0.0001 && end >= 0.9999 { return paths }
        if together {
            let total = paths.map(length).reduce(0, +)
            var result: [[CGPoint]] = [], offset = 0.0
            for line in paths {
                let span = length(line)
                let piece = cut(line, start*total-offset, end*total-offset)
                if piece.count > 1 { result.append(piece) }
                offset += span
            }
            return result
        }
        return paths.compactMap { line in
            let span = length(line), piece = cut(line, start*span, end*span)
            return piece.count > 1 ? piece : nil
        }
    }
}

/// A CSS-style timing curve from (0,0) to (1,1).
struct CubicBezierCurve {
    let x1: Double, y1: Double, x2: Double, y2: Double
    func y(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<30 {
            t = (low+high)/2
            let u = 1-t, value = 3*u*u*t*x1+3*u*t*t*x2+t*t*t
            if value < x { low = t } else { high = t }
        }
        let u = 1-t
        return 3*u*u*t*y1+3*u*t*t*y2+t*t*t
    }
}
