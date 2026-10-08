import AppKit

/// Shows that a tab is playing sound and mutes or unmutes it. Muting draws
/// the slash down across the speaker with a quick spring; unmuting draws it
/// back up. A press shrinks the glyph slightly until release.
@MainActor final class TabAudioButton: GlyphButton {
    private(set) var muted = false
    var color: NSColor = .labelColor { didSet { if color != oldValue { applyColor() } } }
    /// Scaled while pressed, so the whole glyph shrinks about its center.
    private let glyph = CALayer()
    private let speaker = CAShapeLayer()
    /// The speaker with gaps where the slash crosses it.
    private let mutedSpeaker = CAShapeLayer()
    private let slash = CAShapeLayer()
    private var pressed = false
    static let glyphSize: CGFloat = 16
    static let pressedScale: CGFloat = 0.86
    // Tabler's volume and volume-off icons (MIT, Paweł Kuna); the slash is drawn on its own.
    private static let speakerPath = "M15 8a5 5 0 0 1 0 8m2.7-11a9 9 0 0 1 0 14M6 15H4a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1h2l3.5-4.5A.8.8 0 0 1 11 5v14a.8.8 0 0 1-1.5.5z"
    private static let mutedSpeakerPath = "M15 8a5 5 0 0 1 1.912 4.934m-1.377 2.602A5 5 0 0 1 15 16m2.7-11a9 9 0 0 1 2.362 11.086m-1.676 2.299A9 9 0 0 1 17.7 19M9.069 5.054L9.5 4.5A.8.8 0 0 1 11 5v2m0 4v8a.8.8 0 0 1-1.5.5L6 15H4a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1h2l1.294-1.664"
    private static let slashPath = "M3 3l18 18"

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(glyph)
        for shape in [speaker, mutedSpeaker, slash] {
            shape.fillColor = nil; shape.lineWidth = 2*Self.glyphSize/24
            shape.lineCap = .round; shape.lineJoin = .round
            glyph.addSublayer(shape)
        }
        applyColor(); show(animated: false)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Mute tab")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.bounds = bounds; glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // SVG coordinates run downward; this layer's run upward.
        let scale = Self.glyphSize/24
        var transform = CGAffineTransform(translationX: (bounds.width-Self.glyphSize)/2, y: (bounds.height+Self.glyphSize)/2)
            .scaledBy(x: scale, y: -scale)
        for (shape, data) in [(speaker, Self.speakerPath), (mutedSpeaker, Self.mutedSpeakerPath), (slash, Self.slashPath)] {
            shape.frame = bounds
            shape.path = TablerIcon.path(data).copy(using: &transform)
        }
        CATransaction.commit()
    }
    private func applyColor() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        [speaker, mutedSpeaker, slash].forEach { $0.strokeColor = color.cgColor }
        CATransaction.commit()
    }

    func setMuted(_ muted: Bool, animated: Bool) {
        guard muted != self.muted else { return }
        self.muted = muted
        setAccessibilityLabel(muted ? "Unmute tab" : "Mute tab")
        show(animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func show(animated: Bool) {
        let reach = slash.presentation()?.strokeEnd ?? slash.strokeEnd
        let speakerOpacity = speaker.presentation()?.opacity ?? speaker.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        [slash, speaker, mutedSpeaker].forEach { $0.removeAllAnimations() }
        slash.strokeEnd = muted ? 1 : 0
        // A zero-length round-capped line would still leave a dot.
        slash.opacity = muted ? 1 : 0
        speaker.opacity = muted ? 0 : 1; mutedSpeaker.opacity = muted ? 1 : 0
        CATransaction.commit()
        guard animated else { return }
        // From the top left corner down to the bottom right, or back up.
        let draw = CASpringAnimation(keyPath: "strokeEnd")
        draw.mass = 1; draw.stiffness = 520; draw.damping = 2*0.8*sqrt(520)
        draw.fromValue = reach; draw.toValue = muted ? 1 : 0; draw.duration = draw.settlingDuration
        slash.add(draw, forKey: "mute.draw")
        if !muted {
            // Stay visible while the slash retracts.
            let keep = CABasicAnimation(keyPath: "opacity")
            keep.fromValue = 1; keep.toValue = 1; keep.duration = draw.settlingDuration*0.7
            slash.add(keep, forKey: "mute.visible")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = speakerOpacity; fade.toValue = muted ? 0 : 1; fade.duration = 0.12
        speaker.add(fade, forKey: "mute.fade")
        let gapsFade = CABasicAnimation(keyPath: "opacity")
        gapsFade.fromValue = 1-speakerOpacity; gapsFade.toValue = muted ? 1 : 0; gapsFade.duration = 0.12
        mutedSpeaker.add(gapsFade, forKey: "mute.fade")
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != self.pressed else { return }
        self.pressed = pressed
        PressScale.set(glyph, to: pressed ? Self.pressedScale : 1)
    }
    override func mouseDown(with event: NSEvent) { setPressed(true) }
    override func mouseDragged(with event: NSEvent) { setPressed(bounds.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        super.mouseUp(with: event)
    }
}
