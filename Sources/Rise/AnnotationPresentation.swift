import AppKit

/// The page-world badge takes its paint from the actual Ask panel rather than maintaining a
/// second light/dark palette. Its native collapsing stand-in uses that same panel styling.
@MainActor enum AnnotationAppearance {
    static let badgeRadius: CGFloat = 7
    static func badgeStyle(panel: Surface, theme: RiseTheme) -> [String: String] {
        func css(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? .black
            return "rgba(\(Int((c.redComponent*255).rounded())),\(Int((c.greenComponent*255).rounded())),\(Int((c.blueComponent*255).rounded())),\(c.alphaComponent))"
        }
        let layer = panel.layer!
        let background = layer.backgroundColor.flatMap(NSColor.init(cgColor:)) ?? theme.popup
        let border = layer.borderColor.flatMap(NSColor.init(cgColor:)) ?? theme.border
        return ["background": css(background), "color": css(theme.text), "border": css(border),
                "borderWidth": "\(layer.borderWidth)px", "radius": "\(badgeRadius)px",
                "openingFade": "\(max(0.12, CardMotion.selected.fadeIn))s",
                "shadow": "0 \(-layer.shadowOffset.height)px \(layer.shadowRadius*2)px rgba(0,0,0,\(layer.shadowOpacity))"]
    }
}

/// One surface shrinks into its number. The question/answer fades quickly while the number
/// appears in the middle; the real page badge takes over only once the surface has landed.
@MainActor final class AnnotationCollapse: FlippedView {
    static let duration = 0.18
    static let handoffDuration = 0.06
    let panel = Surface(radius: FindBar.radius)
    private let content = FlippedView(), image = NSImageView(), number: NSTextField
    private var from = NSRect.zero, to = NSRect.zero
    private var link: CADisplayLink?, started: CFTimeInterval = 0
    private var arrived: (() -> Void)?, done: (() -> Void)?
    init(number: Int, theme: RiseTheme, snapshot: NSImage?) {
        self.number = label(String(number), size: 11, weight: .semibold)
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false
        FindBar.stylePanel(panel, content: content); FindBar.applyPanelTheme(panel, theme: theme)
        self.number.alignment = .center; self.number.textColor = theme.text
        image.image = snapshot; image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true; self.number.wantsLayer = true
        content.addSubview(image); content.addSubview(self.number); panel.addSubview(content); addSubview(panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    func start(from: NSRect, to: NSRect, arrived: @escaping () -> Void, done: @escaping () -> Void) {
        self.from = from; self.to = to; self.arrived = arrived; self.done = done
        started = CACurrentMediaTime(); render(0)
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { render(1); land(); return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let p = min(1, (CACurrentMediaTime()-started)/Self.duration)
        render(p)
        if p == 1 { land() }
    }
    private func render(_ p: Double) {
        let eased = CGFloat(CubicEasing(0.2, 0.8, 0.2, 1)(p))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a+(b-a)*eased }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = NSRect(x: mix(from.minX,to.minX), y: mix(from.minY,to.minY), width: mix(from.width,to.width), height: mix(from.height,to.height))
        panel.frame = bounds; content.frame = bounds
        let radius = mix(FindBar.radius, AnnotationAppearance.badgeRadius)
        panel.layer?.cornerRadius = radius; content.layer?.cornerRadius = radius
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: radius, continuous: true)
        image.frame = NSRect(x: (bounds.width-from.width)/2, y: (bounds.height-from.height)/2, width: from.width, height: from.height)
        // Clear the question/answer in the first 58 ms, before the surface gets small enough
        // to crop readable fragments. The number fades in sharply as the surface shrinks.
        image.alphaValue = max(0, 1-CGFloat(p)/0.32)
        let h = ceil(number.intrinsicContentSize.height)
        number.frame = NSRect(x: 0, y: (bounds.height-h)/2, width: bounds.width, height: h)
        let numberProgress = min(1, max(0, (CGFloat(p)-0.28)/0.42))
        number.alphaValue = numberProgress
        CATransaction.commit()
    }
    /// Keep the landed surface on screen while the renderer prepares the real badge. Merely
    /// submitting JavaScript is not a paint acknowledgement.
    private func land() {
        link?.invalidate(); link = nil
        let arrived = arrived; self.arrived = nil; arrived?()
    }
    func fadeToBadge() {
        guard superview != nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.handoffDuration; context.timingFunction = CAMediaTimingFunction(name: .linear)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.finish() })
    }
    func finish() {
        link?.invalidate(); link = nil
        arrived = nil
        let done = done; self.done = nil
        removeFromSuperview(); done?()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
