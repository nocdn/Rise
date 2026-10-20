import AppKit
import QuartzCore

// Clip rather than insert an ellipsis, then soften only the overflowing edge.
class FadingTextField: NSTextField {
    private let fade = CAGradientLayer()
    private var fadeBoundary: CGFloat?
    static let fadeMovementKey = "Rise.TextFadeBoundary"
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        cell?.usesSingleLineMode = true; lineBreakMode = .byClipping
        wantsLayer = true; clipsToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var stringValue: String {
        get { super.stringValue }
        set { super.stringValue = newValue; needsLayout = true }
    }
    override func layout() {
        super.layout()
        updateFade()
    }
    /// Keep the text at its full size while moving only its clipping/fade edge.
    /// Presentation values make a quick hover reversal continue smoothly.
    func setFadeBoundary(_ width: CGFloat?, duration: CFTimeInterval = 0) {
        guard fadeBoundary != width else { return }
        let old = fade.presentation()?.locations ?? fade.locations
        fadeBoundary = width
        updateFade()
        if duration > 0, let old, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let movement = CABasicAnimation(keyPath: "locations")
            movement.fromValue = old; movement.toValue = fade.locations
            movement.duration = duration
            movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.add(movement, forKey: Self.fadeMovementKey)
        } else { fade.removeAnimation(forKey: Self.fadeMovementKey) }
    }
    private func updateFade() {
        let width = max(1, bounds.width)
        let edge = min(width, max(0, fadeBoundary ?? width))
        let overflowing = attributedStringValue.size().width > edge - 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.locations = [0, NSNumber(value: Double(max(0, edge-(overflowing ? 18 : 0))/width)), NSNumber(value: Double(edge/width)), 1]
        // Retain the sidebar mask even when the whole URL fits, so its edge can
        // animate inward as controls appear without resizing the native glyphs.
        layer?.mask = currentEditor() == nil && (overflowing || fadeBoundary != nil) ? fade : nil
        CATransaction.commit()
    }
}

/// The tab's loading sweep: a solid band where the load has reached, with a gradient trailing
/// behind it to the left, as long as the tab, slid in from the left as the page loads. The front
/// follows the progress on a spring, frame by frame, keeping its speed as each new report comes:
/// restarting an ease for every report stalled it at each one, which read as flickering.
final class TabLoadingBackground: FlippedView {
    /// The solid band at the front, in points.
    static let head: CGFloat = 12
    /// How far past the tab's end a finished load's front carries on, out of sight, so it
    /// doesn't slow to a stop at the end; it fades from the moment it reaches it.
    static let overrun: CGFloat = 48
    private let fillLayer = CAGradientLayer()
    private(set) var loading = false
    private(set) var fraction: CGFloat = 0
    /// The load finished: the sweep fades once its front reaches the tab's end.
    private var fadesAtEnd = false
    /// Where the front is, how fast it's moving there, and where it's going, in points.
    private var front: CGFloat = 0, speed: CGFloat = 0, target: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// The spring's angular frequency: critically damped, it settles in about half a second.
    static let stiffness: CGFloat = 11
    init() {
        super.init(frame: .zero); wantsLayer = true
        layer?.cornerRadius = 12; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        fillLayer.anchorPoint = .zero; fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5); fillLayer.opacity = 0
        layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// A hard reload's progress is red-pink rather than the accent, with the same fade.
    static let hardReloadColor = NSColor(hex: 0xF03C64)
    func update(loading: Bool, progress: Double, theme: RiseTheme, hard: Bool = false) {
        // The finished sweep keeps its color while it fades, though the tab is no longer hard reloading.
        if loading || fillLayer.colors == nil {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let color = hard ? Self.hardReloadColor : theme.accent
            fillLayer.colors = [0.03, 0.16, 0.16].map { color.withAlphaComponent($0).cgColor }
            CATransaction.commit()
        }
        if loading {
            let starting = !self.loading
            if starting {
                fadesAtEnd = false
                fillLayer.removeAllAnimations(); fraction = 0
                setWidth(0, animated: false)
                fillLayer.opacity = 1
            }
            self.loading = true
            let next = max(fraction, min(0.97, max(0.07, CGFloat(progress))))
            if next != fraction {
                fraction = next
                // A new load always grows from the left, not from the last one's full width.
                setWidth(bounds.width * fraction, animated: true, from: starting ? 0 : nil)
            }
        } else if self.loading {
            self.loading = false; fraction = 1
            fadesAtEnd = true
            setWidth(bounds.width+Self.overrun, animated: true)
        }
    }
    private func fadeOut() {
        fadesAtEnd = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fillLayer.presentation()?.opacity ?? 1; fade.toValue = 0
        fade.duration = 0.35; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fillLayer.opacity = 0; fillLayer.add(fade, forKey: "finish")
    }
    override func layout() {
        super.layout()
        // The tab's length of colour, strengthening to the solid band at its front.
        let length = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fillLayer.bounds = CGRect(x: 0, y: 0, width: length, height: bounds.height)
        let band = 1-min(1, Self.head/max(1, length))
        fillLayer.locations = [0, band, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
        // A resize moves where the front is headed; one already moving keeps going.
        let width = loading ? bounds.width * fraction : fraction >= 1 ? length+Self.overrun : 0
        if link != nil { target = width; front = min(front, width); place() } else { setWidth(width, animated: false) }
    }
    /// How far from the left the colour reaches now, for checks.
    var shownWidth: CGFloat { front }
    /// Sends the front of the band to `width` from the left: the colour shown so far.
    private func setWidth(_ width: CGFloat, animated: Bool, from startWidth: CGFloat? = nil) {
        target = width
        if let startWidth { front = startWidth; speed = 0 }
        // Off any screen, no frames come to move it: it goes there at once.
        guard animated, window?.screen != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            front = width; speed = 0; stopFollowing(); place(); return
        }
        if link == nil {
            let link = displayLink(target: self, selector: #selector(follow(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common); self.link = link; lastTick = CACurrentMediaTime()
        }
        place()
    }
    @objc private func follow(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = CGFloat(min(1.0/30, max(0, now-lastTick))); lastTick = now
        // The exact step of a critically damped spring towards the target.
        let omega = Self.stiffness, offset = front-target, decay = exp(-omega*dt)
        let carried = speed+omega*offset
        front = target+(offset+carried*dt)*decay
        speed = (speed-omega*carried*dt)*decay
        // Never past where it's going. With speed only ever towards a target that only moves
        // on, the critically damped front doesn't turn back.
        if front >= target { front = target; speed = 0 }
        if abs(front-target) < 0.25, abs(speed) < 2 { front = target; speed = 0; stopFollowing() }
        place()
    }
    private func stopFollowing() { link?.invalidate(); link = nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, link != nil { front = target; speed = 0; stopFollowing(); place() }
    }
    private func place() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fillLayer.position = CGPoint(x: front-fillLayer.bounds.width, y: 0)
        CATransaction.commit()
        if fadesAtEnd, front >= bounds.width { fadeOut() }
    }
}

final class LinkStatusPill: Surface {
    let text = ShimmeringTextField(frame: .zero)
    let peekPrefix = label("Open ", size: 12, weight: .medium)
    let peekSuffix = label(" in Peek", size: 12, weight: .medium)
    private(set) var showsPeekHint = false
    /// Inside a Peek, where another Peek can't open: the hint says so instead.
    private(set) var peekBlocked = false
    private(set) var url: URL?
    private(set) var ready = false
    private var restingFrame = NSRect.zero
    var isShimmering: Bool { text.isShimmering }
    init() {
        super.init(radius: 13)
        layer?.cornerCurve = .circular
        shadow = chromeShadow(opacity: 0.075, blur: 3, offset: -0.5)
        text.font = .systemFont(ofSize: 12, weight: .medium)
        for hint in [peekPrefix, peekSuffix] {
            hint.cell?.usesSingleLineMode = true; hint.lineBreakMode = .byClipping
        }
        addSubview(peekPrefix); addSubview(text); addSubview(peekSuffix)
        peekPrefix.isHidden = true; peekSuffix.isHidden = true; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ url: URL?, theme: RiseTheme, peek: Bool = false, blocked: Bool = false) {
        if self.url != url { ready = false; text.stopShimmer() }
        let peek = url != nil && peek
        if showsPeekHint != peek { text.stopShimmer() }
        showsPeekHint = peek; peekPrefix.isHidden = !peek; peekSuffix.isHidden = !peek
        peekBlocked = peek && blocked; peekPrefix.stringValue = peekBlocked ? "Cannot open " : "Open "
        self.url = url; isHidden = url == nil
        guard let url else { return }
        let value = peek ? url.absoluteString : AddressDisplay.text(url.absoluteString)
        text.stringValue = value; text.textColor = theme.text.withAlphaComponent(0.8)
        peekPrefix.textColor = theme.text.withAlphaComponent(0.6); peekSuffix.textColor = peekPrefix.textColor
        text.shimmerColor = theme.linkShimmer
        fill = theme.status
        layer?.borderWidth = 0.75; layer?.borderColor = theme.text.withAlphaComponent(0.18).cgColor
        setAccessibilityLabel(peek ? "\(peekPrefix.stringValue)\(url.absoluteString) in Peek" : url.absoluteString); toolTip = url.absoluteString
    }
    func markReady(_ url: URL) {
        guard self.url == url, !ready else { return }
        ready = true
        text.startShimmer()
    }
    func place(in page: NSRect) {
        // Measure the glyphs independently of the previous field frame and leave
        // room for NSTextFieldCell's internal drawing insets.
        let hintInset: CGFloat = showsPeekHint ? 6 : 0
        let prefixWidth = showsPeekHint ? peekPrefix.attributedStringValue.size().width+hintInset : 0
        let suffixWidth = showsPeekHint ? peekSuffix.attributedStringValue.size().width+hintInset : 0
        let width = min(max(80, text.attributedStringValue.size().width + prefixWidth + suffixWidth + 26 - 2*hintInset + (showsPeekHint ? 4 : 0)), max(0, min(650, page.width - 28)))
        restingFrame = NSRect(x: page.minX + 10, y: page.maxY - 36, width: width, height: 26)
        applyPosition()
        peekPrefix.frame = NSRect(x: 12, y: (26-peekPrefix.intrinsicContentSize.height)/2, width: prefixWidth, height: peekPrefix.intrinsicContentSize.height)
        // Overlap only the cells' drawing slack. The literal spaces in the hints
        // provide the glyph spacing, while their full widths prevent clipping.
        text.frame = NSRect(x: 12 + prefixWidth - hintInset, y: (26 - text.intrinsicContentSize.height)/2,
                            width: max(0, width - 24 - prefixWidth - suffixWidth + 2*hintInset), height: text.intrinsicContentSize.height)
        peekSuffix.frame = NSRect(x: text.frame.maxX - hintInset, y: (26-peekSuffix.intrinsicContentSize.height)/2, width: suffixWidth, height: peekSuffix.intrinsicContentSize.height)
        text.needsLayout = true
    }
    /// A quick side-to-side error shake, for a Peek asked for where one can't open.
    func shake() {
        guard !isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -4, 4, -2, 2, 0]
        shake.duration = 0.32
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shake, forKey: "shake")
    }
    private func applyPosition() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = restingFrame
        CATransaction.commit()
    }
}
