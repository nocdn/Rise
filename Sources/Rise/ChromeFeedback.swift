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
    func setFadeBoundary(_ width: CGFloat, duration: CFTimeInterval = 0) {
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

final class TabLoadingBackground: FlippedView {
    private let fillLayer = CAGradientLayer()
    private(set) var loading = false
    private(set) var fraction: CGFloat = 0
    private var finishWork: DispatchWorkItem?
    init() {
        super.init(frame: .zero); wantsLayer = true
        layer?.cornerRadius = 12; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        fillLayer.anchorPoint = .zero; fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5); fillLayer.opacity = 0
        layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(loading: Bool, progress: Double, theme: RiseTheme) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fillLayer.colors = [0.07, 0.11, 0.16, 0].map { theme.accent.withAlphaComponent($0).cgColor }
        fillLayer.locations = [0, 0.65, 0.9, 1]
        CATransaction.commit()
        if loading {
            if !self.loading {
                finishWork?.cancel(); finishWork = nil
                fillLayer.removeAllAnimations(); fraction = 0
                setWidth(0, animated: false)
                fillLayer.opacity = 1
            }
            self.loading = true
            let next = max(fraction, min(0.97, max(0.07, CGFloat(progress))))
            if next != fraction { fraction = next; setWidth(bounds.width * fraction, animated: true) }
            if fraction >= 0.8, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               fillLayer.animation(forKey: "waiting") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.6; pulse.toValue = 1; pulse.duration = 1.4
                pulse.autoreverses = true; pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fillLayer.add(pulse, forKey: "waiting")
            }
        } else if self.loading {
            self.loading = false; fraction = 1
            fillLayer.removeAnimation(forKey: "waiting")
            setWidth(bounds.width, animated: true)
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.loading else { return }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = self.fillLayer.presentation()?.opacity ?? 1; fade.toValue = 0
                fade.duration = 0.35; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.fillLayer.opacity = 0; self.fillLayer.add(fade, forKey: "finish")
            }
            finishWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }
    override func layout() {
        super.layout()
        setWidth(bounds.width * fraction, animated: false)
    }
    private func setWidth(_ width: CGFloat, animated: Bool) {
        let old = fillLayer.presentation()?.bounds.width ?? fillLayer.bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fillLayer.position = .zero; fillLayer.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let movement = CABasicAnimation(keyPath: "bounds.size.width")
            movement.fromValue = old; movement.toValue = width; movement.duration = 0.4
            movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fillLayer.add(movement, forKey: "progress")
        }
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
        let value = peek ? url.absoluteString : url.absoluteString.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
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
