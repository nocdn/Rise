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

final class LinkStatusPill: Surface {
    let text = ShimmeringTextField(frame: .zero)
    let repositoryGlyph = LinkRepositoryGlyph(frame: .zero)
    private(set) var repositoryState: GitHubLinkStatus.State?
    var showsRepositoryStatus: Bool { repositoryState != nil && !showsPeekHint && url != nil }
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
        addSubview(repositoryGlyph); repositoryGlyph.isHidden = true
        addSubview(peekPrefix); addSubview(text); addSubview(peekSuffix)
        peekPrefix.isHidden = true; peekSuffix.isHidden = true; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ url: URL?, theme: RiseTheme, peek: Bool = false, blocked: Bool = false) {
        if self.url != url { ready = false; text.stopShimmer(); setRepositoryState(nil) }
        let peek = url != nil && peek
        if showsPeekHint != peek { text.stopShimmer() }
        showsPeekHint = peek; peekPrefix.isHidden = !peek; peekSuffix.isHidden = !peek
        peekBlocked = peek && blocked; peekPrefix.stringValue = peekBlocked ? "Cannot open " : "Open "
        self.url = url; isHidden = url == nil
        repositoryGlyph.isHidden = !showsRepositoryStatus
        guard let url else { return }
        let value = peek ? url.absoluteString : AddressDisplay.text(url.absoluteString)
        text.stringValue = value; text.textColor = theme.text.withAlphaComponent(0.8)
        repositoryGlyph.color = theme.text.withAlphaComponent(0.8); repositoryGlyph.appearance = theme.appearance
        peekPrefix.textColor = theme.text.withAlphaComponent(0.6); peekSuffix.textColor = peekPrefix.textColor
        text.shimmerColor = theme.linkShimmer
        fill = theme.status
        layer?.borderWidth = 0.75; layer?.borderColor = theme.text.withAlphaComponent(0.18).cgColor
        setAccessibilityLabel(peek ? "\(peekPrefix.stringValue)\(url.absoluteString) in Peek" : url.absoluteString); toolTip = url.absoluteString
    }
    func setRepositoryState(_ state: GitHubLinkStatus.State?) {
        repositoryState = state
        repositoryGlyph.show(state, animated: window != nil && !showsPeekHint)
        repositoryGlyph.isHidden = !showsRepositoryStatus
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
        let leading: CGFloat = showsRepositoryStatus ? 9 : 12
        let glyphWidth: CGFloat = showsRepositoryStatus ? 17 : 0
        let width = min(max(80, text.attributedStringValue.size().width + prefixWidth + suffixWidth + glyphWidth + leading + 14 - 2*hintInset + (showsPeekHint ? 4 : 0)), max(0, min(650, page.width - 28)))
        restingFrame = NSRect(x: page.minX + 10, y: page.maxY - 36, width: width, height: 26)
        applyPosition()
        peekPrefix.frame = NSRect(x: 12, y: (26-peekPrefix.intrinsicContentSize.height)/2, width: prefixWidth, height: peekPrefix.intrinsicContentSize.height)
        // Overlap only the cells' drawing slack. The literal spaces in the hints
        // provide the glyph spacing, while their full widths prevent clipping.
        repositoryGlyph.frame = NSRect(x: leading, y: 6, width: 14, height: 14)
        text.frame = NSRect(x: leading + prefixWidth - hintInset + glyphWidth, y: (26 - text.intrinsicContentSize.height)/2,
                            width: max(0, width - leading - 12 - prefixWidth - suffixWidth - glyphWidth + 2*hintInset), height: text.intrinsicContentSize.height)
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
