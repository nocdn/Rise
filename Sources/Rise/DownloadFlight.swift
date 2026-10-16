import AppKit
import QuartzCore

/// Tuned in Playgrounds/download-flight.html; the math below mirrors that page step for
/// step, so values copied from it reproduce the same motion. Springs use the
/// (perceptual duration, bounce) pair of `CASpringAnimation(perceptualDuration:bounce:)`.
enum DownloadMotion {
    static let iconSize = 28.0
    static let popFrom = 0.5, popResponse = 0.28, popBounce = 0.3
    static let launchDelay = 0.0
    /// For a 600 pt throw; longer throws take a little longer.
    static let duration = 0.56, distanceInfluence = 0.35
    static let arcHeight = 0.18, peakPosition = 0.35
    static let easing = (x1: 0.42, y1: 0.0, x2: 0.72, y2: 0.19)
    static let shrinkStart = 0.6, endScale = 0.24, shrinkCurve = 1.6
    static let lidOpenAt = 0.55, lidAngle = 24.0, lidLift = 1.2, bodyAngle = 9.0
    static let lidCloseDelay = 0.07, lidResponse = 0.24, lidBounce = 0.25
    /// How far below the rim the download lands inside the box.
    static let depth = 4.0
    static let kick = 1.8, tilt = 2.0, squash = 0.0, directionInfluence = 1.0
    static let reactResponse = 0.34, reactBounce = 0.4
    /// With the sidebar collapsed, the archive slides in on its own tile and leaves
    /// shortly after the last download lands, in case more follow.
    static let trayInResponse = 0.3, trayInBounce = 0.28, trayOutResponse = 0.3, trayOutBounce = 0.0
    static let trayHold = 0.5
}

/// A damped spring integrated in 1 ms steps, matching the playground's.
struct MotionSpring {
    var value: Double, velocity = 0.0, target: Double
    private var stiffness = 0.0, damping = 0.0
    init(_ value: Double = 0) { self.value = value; target = value }
    mutating func configure(response: Double, bounce: Double) {
        let ratio = 1 - min(0.95, max(0, bounce))
        stiffness = pow(2 * .pi/response, 2); damping = 4 * .pi*ratio/response
    }
    mutating func step(_ dt: Double) {
        var left = dt
        while left > 0 {
            let h = min(0.001, left)
            velocity += (-stiffness*(value-target) - damping*velocity)*h; value += velocity*h
            left -= 0.001
        }
    }
    func isResting(within tolerance: Double) -> Bool { abs(value-target) < tolerance && abs(velocity) < tolerance*10 }
    /// Peak displacement after a unit velocity kick, so a kick can be specified in points.
    static func unitPeak(response: Double, bounce: Double) -> Double {
        var spring = MotionSpring(0); spring.configure(response: response, bounce: bounce); spring.velocity = 1
        var peak = 0.0, t = 0.0
        while t < 2 { spring.step(0.004); peak = max(peak, abs(spring.value)); t += 0.004 }
        return peak == 0 ? 1 : peak
    }
}

/// Downloads thrown along an arc into the archive, which opens to catch them and
/// recoils along the direction they arrived from. Coordinates are y-down points.
struct DownloadFlightModel {
    typealias M = DownloadMotion
    struct Flight {
        let id = UUID()
        let start: Double, origin: CGPoint, control: CGPoint, entry: CGPoint
        /// The arc's direction where it reaches the box.
        let direction: CGVector
        let duration: Double, rim: Double
        var pop: MotionSpring
        var impacted = false, done = false
        var position: CGPoint, scale = 1.0, opacity = 1.0
    }
    private(set) var flights: [Flight] = []
    private(set) var time = 0.0
    private(set) var lid = MotionSpring(0)
    private(set) var hinge = ArchiveGlyph.Hinge.left
    private(set) var closeAt = 0.0
    private(set) var offsetX = MotionSpring(0), offsetY = MotionSpring(0), rotation = MotionSpring(0), squash = MotionSpring(0)
    /// Whether the archive arrives on its own tile, and how far it has slid in.
    let usesTray: Bool
    private(set) var tray = MotionSpring(0)
    private static let ease = CubicEasing(M.easing.x1, M.easing.y1, M.easing.x2, M.easing.y2)
    private static let reactionPeak = MotionSpring.unitPeak(response: M.reactResponse, bounce: M.reactBounce)

    init(usesTray: Bool = false) {
        self.usesTray = usesTray
        configureReaction()
    }
    var pose: ArchiveGlyph.Pose {
        ArchiveGlyph.Pose(offset: CGPoint(x: offsetX.value, y: offsetY.value), rotation: rotation.value,
                          squash: squash.value, open: lid.value, hinge: hinge)
    }
    var isIdle: Bool {
        flights.isEmpty && time >= closeAt && lid.value < 1e-4 && (!usesTray || (tray.target == 0 && tray.isResting(within: 1e-3)))
            && [offsetX, offsetY, rotation, squash].allSatisfy { $0.isResting(within: 1e-3) }
    }

    /// Throws a download from `origin` into the archive drawn in the 28 pt `archive` button rect.
    mutating func launch(from origin: CGPoint, into archive: CGRect) {
        let rim = archive.minY+ArchiveGlyph.rim
        let entry = CGPoint(x: archive.midX, y: rim+M.depth)
        let dx = entry.x-origin.x, dy = entry.y-origin.y, distance = hypot(dx, dy), length = distance == 0 ? 1 : distance
        // Bulge the arc upward; the control point sits at twice the apex height.
        var normal = CGVector(dx: dy/length, dy: -dx/length)
        if normal.dy > 0 { normal = CGVector(dx: -normal.dx, dy: -normal.dy) }
        let base = CGPoint(x: origin.x+(entry.x-origin.x)*M.peakPosition, y: origin.y+(entry.y-origin.y)*M.peakPosition)
        let control = CGPoint(x: base.x+normal.dx*M.arcHeight*length*2, y: base.y+normal.dy*M.arcHeight*length*2)
        let tail = hypot(entry.x-control.x, entry.y-control.y), tailLength = tail == 0 ? 1 : tail
        var pop = MotionSpring(M.popFrom); pop.target = 1; pop.configure(response: M.popResponse, bounce: M.popBounce)
        var flight = Flight(start: time, origin: origin, control: control, entry: entry,
                            direction: CGVector(dx: (entry.x-control.x)/tailLength, dy: (entry.y-control.y)/tailLength),
                            duration: M.duration*pow(length/600, M.distanceInfluence), rim: rim, pop: pop, position: origin)
        render(&flight)
        flights.append(flight)
    }
    mutating func step(_ dt: Double) {
        time += dt
        for index in flights.indices {
            var flight = flights[index]
            flight.pop.step(dt); render(&flight)
            flights[index] = flight
        }
        flights.removeAll { $0.done }
        updateLid(dt)
        offsetX.step(dt); offsetY.step(dt); rotation.step(dt); squash.step(dt)
        if usesTray { updateTray(dt) }
    }

    private mutating func render(_ flight: inout Flight) {
        let t = time-flight.start
        var position: CGPoint, scale: Double, opacity = 1.0
        if t < M.launchDelay { position = flight.origin; scale = 1 }
        else {
            let u = min(1, (t-M.launchDelay)/flight.duration), e = Self.ease(u)
            position = Self.point(flight.origin, flight.control, flight.entry, e)
            let k = e <= M.shrinkStart ? 0 : (e-M.shrinkStart)/(1-M.shrinkStart)
            scale = 1+(M.endScale-1)*pow(min(1, max(0, k)), M.shrinkCurve)
            // The box reacts the moment the download drops past its rim, pushed along
            // the direction it was travelling; the box's front then hides it.
            if !flight.impacted && (position.y >= flight.rim || u >= 1) {
                let tx = 2*(1-e)*(flight.control.x-flight.origin.x)+2*e*(flight.entry.x-flight.control.x)
                let ty = 2*(1-e)*(flight.control.y-flight.origin.y)+2*e*(flight.entry.y-flight.control.y)
                let tangent = hypot(tx, ty), length = tangent == 0 ? 1 : tangent
                flight.impacted = true; closeAt = max(closeAt, time+M.lidCloseDelay)
                kick(CGVector(dx: tx/length, dy: ty/length))
            }
            if u >= 1 {
                let after = t-M.launchDelay-flight.duration
                opacity = 1-min(1, after/0.06)
                if after >= 0.06 { flight.done = true }
            }
        }
        flight.position = position; flight.scale = scale*flight.pop.value; flight.opacity = opacity
    }
    /// Hinged on the side away from the incoming download, so it opens toward it.
    /// A closing lid stops against the box instead of swinging through it.
    private mutating func updateLid(_ dt: Double) {
        lid.configure(response: M.lidResponse, bounce: M.lidBounce)
        let waiting = flights.first { !$0.impacted && time-$0.start-M.launchDelay >= $0.duration*M.lidOpenAt }
        if let waiting, lid.target == 0 { hinge = waiting.direction.dx < 0 ? .left : .right }
        lid.target = waiting != nil || time < closeAt ? 1 : 0
        lid.step(dt)
        if lid.value < 0 { lid.value = 0; lid.velocity = max(0, lid.velocity) }
    }
    private mutating func updateTray(_ dt: Double) {
        let shown = !flights.isEmpty || time < closeAt+M.trayHold
        if shown { tray.configure(response: M.trayInResponse, bounce: M.trayInBounce) }
        else { tray.configure(response: M.trayOutResponse, bounce: M.trayOutBounce) }
        tray.target = shown ? 1 : 0
        tray.step(dt)
    }
    private mutating func configureReaction() {
        for keyPath in [\Self.offsetX, \Self.offsetY, \Self.rotation, \Self.squash] {
            self[keyPath: keyPath].configure(response: M.reactResponse, bounce: M.reactBounce)
        }
    }
    private mutating func kick(_ direction: CGVector) {
        configureReaction()
        let toward = CGVector(dx: direction.dx*M.directionInfluence, dy: 1+(direction.dy-1)*M.directionInfluence)
        let size = hypot(toward.dx, toward.dy), length = size == 0 ? 1 : size
        let x = toward.dx/length, y = toward.dy/length, velocity = 1/Self.reactionPeak
        offsetX.velocity += velocity*x*M.kick; offsetY.velocity += velocity*y*M.kick
        rotation.velocity += velocity*x*M.tilt; squash.velocity += velocity*max(0, y)*M.squash
    }
    static func point(_ a: CGPoint, _ control: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: (1-t)*(1-t)*a.x+2*(1-t)*t*control.x+t*t*b.x, y: (1-t)*(1-t)*a.y+2*(1-t)*t*control.y+t*t*b.y)
    }
}

/// One download in flight: a blue disc with a white arrow, drawn in the playground's
/// 32-unit space and hidden wherever the archive covers it.
final class DownloadIconView: FlippedView {
    static let padding: CGFloat = 6
    var scale: CGFloat = 1
    /// The archive's silhouette in this view's coordinates.
    var cover: CGPath? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func place(at center: CGPoint, scale: CGFloat) {
        self.scale = scale
        let half = DownloadMotion.iconSize*scale/2+Self.padding
        frame = CGRect(x: center.x-half, y: center.y-half, width: 2*half, height: 2*half)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, scale > 0 else { return }
        if let cover {
            context.addRect(bounds); context.addPath(cover); context.clip(using: .evenOdd)
        }
        let unit = DownloadMotion.iconSize*scale/32
        context.translateBy(x: Self.padding, y: Self.padding); context.scaleBy(x: unit, y: unit)
        let disc = CGRect(x: 1, y: 1, width: 30, height: 30)
        // Shadow offsets ignore flipping: negative is down. The playground's shadow scales with the icon.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1.5*scale), blur: 2.5*scale, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.setFillColor(NSColor(hex: 0x1E74F0).cgColor); context.fillEllipse(in: disc)
        context.restoreGState()
        context.saveGState()
        context.addEllipse(in: disc); context.clip()
        let colors = [NSColor(hex: 0x58A8FF).cgColor, NSColor(hex: 0x1E74F0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 16, y: 1), end: CGPoint(x: 16, y: 31), options: [])
        }
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor); context.setLineWidth(1)
        context.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 29, height: 29))
        context.move(to: CGPoint(x: 16, y: 8.6)); context.addLine(to: CGPoint(x: 16, y: 21.8))
        context.move(to: CGPoint(x: 10.6, y: 16.6)); context.addLine(to: CGPoint(x: 16, y: 22)); context.addLine(to: CGPoint(x: 21.4, y: 16.6))
        context.setStrokeColor(NSColor.white.cgColor); context.setLineWidth(2.6)
        context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
    }
}

/// Draws download flights above the whole window, with a stand-in archive on top
/// that hides each download as it drops in. Removes itself once everything settles.
@MainActor final class DownloadFlightView: FlippedView {
    private(set) var model: DownloadFlightModel
    private weak var button: ArchiveButton?
    private let tile = Surface(radius: 10)
    private let glyph = ArchiveGlyphView()
    private var icons: [UUID: DownloadIconView] = [:]
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    var finished: (() -> Void)?
    static let tileSize: CGFloat = 36, tileMargin: CGFloat = 12
    /// Room around the archive for its lid to lift and the whole thing to recoil.
    private static let glyphMargin: CGFloat = 12

    /// Lands in the sidebar's archive button, or, with no button, on a tile that slides
    /// into the window's bottom-left corner.
    init(button: ArchiveButton?, tint: NSColor, tileColor: NSColor, tileBorder: NSColor) {
        self.button = button
        model = DownloadFlightModel(usesTray: button == nil)
        super.init(frame: .zero)
        wantsLayer = true
        tile.fill = tileColor; tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 0.5; tile.layer?.borderColor = tileBorder.cgColor
        tile.shadow = chromeShadow(opacity: 0.16, blur: 6, offset: -1)
        tile.isHidden = button != nil
        glyph.tint = tint; glyph.buttonOrigin = CGPoint(x: Self.glyphMargin, y: Self.glyphMargin)
        addSubview(tile); addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); render() }

    /// The 28 pt archive button rect at rest, in this view's coordinates.
    var restingArchive: CGRect {
        if let button { return button.convert(button.bounds, to: self) }
        let side = Self.tileSize, inset = (side-28)/2
        return CGRect(x: Self.tileMargin+inset, y: bounds.height-Self.tileMargin-side+inset, width: 28, height: 28)
    }
    /// Off-screen to the left while hidden; a spring carries it in, slightly overshooting.
    private var slide: CGFloat {
        guard model.usesTray else { return 0 }
        return -(1-model.tray.value)*(Self.tileMargin+Self.tileSize+12)
    }
    func launch(from origin: CGPoint) {
        model.launch(from: origin, into: restingArchive)
        button?.isGlyphHidden = true
        if link == nil {
            lastTick = CACurrentMediaTime()
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common); self.link = link
        }
        render()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        model.step(min(0.05, now-(lastTick ?? now))); lastTick = now
        render()
        if model.isIdle { finish() }
    }
    func finish() {
        link?.invalidate(); link = nil
        button?.isGlyphHidden = false
        finished?()
    }
    private func render() {
        var archive = restingArchive; archive.origin.x += slide
        let inset = (Self.tileSize-28)/2
        tile.frame = archive.insetBy(dx: -inset, dy: -inset)
        glyph.frame = archive.insetBy(dx: -Self.glyphMargin, dy: -Self.glyphMargin)
        glyph.pose = model.pose
        let cover = ArchiveGlyph.silhouette(model.pose, origin: archive.origin)
        for flight in model.flights {
            let icon = icons[flight.id] ?? {
                let view = DownloadIconView(); addSubview(view, positioned: .below, relativeTo: glyph)
                icons[flight.id] = view; return view
            }()
            icon.place(at: flight.position, scale: flight.scale)
            icon.alphaValue = flight.opacity
            var shift = CGAffineTransform(translationX: -icon.frame.minX, y: -icon.frame.minY)
            icon.cover = cover.copy(using: &shift)
        }
        let live = Set(model.flights.map(\.id))
        for (id, icon) in icons where !live.contains(id) { icon.removeFromSuperview(); icons[id] = nil }
    }
}

@MainActor extension BrowserController {
    /// Throws a download from the pointer into the archive, or from the page's center
    /// when the pointer is outside the window.
    func launchDownloadFlight() {
        guard let window, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let flight = downloadFlight ?? {
            let tray = !sidebarVisible || sidebar.isHidden
            // The tile is a little lighter than the sidebar, with a hairline edge to set it off the page.
            let dark = theme == .dark
            // On the tile the archive takes the stronger text color, so it stands out from the page.
            let view = DownloadFlightView(button: tray ? nil : sidebar.archiveButton, tint: tray ? theme.text : theme.sidebarIcon,
                                          tileColor: theme.background.blended(withFraction: dark ? 0.13 : 0.7, of: .white) ?? theme.background,
                                          tileBorder: dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.09))
            view.frame = root.bounds; view.autoresizingMask = [.width, .height]
            view.finished = { [weak self, weak view] in
                view?.removeFromSuperview()
                if self?.downloadFlight === view { self?.downloadFlight = nil }
            }
            return view
        }()
        if flight.superview == nil { root.addSubview(flight) }
        downloadFlight = flight
        flight.launch(from: downloadFlightOrigin)
    }
    var downloadFlightOrigin: CGPoint {
        guard let window else { return CGPoint(x: pageShadow.frame.midX, y: pageShadow.frame.midY) }
        let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return root.bounds.contains(point) ? point : CGPoint(x: pageShadow.frame.midX, y: pageShadow.frame.midY)
    }
    /// A free name in `folder`, numbered like Finder ("report 2.pdf") when taken.
    nonisolated static func downloadDestination(for suggestedName: String, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        var name = suggestedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Download" }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name), number = 2
        while isTaken(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
