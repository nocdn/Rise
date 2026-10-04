import AppKit

private final class CopySymbolView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Animate the glyph independently of the button's hover/visibility opacity.
final class SidebarCopyButton: SidebarHoverButton {
    private let glyph = CopySymbolView()
    private var resetTimer: Timer?
    private(set) var isShowingConfirmation = false

    override var contentTintColor: NSColor? {
        didSet { glyph.contentTintColor = contentTintColor }
    }
    init(action: @escaping () -> Void) {
        super.init(symbol: "link", size: 14, title: "Copy current URL (⌘⇧C)", action: action)
        glyph.image = Self.linkImage; image = nil
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = contentTintColor
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); glyph.frame = bounds
    }
    func showCopied() {
        resetTimer?.invalidate()
        setConfirmation(true)
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetTimer = nil
                self?.setConfirmation(false)
            }
        }
        resetTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    static let linkImage = TablerIcon.image(TablerIcon.link, size: 16, description: "Copy current URL")
    static let copiedImage = TablerIcon.image(TablerIcon.linkCopied, size: 16, description: "Copied")
    /// Like SF Symbols' replace transition: the new glyph fades in while springing up
    /// from a smaller size, about the glyph's center.
    private func setConfirmation(_ copied: Bool) {
        guard isShowingConfirmation != copied else { return }
        isShowingConfirmation = copied
        let image = copied ? Self.copiedImage : Self.linkImage
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = glyph.layer else { glyph.image = image; return }
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.16
        layer.add(fade, forKey: "replaceFade")
        glyph.image = image
        let size = layer.bounds.size, anchor = layer.anchorPoint
        let center = CGPoint(x: (0.5-anchor.x)*size.width, y: (0.5-anchor.y)*size.height)
        let shrunk = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-center.x, -center.y, 0), CATransform3DMakeScale(0.6, 0.6, 1)),
                                         CATransform3DMakeTranslation(center.x, center.y, 0))
        let pop = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.3)
        pop.keyPath = "transform"; pop.fromValue = NSValue(caTransform3D: shrunk); pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "replacePop")
    }
    deinit { resetTimer?.invalidate() }
}
