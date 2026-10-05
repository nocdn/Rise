import AppKit

/// The same fade/spring glyph replacement for URL-copy and download controls.
@MainActor enum SymbolReplacement {
    static func setImage(_ image: NSImage?, in glyph: NSImageView, animated: Bool = true) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = glyph.layer else { glyph.image = image; return }
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.16
        layer.add(fade, forKey: "replaceFade"); glyph.image = image
        let size = layer.bounds.size, anchor = layer.anchorPoint
        let center = CGPoint(x: (0.5-anchor.x)*size.width, y: (0.5-anchor.y)*size.height)
        let shrunk = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-center.x, -center.y, 0), CATransform3DMakeScale(0.6, 0.6, 1)),
                                         CATransform3DMakeTranslation(center.x, center.y, 0))
        let pop = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.3)
        pop.keyPath = "transform"; pop.fromValue = NSValue(caTransform3D: shrunk); pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = pop.settlingDuration; layer.add(pop, forKey: "replacePop")
    }
}

private final class DownloadSymbolView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DownloadPauseButton: ChromeButton {
    private let glyph = DownloadSymbolView()
    private var showsResume = false
    override var contentTintColor: NSColor? { didSet { glyph.contentTintColor = contentTintColor } }
    init(action: @escaping () -> Void) {
        super.init(symbol: "pause", title: "Pause Download", action: action)
        image = nil; glyph.wantsLayer = true; glyph.imageScaling = .scaleNone
        glyph.image = TablerIcon.image(TablerIcon.pause, size: 19, description: "Pause Download")
        glyph.contentTintColor = contentTintColor; addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); glyph.frame = bounds }
    func update(paused: Bool) {
        let title = paused ? "Resume Download" : "Pause Download"
        toolTip = title; setAccessibilityLabel(title)
        guard paused != showsResume else { return }
        showsResume = paused
        SymbolReplacement.setImage(TablerIcon.image(paused ? TablerIcon.play : TablerIcon.pause, size: paused ? 17 : 19, description: title), in: glyph)
    }
}
