import AppKit

/// How a hover card comes and goes: a scale from or to some point of it, a fade, and for the
/// way in a spring, so it can be tried with different feels. The Calendar, Gmail and pull request
/// cards beside tabs use the one picked with Develop ▸ Card Motion Tester (the first, unless
/// changed there). The tester is kept for tuning other motions the same way.
struct CardMotion: Equatable {
    /// The point the card grows from and shrinks to.
    enum Origin: String { case tab = "the tab", center = "its centre", top = "its top" }
    var name: String
    var origin = Origin.tab
    /// In: the scale it starts from, the spring that brings it to full size, and the fade.
    var scaleIn: CGFloat = 1, response = 0.3, bounce = 0.0, fadeIn = 0.15
    /// Slides in from the sidebar by this much as it scales.
    var slide: CGFloat = 0
    /// Out: the scale it ends at, over `outDuration` with `outCurve`, fading over `fadeOut`.
    var scaleOut: CGFloat = 1, outDuration = 0.12, fadeOut = 0.12
    var outCurve = CAMediaTimingFunctionName.easeIn
    var animatesIn: Bool { scaleIn != 1 || fadeIn > 0 || slide != 0 }
    var animatesOut: Bool { scaleOut != 1 || fadeOut > 0 }

    /// Option 3 of the first round (out of the tab from 80 %, a 0.3 bounce, a quick fade) at six
    /// speeds, its own 0.26 s among them; the fade and the way out keep pace.
    static let presets: [CardMotion] = [0.18, 0.21, 0.24, 0.26, 0.29, 0.33].map { response in
        let pace = response/0.26
        let name = "Spring \(response.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))) s" + (response == 0.26 ? " (option 3)" : "")
        return tab(name, from: 0.8, response: response, bounce: 0.3, fade: 0.1*pace, out: 0.88, outIn: 0.12*pace)
    }
    private static func tab(_ name: String, from scaleIn: CGFloat, response: Double, bounce: Double, fade: Double,
                            out scaleOut: CGFloat, outIn duration: Double) -> CardMotion {
        CardMotion(name: name, origin: .tab, scaleIn: scaleIn, response: response, bounce: bounce, fadeIn: fade,
                   scaleOut: scaleOut, outDuration: duration, fadeOut: duration)
    }
    static let preferenceKey = "CalendarCardMotion", delayKey = "CalendarCardDelay"
    /// How long the pointer rests on a tab with a preview before its card opens, whatever the motion.
    static let delayStep = 0.05, delayRange = 0.0...1.5, defaultDelay = 0.2
    static var hoverDelay: Double {
        get { UserDefaults.standard.object(forKey: delayKey) as? Double ?? defaultDelay }
        set { UserDefaults.standard.set(min(delayRange.upperBound, max(delayRange.lowerBound, (newValue/delayStep).rounded()*delayStep)), forKey: delayKey) }
    }
    static var selected: CardMotion {
        let name = UserDefaults.standard.string(forKey: preferenceKey)
        return presets.first { $0.name == name } ?? presets[0]
    }
    static func select(_ motion: CardMotion) { UserDefaults.standard.set(motion.name, forKey: preferenceKey) }

    /// One line of its numbers, for the panel.
    var summary: String {
        guard animatesIn || animatesOut else { return "Appears and disappears at once." }
        func n(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))) }
        var parts: [String] = []
        if scaleIn != 1 { parts.append("in ×\(n(scaleIn)) from \(origin.rawValue), spring \(n(response)) s, bounce \(n(bounce))") }
        if slide != 0 { parts.append("slides \(n(-slide)) pt") }
        if fadeIn > 0 { parts.append("fade in \(n(fadeIn)) s") }
        parts.append(scaleOut != 1 ? "out ×\(n(scaleOut)) in \(n(outDuration)) s" : "out without scaling")
        if fadeOut > 0 { parts.append("fade out \(n(fadeOut)) s") }
        return parts.joined(separator: " · ")
    }
}

@MainActor enum CardMotionAnimator {
    static let inKeys = ["card.motion.in.transform", "card.motion.in.opacity"]
    static let outKeys = ["card.motion.out.transform", "card.motion.out.opacity"]

    /// A scale about `point` (in the view's own coordinates), then a nudge along x.
    private static func transform(_ scale: CGFloat, about point: CGPoint, in layer: CALayer, slide: CGFloat = 0) -> CATransform3D {
        let size = layer.bounds.size, anchor = layer.anchorPoint
        let pivot = CGPoint(x: point.x-anchor.x*size.width, y: point.y-anchor.y*size.height)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0), CATransform3DMakeScale(scale, scale, 1)),
                                   CATransform3DMakeTranslation(pivot.x+slide, pivot.y, 0))
    }
    private static func point(_ motion: CardMotion, in view: NSView, tab: CGPoint) -> CGPoint {
        switch motion.origin {
        case .tab: return tab
        case .center: return CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        case .top: return CGPoint(x: view.bounds.midX, y: 0)
        }
    }
    /// `tab` is where the card comes out of its tab, in the card's own (flipped) coordinates;
    /// it can lie outside the card.
    static func animateIn(_ view: NSView, _ motion: CardMotion, tab: CGPoint) {
        guard let layer = view.layer else { return }
        (inKeys+outKeys).forEach { layer.removeAnimation(forKey: $0) }
        guard motion.animatesIn, view.window != nil else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if motion.fadeIn > 0 || reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = max(0.12, motion.fadeIn)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: inKeys[1])
        }
        guard !reduced, motion.scaleIn != 1 || motion.slide != 0 else { return }
        let spring = CASpringAnimation(perceptualDuration: motion.response, bounce: motion.bounce)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: transform(motion.scaleIn, about: point(motion, in: view, tab: tab), in: layer, slide: motion.slide))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity); spring.duration = spring.settlingDuration
        // Set rather than left to the commit, so a copy of it (`movePivotIn`) carries on from here.
        spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.add(spring, forKey: inKeys[0])
    }
    /// For a card whose size changed on its way in: the way in carries on from where it had got
    /// to, about `tab` in the card's new coordinates, rather than about the old point.
    static func movePivotIn(_ view: NSView, _ motion: CardMotion, tab: CGPoint) {
        guard let layer = view.layer, let spring = layer.animation(forKey: inKeys[0])?.copy() as? CASpringAnimation else { return }
        spring.fromValue = NSValue(caTransform3D: transform(motion.scaleIn, about: point(motion, in: view, tab: tab), in: layer, slide: motion.slide))
        layer.add(spring, forKey: inKeys[0])
    }
    /// Plays the way out, then calls `done` unless the card came back first.
    static func animateOut(_ view: NSView, _ motion: CardMotion, tab: CGPoint, done: @escaping () -> Void) {
        guard let layer = view.layer, motion.animatesOut, view.window != nil, !view.isHidden else { done(); return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            guard layer.animation(forKey: outKeys[1]) != nil || layer.animation(forKey: outKeys[0]) != nil else { return }
            done(); outKeys.forEach { layer.removeAnimation(forKey: $0) }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1; fade.toValue = 0
        fade.duration = max(0.01, reduced ? 0.12 : motion.fadeOut > 0 ? motion.fadeOut : motion.outDuration)
        // Without a fade the card shrinks, then goes.
        if motion.fadeOut == 0 && !reduced { fade.fromValue = 1; fade.toValue = 1 }
        fade.timingFunction = CAMediaTimingFunction(name: motion.outCurve)
        var animations: [(CABasicAnimation, String)] = [(fade, outKeys[1])]
        if !reduced, motion.scaleOut != 1 {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: transform(motion.scaleOut, about: point(motion, in: view, tab: tab), in: layer, slide: motion.slide/2))
            shrink.duration = motion.outDuration; shrink.timingFunction = CAMediaTimingFunction(name: motion.outCurve)
            animations.append((shrink, outKeys[0]))
        }
        inKeys.forEach { layer.removeAnimation(forKey: $0) }
        for (animation, key) in animations {
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
    /// Stops a way out at once, as the card shows again.
    static func cancelOut(_ view: NSView) { outKeys.forEach { view.layer?.removeAnimation(forKey: $0) } }
}

/// Develop ▸ Card Motion Tester: a label at the bottom of the window names the motion in
/// use, and ← and → flick through them. Each switch replays the open preview card's way in.
/// ↑ and ↓ lengthen and shorten the wait before the card opens, for every motion.
@MainActor final class CardMotionTester {
    static let shared = CardMotionTester()
    private weak var browser: BrowserController?
    private var monitor: Any?
    let label = CardMotionLabel()
    var isOn: Bool { monitor != nil }

    func toggle(in browser: BrowserController) {
        if isOn { stop(); return }
        self.browser = browser
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handles(event) else { return event }
            switch event.keyCode {
            case 123: self.step(-1)
            case 124: self.step(1)
            case 126: self.adjustDelay(1)
            default: self.adjustDelay(-1)
            }
            return nil
        }
        browser.root.addSubview(label, positioned: .below, relativeTo: browser.dismissArea)
        refresh()
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; label.removeFromSuperview()
    }
    /// The arrow keys on their own, in the tester's window, whatever has the keyboard there.
    func handles(_ event: NSEvent) -> Bool {
        guard isOn, (123...126).contains(event.keyCode), event.window === browser?.window else { return false }
        return event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
    func step(_ delta: Int) {
        let presets = CardMotion.presets, index = presets.firstIndex(of: CardMotion.selected) ?? 0
        CardMotion.select(presets[(index+delta+presets.count)%presets.count])
        refresh()
        guard let hover = browser?.tabHoverCards else { return }
        hover.calendarCard.replayMotion(); hover.gmailCard.replayMotion(); hover.chatCard.replayMotion(); hover.pullRequestCard.replayMotion()
    }
    func adjustDelay(_ steps: Int) {
        CardMotion.hoverDelay += Double(steps)*CardMotion.delayStep
        refresh()
    }
    private func refresh() {
        guard let browser else { return }
        let presets = CardMotion.presets, motion = CardMotion.selected
        label.show(position: (presets.firstIndex(of: motion) ?? 0)+1, of: presets.count, motion: motion, delay: CardMotion.hoverDelay, theme: browser.theme)
        let size = label.fittingSize, bounds = browser.root.bounds
        label.frame = NSRect(x: round(bounds.midX-size.width/2), y: bounds.maxY-size.height-16, width: size.width, height: size.height)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }
}

/// "← 3 of 6 · Spring 0.24 s →", with the motion's numbers and the wait before opening under it.
@MainActor final class CardMotionLabel: Surface {
    let title = label("", size: 13, weight: .semibold)
    let detail = label("", size: 11)
    let delay = label("", size: 12, weight: .medium)
    init() {
        super.init(radius: 12)
        layer?.borderWidth = 0.5; layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.15
        layer?.shadowRadius = 10; layer?.shadowOffset = NSSize(width: 0, height: -3)
        clipsToBounds = false
        detail.alignment = .center; title.alignment = .center; delay.alignment = .center
        [title, detail, delay].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var fittingSize: NSSize {
        let width = max(title.intrinsicContentSize.width, detail.intrinsicContentSize.width, delay.intrinsicContentSize.width)+32
        return NSSize(width: ceil(width), height: 72)
    }
    func show(position: Int, of count: Int, motion: CardMotion, delay wait: Double, theme: RiseTheme) {
        show(title: "←  \(position) of \(count) · \(motion.name)  →", detail: motion.summary,
             footer: "↑↓  Opens after \(wait.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))) s", theme: theme)
    }
    /// Three lines, as another tester names what it's showing.
    func show(title text: String, detail summary: String, footer: String, theme: RiseTheme) {
        title.stringValue = text
        detail.stringValue = summary
        delay.stringValue = footer
        fill = theme == .dark ? theme.popup : TabAppearance.selectedFill(theme)
        layer?.borderColor = theme.border.cgColor
        title.textColor = theme.text; detail.textColor = theme.muted; delay.textColor = theme.text
        let size = fittingSize
        title.frame = NSRect(x: 0, y: 9, width: size.width, height: 17)
        detail.frame = NSRect(x: 0, y: 28, width: size.width, height: 15)
        delay.frame = NSRect(x: 0, y: 47, width: size.width, height: 16)
    }
}

@MainActor extension BrowserController {
    @objc func toggleCardMotionTester() { CardMotionTester.shared.toggle(in: self) }
}
