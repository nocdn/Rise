import AppKit
import CoreImage

/// A line of text that gathers out of a cloud of drifting particles, and can scatter back into it,
/// as a smart rename shows a file's new name (Playgrounds/particle-rename-reference.mp4).
///
/// While the name is worked out, a band of fine dots twinkles across the whole title, a brighter
/// patch drifting through it left to right. The new name then forms from the left: a front sweeps
/// along the text, easing out, and just ahead of it the cloud's dots fly to points sampled from the
/// name's own glyphs, so each letter first appears dotted. Just behind the front the real text takes
/// over and the dots fade, and dots the name doesn't need fade where the front passes them.
/// Nothing snaps: each dot sets off a little early or late and flies at its own pace, lands on a
/// curve with no jolt at either end and keeps breathing slightly, and a letter passes through a
/// soft glow of itself on its way from dots to sharp text.
///
/// The text is an ordinary label, so the finished name is exactly what a label draws. The dots are
/// drawn on the CPU into one bitmap a frame; a title holds about a thousand.
@MainActor final class ParticleTextView: NSView {
    enum State: String { case text, dissolving, cloud, revealing }

    struct Tuning {
        /// How fast the front crosses the text, in points a second, before its ease-out.
        var sweepSpeed: CGFloat = 320
        /// How strongly the front slows towards the end of the text; 1 is a constant speed.
        var sweepEase: CGFloat = 1.1
        /// How long a dot takes to fly from the cloud to its place in a letter, and how early
        /// it starts to lean that way.
        var flight: Double = 0.16
        var anticipation: Double = 0.24
        /// Dots set off up to this much later than the front, and fly at up to this much
        /// slower or faster, so a letter fills in rather than landing all at once.
        var stagger: Double = 0.12
        var pace: ClosedRange<Double> = 0.8...1.4
        /// How long a dotted letter holds before the text replaces it, and how long that takes.
        var hold: Double = 0.02
        var solidify: Double = 0.28
        /// A letter glows softly, blurred by this much, between its dots and its sharp text;
        /// the glow takes this long to come up.
        var glowRadius: CGFloat = 1.3
        var glowStrength: CGFloat = 0.75
        var glowIn: Double = 0.22
        /// How much of its drift a landed dot keeps until the text takes over.
        var settle: CGFloat = 0.3
        /// Dissolving: how long the dots take to spread out from the letters into the cloud.
        var scatter: Double = 0.5
        /// Cloud dots per square point.
        var density: CGFloat = 0.3
        /// How far apart the dots sampled in a letter are, in points.
        var dotSpacing: CGFloat = 1.1
        /// How far a dot wanders in the cloud, in points.
        var drift: CGFloat = 1.1
        var dotRadius: ClosedRange<CGFloat> = 0.42...0.78
        /// How tall the cloud is, against the font's cap height.
        var bandHeight: CGFloat = 1.3
    }

    var tuning = Tuning()
    private(set) var state: State = .text
    /// Slows or speeds every motion, for studying it.
    var timeScale: Double = 1
    /// Holds the current moment, including the cloud's drift.
    var isPaused = false
    var onStateChange: ((State) -> Void)?

    var font: NSFont = .systemFont(ofSize: 13) { didSet { label.font = font; probe.font = font; needsLayout = true } }
    var textColor: NSColor = .labelColor { didSet { label.textColor = textColor; needsDisplay = true } }
    var text: String { label.stringValue }

    private let textHost = NSView()
    private let label = NSTextField(labelWithString: "")
    /// Draws text off screen, invisibly, for its glyphs' pixels.
    private let probe = NSTextField(labelWithString: "")
    private let dots = DotsView()
    private let textMask = CAGradientLayer()
    /// The text blurred, between dots and sharp text.
    private let glow = CALayer(), glowMask = CAGradientLayer()

    private struct Particle {
        var home: CGPoint
        /// Where it sits in a letter, when it forms part of the text.
        var target: CGPoint?
        var radius: CGFloat
        var brightness: CGFloat
        var phase: SIMD3<Double>
        var rate: SIMD3<Double>
        /// Added for this transition, so it fades in rather than having been in the cloud.
        var joining = false
        /// When it sets off after the front, and how long it takes against the usual flight.
        var delay: Double = 0
        var pace: Double = 1
    }
    private var particles: [Particle] = []
    /// Seconds of (scaled) time, for the cloud's drift and twinkle.
    private var clock: Double = 0
    /// Seconds since the current transition began.
    private var elapsed: Double = 0
    /// The span of the text the front crosses, in this view's points.
    private var textSpan: ClosedRange<CGFloat> = 0...1
    private var band: (center: CGFloat, half: CGFloat) = (0, 6)
    /// The cloud fades in when it appears without the text to come from.
    private var cloudFadeStart: Double?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for field in [label, probe] {
            field.font = font; field.lineBreakMode = .byTruncatingMiddle; field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
        }
        label.textColor = textColor
        probe.textColor = .black; probe.alphaValue = 0
        textHost.wantsLayer = true
        for mask in [textMask, glowMask] { mask.startPoint = CGPoint(x: 0, y: 0.5); mask.endPoint = CGPoint(x: 1, y: 0.5) }
        glow.mask = glowMask; glow.contentsGravity = .resize; glow.isHidden = true
        textHost.addSubview(label)
        addSubview(probe); addSubview(textHost); addSubview(dots)
        layer?.insertSublayer(glow, at: 0)
        dots.owner = self
    }
    required init?(coder: NSCoder) { fatalError() }

    private var labelFrame: NSRect {
        NSRect(x: 0, y: ((bounds.height-17)/2).rounded(), width: bounds.width, height: 17)
    }
    override func layout() {
        super.layout()
        textHost.frame = bounds; label.frame = labelFrame; probe.frame = labelFrame; dots.frame = bounds
        textMask.frame = textHost.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = labelFrame.insetBy(dx: -glowPadding, dy: -glowPadding); glowMask.frame = glow.bounds
        CATransaction.commit()
        measureBand()
    }

    // MARK: States

    /// Shows `text` at rest, stopping any motion.
    func setText(_ text: String) {
        label.stringValue = text
        particles = []; setState(.text)
    }

    /// Shows the cloud at once, fading in, as when there was no name to start from.
    func showCloud() {
        layoutSubtreeIfNeeded()
        makeCloud(); cloudFadeStart = clock
        setState(.cloud)
    }

    /// Scatters the current text into the cloud, left to right.
    func dissolve() {
        layoutSubtreeIfNeeded()
        let targets = sampleGlyphs(of: label.stringValue)
        guard !targets.points.isEmpty else { showCloud(); return }
        makeCloud(); cloudFadeStart = nil
        assign(targets.points); textSpan = targets.span
        makeGlow()
        setState(.dissolving)
    }

    /// Gathers `newText` out of the cloud, which appears first if it isn't showing.
    func reveal(_ newText: String) {
        layoutSubtreeIfNeeded()
        if state != .cloud { makeCloud(); cloudFadeStart = clock }
        let targets = sampleGlyphs(of: newText)
        guard !targets.points.isEmpty else { setText(newText); return }
        for index in particles.indices { particles[index].target = nil }
        particles.removeAll { $0.joining }
        assign(targets.points); textSpan = targets.span
        label.stringValue = newText
        makeGlow()
        setState(.revealing)
    }

    /// The length of the current transition, in unscaled seconds.
    var transitionDuration: Double {
        switch state {
        case .revealing: sweepDuration + tuning.stagger + tuning.flight*tuning.pace.upperBound + tuning.hold + tuning.solidify
        case .dissolving: sweepDuration + tuning.stagger + tuning.solidify*0.5 + tuning.scatter*tuning.pace.upperBound
        default: 0
        }
    }
    /// How far through its transition the view is, from 0 to 1.
    var progress: Double { transitionDuration > 0 ? min(elapsed/transitionDuration, 1) : 0 }
    /// Holds the transition at a fraction of the way through.
    func scrub(to fraction: Double) {
        guard transitionDuration > 0 else { return }
        isPaused = true; elapsed = max(0, min(fraction, 0.999))*transitionDuration
        dots.needsDisplay = true; updateTextMask()
    }

    private func setState(_ new: State) {
        state = new; elapsed = 0
        textHost.alphaValue = new == .cloud ? 0 : 1
        textHost.layer?.mask = new == .revealing || new == .dissolving ? textMask : nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.isHidden = !(new == .revealing || new == .dissolving)
        CATransaction.commit()
        updateTextMask()
        if new == .text { stopClock() } else { startClock() }
        dots.needsDisplay = true
        onStateChange?(new)
    }

    // MARK: Clock

    private func startClock() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link; lastTick = nil
    }
    private func stopClock() { link?.invalidate(); link = nil; lastTick = nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopClock() } else if state != .text { startClock() }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTick.map { min(max(link.timestamp-$0, 0), 1.0/20) } ?? 1.0/60
        lastTick = link.timestamp
        guard !isPaused else { return }
        clock += dt*timeScale; elapsed += dt*timeScale
        if state == .revealing, elapsed >= transitionDuration { particles = []; setState(.text); return }
        if state == .dissolving, elapsed >= transitionDuration {
            for index in particles.indices { particles[index].target = nil; particles[index].joining = false }
            setState(.cloud); return
        }
        updateTextMask(); dots.needsDisplay = true
    }

    // MARK: Geometry

    /// The cloud sits where capitals do, a little taller.
    private func measureBand() {
        let ink = glyphPixels(of: "HOXE", threshold: 0.5)
        guard let top = ink.map(\.y).min(), let bottom = ink.map(\.y).max() else {
            band = (labelFrame.midY, font.capHeight*tuning.bandHeight/2); return
        }
        band = ((top+bottom)/2, (bottom-top)*tuning.bandHeight/2)
    }

    private func makeCloud() {
        let width = bounds.width, count = Int(width*band.half*2*tuning.density)
        particles = (0..<count).map { _ in
            makeParticle(at: CGPoint(x: .random(in: 1...max(1, width-1)), y: bandY()))
        }
    }
    /// Denser through the middle of the band, as the reference's cloud is.
    private func bandY() -> CGFloat {
        band.center + band.half*(CGFloat.random(in: -1...1)+CGFloat.random(in: -1...1))/2
    }
    private func makeParticle(at home: CGPoint, joining: Bool = false) -> Particle {
        Particle(home: home, radius: .random(in: tuning.dotRadius), brightness: .random(in: 0.35...1),
                 phase: SIMD3(.random(in: 0...(2 * .pi)), .random(in: 0...(2 * .pi)), .random(in: 0...(2 * .pi))),
                 rate: SIMD3(.random(in: 0.9...2.4), .random(in: 0.9...2.4), .random(in: 2.5...6)), joining: joining,
                 delay: .random(in: 0...tuning.stagger), pace: .random(in: tuning.pace))
    }

    /// Each point of the text takes the free cloud dot nearest it along the line, so dots gather
    /// from close by; where the cloud runs short, a new dot joins nearby.
    private func assign(_ targets: [CGPoint]) {
        let order = particles.indices.sorted { particles[$0].home.x < particles[$1].home.x }
        let xs = order.map { particles[$0].home.x }
        var used = [Bool](repeating: false, count: order.count)
        var joining: [Particle] = []
        for target in targets.shuffled() {
            var right = lowerBound(xs, target.x), left = right-1, chosen: Int?
            while left >= 0 || right < xs.count {
                let toLeft = left >= 0 ? target.x-xs[left] : .infinity, toRight = right < xs.count ? xs[right]-target.x : .infinity
                if min(toLeft, toRight) > 24 { break }
                if toLeft <= toRight { if !used[left] { chosen = left; break }; left -= 1 }
                else { if !used[right] { chosen = right; break }; right += 1 }
            }
            if let chosen {
                used[chosen] = true; particles[order[chosen]].target = target
                particles[order[chosen]].delay = .random(in: 0...tuning.stagger); particles[order[chosen]].pace = .random(in: tuning.pace)
            }
            else {
                var particle = makeParticle(at: CGPoint(x: target.x + .random(in: -6...6), y: bandY()), joining: true)
                particle.target = target; joining.append(particle)
            }
        }
        particles += joining
    }
    private func lowerBound(_ xs: [CGFloat], _ x: CGFloat) -> Int {
        var low = 0, high = xs.count
        while low < high { let mid = (low+high)/2; if xs[mid] < x { low = mid+1 } else { high = mid } }
        return low
    }

    /// Evenly spaced points inside the glyphs of `string`, as the label draws it, and the span
    /// of its ink.
    private func sampleGlyphs(of string: String) -> (points: [CGPoint], span: ClosedRange<CGFloat>) {
        let ink = glyphPixels(of: string, threshold: 0.45).shuffled()
        guard let minX = ink.map(\.x).min(), let maxX = ink.map(\.x).max() else { return ([], 0...1) }
        let spacing = tuning.dotSpacing, cell = spacing
        var grid: [SIMD2<Int>: [CGPoint]] = [:], points: [CGPoint] = []
        for point in ink {
            let key = SIMD2(Int(point.x/cell), Int(point.y/cell))
            var clear = true
            search: for dx in -1...1 { for dy in -1...1 {
                for other in grid[SIMD2(key.x+dx, key.y+dy)] ?? [] where hypot(other.x-point.x, other.y-point.y) < spacing { clear = false; break search }
            } }
            if clear { grid[key, default: []].append(point); points.append(point) }
        }
        return (points, minX...max(maxX, minX+1))
    }

    /// The centres of the pixels the label would ink for `string`, in this view's points.
    private func glyphPixels(of string: String, threshold: CGFloat) -> [CGPoint] {
        probe.stringValue = string; probe.frame = labelFrame
        guard probe.bounds.width >= 1, let rep = probe.bitmapImageRepForCachingDisplay(in: probe.bounds) else { return [] }
        // A snapshot honours the view's opacity, so it shows only while it's taken.
        probe.alphaValue = 1; probe.cacheDisplay(in: probe.bounds, to: rep); probe.alphaValue = 0
        guard let image = rep.cgImage else { return [] }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { return [] }
        let scaleX = CGFloat(width)/probe.bounds.width, scaleY = CGFloat(height)/probe.bounds.height
        let cutoff = UInt8(threshold*255), origin = labelFrame.origin
        var points: [CGPoint] = []
        for row in 0..<height { for column in 0..<width where pixels[(row*width+column)*4+3] >= cutoff {
            points.append(CGPoint(x: origin.x+(CGFloat(column)+0.5)/scaleX, y: origin.y+(CGFloat(row)+0.5)/scaleY))
        } }
        return points
    }

    // MARK: Motion

    private var sweepDuration: Double { Double((textSpan.upperBound-textSpan.lowerBound)/tuning.sweepSpeed) }
    /// When the front reaches `x`: it eases out, so later letters come more slowly.
    private func frontTime(_ x: CGFloat) -> Double {
        let reached = Double(min(max((x-textSpan.lowerBound)/(textSpan.upperBound-textSpan.lowerBound), 0), 1))
        return (1-pow(1-reached, 1/Double(tuning.sweepEase)))*sweepDuration
    }
    private static func smooth(_ value: Double) -> CGFloat {
        let t = min(max(value, 0), 1); return CGFloat(t*t*(3-2*t))
    }
    /// Starts and lands with neither speed nor acceleration jumping, so a dot eases into place.
    private static func smoother(_ value: Double) -> CGFloat {
        let t = min(max(value, 0), 1); return CGFloat(t*t*t*(t*(6*t-15)+10))
    }
    /// How strongly the blurred text shows at `x`.
    private func glowAlpha(_ x: CGFloat) -> CGFloat {
        let start = frontTime(x)
        switch state {
        case .revealing: return tuning.glowStrength*Self.smooth((elapsed-(start+tuning.flight*0.5))/tuning.glowIn)*(1-textAlpha(x))
        case .dissolving:
            // Rises as the sharp text goes, then fades as the dots spread.
            return tuning.glowStrength*(1-textAlpha(x))*(1-Self.smooth((elapsed-(start+tuning.solidify*0.6))/tuning.glowIn))
        default: return 0
        }
    }
    private var glowPadding: CGFloat { ceil(tuning.glowRadius*3) }
    /// The text as the label draws it, blurred, with room around it for the blur.
    private func makeGlow() {
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return }
        label.cacheDisplay(in: label.bounds, to: rep)
        guard let source = rep.cgImage else { return }
        let scale = CGFloat(source.width)/max(label.bounds.width, 1), pad = glowPadding*scale
        let extent = CGRect(x: 0, y: 0, width: CGFloat(source.width)+pad*2, height: CGFloat(source.height)+pad*2)
        let blurred = CIImage(cgImage: source).transformed(by: CGAffineTransform(translationX: pad, y: pad))
            .applyingGaussianBlur(sigma: Double(tuning.glowRadius*scale)).cropped(to: extent)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.contents = CIContext().createCGImage(blurred, from: extent); glow.contentsScale = scale
        glow.frame = labelFrame.insetBy(dx: -glowPadding, dy: -glowPadding); glowMask.frame = glow.bounds
        CATransaction.commit()
    }
    /// How solid the text is at `x`: 1 where it has fully taken over from the dots.
    private func textAlpha(_ x: CGFloat) -> CGFloat {
        switch state {
        case .revealing: Self.smooth((elapsed-(frontTime(x)+tuning.flight+tuning.hold))/tuning.solidify)
        case .dissolving: 1-Self.smooth((elapsed-frontTime(x))/tuning.solidify)
        case .text: 1
        case .cloud: 0
        }
    }
    private func updateTextMask() {
        guard state == .revealing || state == .dissolving, bounds.width > 0 else { return }
        let stops = 48
        CATransaction.begin(); CATransaction.setDisableActions(true)
        textMask.frame = textHost.bounds
        textMask.locations = (0...stops).map { NSNumber(value: Double($0)/Double(stops)) }
        textMask.colors = (0...stops).map { CGColor(gray: 0, alpha: textAlpha(bounds.width*CGFloat($0)/CGFloat(stops))) }
        glowMask.locations = textMask.locations
        glowMask.colors = (0...stops).map { CGColor(gray: 0, alpha: glowAlpha(glow.frame.minX+glow.frame.width*CGFloat($0)/CGFloat(stops))) }
        CATransaction.commit()
    }

    /// Where a dot drifts to in the cloud now, and how bright it is there.
    private func cloud(_ p: Particle) -> (point: CGPoint, alpha: CGFloat) {
        let drift = tuning.drift
        let point = CGPoint(x: p.home.x+drift*CGFloat(sin(clock*p.rate.x+p.phase.x)),
                            y: p.home.y+drift*0.7*CGFloat(sin(clock*p.rate.y+p.phase.y)))
        let twinkle = 0.6+0.4*CGFloat(sin(clock*p.rate.z+p.phase.z))
        // A brighter patch drifts through the cloud, left to right.
        let reach = bounds.width+160, waveX = CGFloat((clock*150).truncatingRemainder(dividingBy: Double(reach)))-80
        let wave = exp(-pow((point.x-waveX)/70, 2))
        var alpha = p.brightness*twinkle*(0.7+0.45*wave)
        if let start = cloudFadeStart { alpha *= Self.smooth((clock-start)/0.35) }
        return (point, min(alpha, 1))
    }

    /// Where every dot is and how bright, this frame.
    fileprivate func drawDots(in context: CGContext) {
        guard state != .text else { return }
        var color = (r: CGFloat(1), g: CGFloat(1), b: CGFloat(1))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = textColor.usingColorSpace(.sRGB) { color = (c.redComponent, c.greenComponent, c.blueComponent) }
        }
        for p in particles {
            let (cloudPoint, cloudAlpha) = cloud(p)
            var point = cloudPoint, alpha = cloudAlpha
            switch state {
            case .revealing:
                let x = p.target?.x ?? min(p.home.x, textSpan.upperBound), start = frontTime(x)
                if let target = p.target {
                    let start = start+p.delay
                    let gathered = Self.smoother((elapsed-start+tuning.anticipation)/(tuning.flight*p.pace+tuning.anticipation))
                    // A landed dot keeps breathing a little, until the text takes over.
                    let sharp = textAlpha(target.x), breath = tuning.settle*(1-sharp)
                    let resting = CGPoint(x: target.x+(cloudPoint.x-p.home.x)*breath, y: target.y+(cloudPoint.y-p.home.y)*breath)
                    point = mix(cloudPoint, resting, gathered)
                    alpha = (cloudAlpha*(1-gathered)+0.95*gathered)*(1-sharp)*(1-0.45*glowAlpha(target.x)/max(tuning.glowStrength, 0.01))
                    if p.joining { alpha *= gathered }
                } else {
                    alpha *= 1-Self.smooth((elapsed-start+0.05)/0.22)
                }
            case .dissolving:
                let x = p.target?.x ?? min(p.home.x, textSpan.upperBound), start = frontTime(x)
                if let target = p.target {
                    let spread = Self.smoother((elapsed-start-p.delay-tuning.solidify*0.5)/(tuning.scatter*p.pace))
                    let breath = tuning.settle*(1-textAlpha(target.x))
                    let resting = CGPoint(x: target.x+(cloudPoint.x-p.home.x)*breath, y: target.y+(cloudPoint.y-p.home.y)*breath)
                    point = mix(resting, cloudPoint, spread)
                    alpha = 0.95*(1-textAlpha(target.x))*(1-spread)+cloudAlpha*spread
                } else {
                    alpha *= Self.smooth((elapsed-start)/0.4)
                }
            case .cloud, .text: break
            }
            guard alpha > 0.01 else { continue }
            context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: alpha)
            context.fillEllipse(in: CGRect(x: point.x-p.radius, y: point.y-p.radius, width: p.radius*2, height: p.radius*2))
        }
    }
    private func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t) }

    // MARK: Studying

    /// Renders the view at moments of a reveal of `newText`, without a clock, for comparing
    /// against the reference frame by frame.
    func revealFrames(of newText: String, from oldText: String?, times: [Double]) -> [NSImage] {
        if let oldText { setText(oldText) }
        // From a cloud that has been showing a while, as a reveal follows thinking.
        showCloud(); cloudFadeStart = nil
        reveal(newText); isPaused = true; stopClock()
        let textImage = NSImage(size: label.bounds.size)
        if let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: rep); textImage.addRepresentation(rep)
        }
        let frame = labelFrame, glowFrame = glow.frame, glowImage = glow.contents.map { $0 as! CGImage }
        return times.map { time in
            elapsed = time; clock = time
            // Drawn now: an image's drawing handler would run later, at the last moment's state.
            let scale: CGFloat = 2, size = bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width*scale), pixelsHigh: Int(size.height*scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage() }
            rep.size = size
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            context.translateBy(x: 0, y: size.height*scale); context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let rect = NSRect(origin: .zero, size: size)
            do {
                // The glow and the real label's pixels, column by column at their strength, then the dots.
                if let glowImage {
                    let sx = CGFloat(glowImage.width)/glowFrame.width
                    for column in stride(from: CGFloat(0), to: glowFrame.width, by: 1) {
                        let alpha = glowAlpha(glowFrame.minX+column+0.5)
                        guard alpha > 0.01, let slice = glowImage.cropping(to: CGRect(x: column*sx, y: 0, width: sx, height: CGFloat(glowImage.height))) else { continue }
                        context.saveGState(); context.setAlpha(alpha)
                        context.translateBy(x: glowFrame.minX+column, y: glowFrame.maxY); context.scaleBy(x: 1, y: -1)
                        context.draw(slice, in: CGRect(x: 0, y: 0, width: 1, height: glowFrame.height))
                        context.restoreGState()
                    }
                }
                for column in stride(from: CGFloat(0), to: frame.width, by: 1) {
                    let alpha = textAlpha(frame.minX+column+0.5)
                    guard alpha > 0.01 else { continue }
                    textImage.draw(in: NSRect(x: frame.minX+column, y: frame.minY, width: 1, height: frame.height),
                                   from: NSRect(x: column, y: 0, width: 1, height: frame.height),
                                   operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                }
                drawDots(in: context)
            }
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size); image.addRepresentation(rep); return image
        }
    }
}

/// Draws the dots; AppKit redraws it each frame of the clock.
@MainActor private final class DotsView: NSView {
    weak var owner: ParticleTextView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        owner?.drawDots(in: context)
    }
}
