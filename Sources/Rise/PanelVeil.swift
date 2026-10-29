import AppKit

/// One window-wide dim for the address palette and tab switcher. It stops taking
/// clicks as soon as dismissal begins, while the same short fade finishes visually.
final class PanelVeil: FlippedView {
    static let fadeInDuration: CFTimeInterval = 0.15
    static let fadeOutDuration: CFTimeInterval = 0.06
    static let animationKey = "veil.fade"
    var dismiss: (() -> Void)?
    private var isShowing = false
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ theme: RiseTheme) {
        let color = (theme == .dark ? NSColor.black.withAlphaComponent(0.35)
            : NSColor(srgbRed: 10/255, green: 10/255, blue: 30/255, alpha: 0.12)).cgColor
        if layer?.backgroundColor != color { layer?.backgroundColor = color }
    }

    /// Resume from the visible opacity when a panel reopens during the exit fade.
    func show(theme: RiseTheme) {
        applyTheme(theme)
        guard !isShowing else { return }
        isShowing = true; generation += 1
        let reached = isHidden ? 0 : layer?.presentation()?.opacity ?? 1
        isHidden = false
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, reached < 1 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = reached; fade.toValue = 1; fade.duration = Self.fadeInDuration*Double(1-reached)
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.31, 0.94, 0.34, 1)
        layer.add(fade, forKey: Self.animationKey)
    }

    func hide(animated: Bool = true) {
        guard isShowing || (!animated && !isHidden) else { return }
        isShowing = false; generation += 1
        guard animated, !isHidden, let layer, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isHidden = true; layer?.removeAnimation(forKey: Self.animationKey); return
        }
        let exit = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == exit else { return }
            self.isHidden = true; layer.removeAnimation(forKey: Self.animationKey)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1; fade.toValue = 0; fade.duration = Self.fadeOutDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: Self.animationKey)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing, dismiss != nil else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { if isShowing { dismiss?() } }
}
