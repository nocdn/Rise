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
        SymbolReplacement.setImage(image, in: glyph)
    }
    deinit { resetTimer?.invalidate() }
}
