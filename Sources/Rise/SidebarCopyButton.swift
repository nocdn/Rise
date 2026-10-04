import AppKit
import Symbols

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
        glyph.image = image; image = nil
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
    private func setConfirmation(_ copied: Bool) {
        guard isShowingConfirmation != copied,
              let symbol = NSImage(systemSymbolName: copied ? "checkmark" : "link", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return }
        isShowingConfirmation = copied
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            glyph.removeAllSymbolEffects(); glyph.image = symbol
        } else {
            glyph.setSymbolImage(symbol, contentTransition: .replace.wholeSymbol, options: .speed(1.5))
        }
    }
    deinit { resetTimer?.invalidate() }
}
