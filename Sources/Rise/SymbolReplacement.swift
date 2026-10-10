import AppKit

/// Fade/spring glyph replacement for URL-copy feedback.
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
