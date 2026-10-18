import AppKit
import QuartzCore

/// Springs the find bar, info plaque and the download tray share.
enum DownloadMotion {
    static let trayInResponse = 0.3, trayInBounce = 0.28, trayOutResponse = 0.3, trayOutBounce = 0.0
    /// With the sidebar hidden, the tile stays this long after the last download lands.
    static let trayHold = 0.5
}

/// The iOS app's download flight (`MobileDownloadFlightPath`), mirrored to arc over the
/// top: the card pops out near the click, rises, then accelerates round a shallow curve
/// and collapses into the downloads button, which takes a small jolt along the way it came.
/// Only the side of the curve and the lean that goes with it differ from the phone's.
struct DownloadFlightPath {
    static let cardSize = CGSize(width: 232, height: DownloadRow.height)
    static let cornerRadius: CGFloat = 12
    static let reactionDuration = 0.55
    private static let ease = CubicEasing(0.42, 0, 0.72, 0.19)
    private static let pop = ClosedSpring(response: 0.24, damping: 0.78)
    private static let reaction = ClosedSpring(response: 0.34, damping: 0.6)
    let origin: CGPoint, destination: CGPoint, control: CGPoint
    let duration: Double
    var totalDuration: Double { duration+Self.reactionDuration }

    /// In y-down coordinates, as on iOS.
    init(from origin: CGPoint, to destination: CGPoint, within bounds: CGRect) {
        self.origin = origin; self.destination = destination
        let dx = destination.x-origin.x, dy = destination.y-origin.y
        let distance = hypot(dx, dy), length = max(1, distance)
        var normal = CGVector(dx: -dy/length, dy: dx/length)
        // The phone's curve bows downward; here it bows upward, over the page, towards a
        // button low in the sidebar.
        if normal.dy > 0 { normal = CGVector(dx: -normal.dx, dy: -normal.dy) }
        // The slight rise before the card sweeps away.
        let x = origin.x+dx*0.35+normal.dx*distance*0.36
        let y = origin.y+dy*0.35+normal.dy*distance*0.36
        control = CGPoint(x: min(bounds.maxX-12, max(bounds.minX+12, x)),
                          y: min(bounds.maxY-12, max(bounds.minY+12, y)))
        duration = min(0.54, max(0.34, 0.44*pow(Double(distance)/600, 0.2)))
    }

    struct Pose { let position: CGPoint; let scale: CGFloat; let rotation: CGFloat; let opacity: Float }
    func pose(at time: Double) -> Pose {
        let u = min(1, max(0, time/duration)), p = Self.ease(u), q = 1-p
        let position = CGPoint(x: q*q*origin.x+2*q*p*control.x+p*p*destination.x,
                               y: q*q*origin.y+2*q*p*control.y+p*p*destination.y)
        let shrink = pow(max(0, (p-0.6)/0.4), 1.6)
        let pop = 0.42+0.58*Self.pop(max(0, time))
        let scale = (0.86+(0.025-0.86)*shrink)*pop
        // Mirrored with the curve, so it leans the other way to the phone.
        let direction = destination.x >= origin.x ? -1.0 : 1.0
        return Pose(position: position, scale: scale, rotation: direction*0.055*sin(.pi*p),
                    opacity: Float(1-max(0, (p-0.9)/0.1)))
    }

    /// A velocity impulse: about 2 points along the incoming tangent, a small tilt and
    /// squeeze, then a damped return through rest.
    func impact(at time: Double) -> CATransform3D {
        guard time > 0, time < Self.reactionDuration else { return CATransform3DIdentity }
        let dx = destination.x-control.x, dy = destination.y-control.y, length = max(1, hypot(dx, dy))
        let k = Self.reaction.value(from: 0, to: 0, velocity: 46, at: time)
        var result = CATransform3DMakeTranslation(dx/length*2.2*k, dy/length*2.2*k, 0)
        result = CATransform3DRotate(result, dx/length*0.035*k, 0, 0, 1)
        return CATransform3DScale(result, 1+0.025*k, 1-0.04*k, 1)
    }
}

/// Download flights above the whole window, drawn in layers it owns (y down, as on iOS) so
/// AppKit never moves them. Each download's card flies on render-server keyframes into a
/// stand-in for the downloads button, or, with the sidebar hidden, a tile that slides into
/// the bottom-left corner. Each flight's jolt is additive, so quick downloads don't cancel
/// one another's. It removes itself once everything has landed.
@MainActor final class DownloadFlight: NSView {
    static let tileSize: CGFloat = 36, tileMargin: CGFloat = 12
    private let root = CALayer(), landing = CALayer(), glyph = CALayer()
    private weak var button: DownloadsButton?
    /// The icon whose progress the stand-in shows, kept up to date even with the sidebar hidden.
    private weak var source: DownloadGlyphView?
    private let theme: RiseTheme, tint: NSColor
    private var endTime: CFTimeInterval = 0, endWork: DispatchWorkItem?
    var finished: (() -> Void)?
    var usesTray: Bool { button == nil }
    private(set) var flights = 0

    init(frame: NSRect, button: DownloadsButton?, source: DownloadGlyphView?, theme: RiseTheme, tint: NSColor) {
        self.button = button; self.source = source; self.theme = theme; self.tint = tint
        super.init(frame: frame)
        layer = root; wantsLayer = true
        root.isGeometryFlipped = true; root.masksToBounds = false
        landing.addSublayer(glyph)
        root.addSublayer(landing)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the downloads button sits, or the tile would, in this view.
    var landingFrame: CGRect {
        if let button, button.window != nil { return convert(button.bounds, from: button) }
        let side = Self.tileSize
        return CGRect(x: Self.tileMargin, y: bounds.height-Self.tileMargin-side, width: side, height: side)
    }

    func launch(_ item: DownloadList.Item, from origin: CGPoint) {
        let scale = window?.backingScaleFactor ?? 2
        let target = landingFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if flights == 0 { prepareLanding(target, scale: scale) }
        let path = DownloadFlightPath(from: origin, to: CGPoint(x: target.midX, y: target.midY), within: bounds)
        let card = Self.card(for: item, theme: theme, scale: scale)
        card.position = path.destination; card.opacity = 0
        root.insertSublayer(card, below: landing)
        CATransaction.commit()
        flights += 1
        let start = CACurrentMediaTime(), count = Int(ceil(path.totalDuration*120))
        var positions: [NSValue] = [], transforms: [NSValue] = [], opacity: [Float] = [], impacts: [NSValue] = []
        for index in 0...count {
            let time = path.totalDuration*Double(index)/Double(count), pose = path.pose(at: time)
            positions.append(NSValue(point: pose.position)); opacity.append(pose.opacity)
            var transform = CATransform3DMakeRotation(pose.rotation, 0, 0, 1)
            transform = CATransform3DScale(transform, pose.scale, pose.scale, 1)
            transforms.append(NSValue(caTransform3D: transform))
            impacts.append(NSValue(caTransform3D: path.impact(at: time-path.duration)))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { card.removeFromSuperlayer() }
        func animate(_ layer: CALayer, _ key: String, _ values: [Any], additive: Bool = false) {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values; animation.duration = path.totalDuration
            animation.beginTime = layer.convertTime(start, from: nil)
            animation.calculationMode = .linear; animation.isAdditive = additive
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            layer.add(animation, forKey: additive ? "download-impact-\(UUID())" : "download.\(key)")
        }
        animate(card, "position", positions)
        animate(card, "transform", transforms)
        animate(card, "opacity", opacity)
        animate(glyph, "transform", impacts, additive: true)
        CATransaction.commit()
        // A tap on the trackpad as it lands, as the phone gives one.
        DispatchQueue.main.asyncAfter(deadline: .now()+path.duration) { [weak self] in
            guard self?.window != nil else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        scheduleEnd(after: start+path.totalDuration)
    }

    /// The button's icon as it shows now, hidden underneath until the flights land; or the tile.
    private func prepareLanding(_ target: CGRect, scale: CGFloat) {
        landing.frame = target
        glyph.frame = landing.bounds.insetBy(dx: (target.width-28)/2, dy: (target.height-28)/2)
        glyph.contentsScale = scale; glyph.contentsGravity = .resize
        let shown = source?.displayed ?? (.idle, 0)
        glyph.contents = DownloadGlyph.image(state: shown.state, tint: tint, spin: shown.spin)
        if let button {
            button.isGlyphHidden = true
            landing.backgroundColor = nil; landing.shadowOpacity = 0; landing.borderWidth = 0
        } else {
            let dark = theme == .dark
            // A little lighter than the sidebar, with a hairline edge to set it off the page.
            landing.backgroundColor = (theme.background.blended(withFraction: dark ? 0.13 : 0.7, of: .white) ?? theme.background).cgColor
            landing.cornerRadius = 10; landing.cornerCurve = .continuous
            landing.borderWidth = 0.5
            landing.borderColor = (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.09)).cgColor
            landing.shadowColor = NSColor.black.cgColor; landing.shadowOpacity = 0.16
            landing.shadowRadius = 3; landing.shadowOffset = CGSize(width: 0, height: 1)
            slideTile(in: true)
        }
    }
    /// The tile springs in from beyond the window's left edge, slightly overshooting.
    private func slideTile(in coming: Bool, completion: (() -> Void)? = nil) {
        let away = -(Self.tileMargin+Self.tileSize+12)
        let animation = CASpringAnimation(perceptualDuration: coming ? DownloadMotion.trayInResponse : DownloadMotion.trayOutResponse,
                                          bounce: coming ? DownloadMotion.trayInBounce : DownloadMotion.trayOutBounce)
        animation.keyPath = "transform.translation.x"
        let shown = (landing.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? (coming ? away : 0)
        animation.fromValue = shown; animation.toValue = coming ? 0 : away
        animation.duration = animation.settlingDuration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        landing.setValue(coming ? 0 : away, forKeyPath: "transform.translation.x")
        landing.add(animation, forKey: "tray")
        CATransaction.commit()
    }
    private func scheduleEnd(after time: CFTimeInterval) {
        endTime = max(endTime, time)
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.end() }
        endWork = work
        let delay = endTime-CACurrentMediaTime()+(usesTray ? DownloadMotion.trayHold : 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+max(0, delay), execute: work)
    }
    private func end() {
        if usesTray { slideTile(in: false) { [weak self] in self?.finish() } } else { finish() }
    }
    func finish() {
        endWork?.cancel(); endWork = nil
        button?.isGlyphHidden = false
        root.sublayers?.filter { $0 !== landing }.forEach { $0.removeFromSuperlayer() }
        flights = 0
        finished?()
    }

    /// The download as its row in the downloads list shows it: the progress ring, the
    /// file's name and how much has come, on a card like the list's.
    static func card(for item: DownloadList.Item, theme: RiseTheme, scale: CGFloat) -> CALayer {
        let size = DownloadFlightPath.cardSize, dark = theme == .dark
        let card = CALayer()
        card.bounds = CGRect(origin: .zero, size: size)
        card.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor.white).cgColor
        card.cornerRadius = DownloadFlightPath.cornerRadius; card.cornerCurve = .continuous
        card.borderWidth = 0.5
        card.borderColor = (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.06)).cgColor
        card.shadowColor = NSColor.black.cgColor; card.shadowOpacity = 0.18
        card.shadowRadius = 10; card.shadowOffset = CGSize(width: 0, height: 4)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: card.cornerRadius, cornerHeight: card.cornerRadius, transform: nil)
        // As DownloadRow lays out its icon, ring, name and detail.
        let ring = CGRect(x: 10, y: (size.height-28)/2, width: 28, height: 28)
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: ring.midX, y: ring.midY), radius: 10, startAngle: -.pi/2, endAngle: 3 * .pi/2, clockwise: false)
        let fraction = item.fraction
        for (color, end) in [(theme.text.withAlphaComponent(0.14), 1.0), (DownloadGlyph.blue, fraction ?? 0.25)] {
            let shape = CAShapeLayer()
            shape.frame = card.bounds; shape.path = circle; shape.fillColor = nil
            shape.lineWidth = 2.5; shape.lineCap = .round
            shape.strokeColor = color.cgColor; shape.strokeEnd = CGFloat(end)
            card.addSublayer(shape)
        }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let detail = item.totalBytes > 0 ? "\(format(item.receivedBytes)) of \(format(item.totalBytes))" : "Starting…"
        let width = size.width-45-12
        for (text, font, color, frame) in [
            (item.record.url.lastPathComponent, NSFont.systemFont(ofSize: 13), theme.text, CGRect(x: 45, y: 6, width: width, height: 17)),
            (detail, NSFont.systemFont(ofSize: 11), theme.muted, CGRect(x: 45, y: 24, width: width, height: 14)),
        ] {
            let label = CATextLayer()
            label.frame = frame; label.contentsScale = scale
            label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            label.truncationMode = .middle; label.isWrapped = false
            card.addSublayer(label)
        }
        return card
    }
}

@MainActor extension BrowserController {
    /// Throws a download from the pointer into the downloads button, or from the page's
    /// center when the pointer is outside the window.
    func launchDownloadFlight(_ item: DownloadList.Item) {
        guard let window, window.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            return
        }
        let tray = !sidebarVisible || sidebar.isHidden
        root.layoutSubtreeIfNeeded()
        let flight = downloadFlight ?? {
            // On the tile the icon takes the stronger text color, so it stands out from the page.
            let view = DownloadFlight(frame: root.bounds, button: tray ? nil : sidebar.archiveButton, source: sidebar.archiveButton.glyph, theme: theme,
                                      tint: tray ? theme.text : theme.sidebarIcon)
            view.autoresizingMask = [.width, .height]
            view.finished = { [weak self, weak view] in
                view?.removeFromSuperview()
                if self?.downloadFlight === view { self?.downloadFlight = nil }
            }
            return view
        }()
        if flight.superview == nil { root.addSubview(flight) }
        downloadFlight = flight
        flight.launch(item, from: downloadFlightOrigin)
    }
    var downloadFlightOrigin: CGPoint {
        guard let window else { return CGPoint(x: pageShadow.frame.midX, y: pageShadow.frame.midY) }
        let point = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return root.bounds.contains(point) ? point : CGPoint(x: pageShadow.frame.midX, y: pageShadow.frame.midY)
    }
    /// The downloads button follows the downloads in progress: how much of them has come, or
    /// a turning loop while any of their sizes is unknown.
    func updateDownloadsButton() {
        let active = downloads.items.filter { !$0.isFinished }
        let state: DownloadGlyph.State
        if active.isEmpty { state = .idle }
        else if active.allSatisfy({ $0.totalBytes > 0 }) {
            let total = active.reduce(Int64(0)) { $0+$1.totalBytes }, received = active.reduce(Int64(0)) { $0+$1.receivedBytes }
            state = .progress(min(1, Double(received)/Double(max(1, total))))
        } else { state = .indeterminate }
        sidebar.archiveButton.glyph.setState(state)
    }
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
