import AppKit
import QuartzCore

/// Moves something along a spring one display frame at a time, for motion that has to stay
/// live, such as a web page laying itself out again at every size, which a Core Animation copy can't.
@MainActor final class PeekLiveMotion: NSObject {
    private let spring: CASpringAnimation
    private let step: (CGFloat) -> Void
    private let completion: () -> Void
    /// Something else moving with it on a spring of its own, given the time since it began (infinite
    /// once it ends), and what to do once it does.
    var alongside: ((TimeInterval) -> Void)?
    var afterwards: (() -> Void)?
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    init(on view: NSView, spring: CASpringAnimation, step: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.spring = spring; self.step = step; self.completion = completion
        super.init()
        step(0)
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        // The display pauses for a hidden window; the motion still ends, so layout isn't held up.
        DispatchQueue.main.asyncAfter(deadline: .now()+duration+0.25) { [weak self] in self?.finish() }
    }
    /// By then the bounce is under a fifth of a point; the rest would only hold the hand-over up.
    var duration: TimeInterval { spring.perceptualDuration*1.5 }
    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp-start
        if elapsed >= duration { finish() } else { step(Self.progress(at: elapsed, along: spring)); alongside?(elapsed) }
    }
    /// Jumps to the end and hands over.
    func finish() {
        guard link != nil else { return }
        stop(); step(1); alongside?(.infinity); completion(); afterwards?()
    }
    /// `progress(at:along:)`, done once the spring has all but settled.
    nonisolated static func settledProgress(at time: TimeInterval, along spring: CASpringAnimation) -> CGFloat {
        time >= spring.perceptualDuration*1.5 ? 1 : progress(at: time, along: spring)
    }
    /// Leaves things where they are, for whatever interrupted.
    func stop() { link?.invalidate(); link = nil }
    var isRunning: Bool { link != nil }

    /// How far along, from 0 to 1 and past it on the bounce, a spring released from rest is after `time`.
    nonisolated static func progress(at time: TimeInterval, along spring: CASpringAnimation) -> CGFloat {
        let mass = spring.mass, stiffness = spring.stiffness
        let natural = (stiffness/mass).squareRoot(), ratio = spring.damping/(2*(stiffness*mass).squareRoot())
        guard ratio < 1 else { return CGFloat(1-exp(-natural*time)*(1+natural*time)) }
        let decay = ratio*natural, ringing = natural*(1-ratio*ratio).squareRoot()
        return CGFloat(1-exp(-decay*time)*(cos(ringing*time)+decay/ringing*sin(ringing*time)))
    }
}

@MainActor extension BrowserController {
    static let livePeekResizeKey = "Rise.LivePeekResize"
    /// Whether expanding a Peek and ⌘Z resize the live page as they go, instead of moving a still of it.
    var livePeekResize: Bool { preferences.object(forKey: Self.livePeekResizeKey) as? Bool ?? true }
    func setLivePeekResize(_ value: Bool) { preferences.set(value, forKey: Self.livePeekResizeKey) }

    /// Grows the Peek card into the page with its live page inside, laying out at every size,
    /// then hands the page over as the still-based expand does, with nothing left to animate.
    func expandPeekLive(_ tab: BrowserTab, card: Surface, modifiers: NSEvent.ModifierFlags) {
        finishPeekLiveMotion()
        isPromotingPeek = true
        let spring = Self.peekPromoteSpring
        let source = tabs.first { $0.id == peekSourceTabID } ?? selectedTab
        let from = card.frame
        // Where the page settles; view geometry leaves out the page's recede.
        let target = (activeSplitGroup == nil ? source?.page.view : nil).map { $0.convert($0.bounds, to: root) }
            ?? pageClip.convert(pageClip.bounds, to: root)
        (peekBackdrop as? PeekBackdrop)?.dismiss = nil
        if let backdrop = peekBackdrop {
            NSAnimationContext.runAnimationGroup { $0.duration = spring.perceptualDuration*0.7; backdrop.animator().alphaValue = 0 }
        }
        let controls = peekControls; peekControls = []
        tuckPeekControls(controls, animated: true)
        recedePage(false, along: spring)
        fadeLiveCardShadow(card, to: 0, duration: spring.perceptualDuration)
        // It bounces a little past the page on the sidebar's side only, never past the window's edges.
        let edges = windowSides
        peekLiveMotion = PeekLiveMotion(on: card, spring: spring, step: { [weak self, weak card, weak tab] progress in
            guard let self, let card, let tab else { return }
            self.placeLivePeek(card, web: tab.page.view, at: from.interpolated(to: target, by: progress).limited(to: target, edges: edges))
        }, completion: { [weak self, weak tab] in
            guard let self else { return }
            self.peekLiveMotion = nil; self.isPromotingPeek = false
            guard let tab, tab === self.peekTab else { return }
            self.promotePeek(tab, modifiers: modifiers, snapshots: (nil, nil))
        })
    }
    /// ⌘Z: the page shrinks back into the Peek card live, the way it grew.
    func shrinkIntoPeekLive(card: Surface, web: NSView, from start: NSRect) {
        finishPeekLiveMotion()
        let spring = Self.peekUnexpandSpring, target = card.frame
        card.alphaValue = 1
        fadeLiveCardShadow(card, to: 0.25, from: 0, duration: spring.perceptualDuration*0.6)
        recedePage(true, along: spring)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = spring.perceptualDuration*0.7; peekBackdrop?.animator().alphaValue = 1
        }
        for (index, control) in peekControls.enumerated() {
            control.slideOut(after: spring.perceptualDuration*Self.peekControlsLead+Double(index)*Self.peekControlStagger)
        }
        peekLiveMotion = PeekLiveMotion(on: card, spring: spring, step: { [weak self, weak card, weak web] progress in
            guard let self, let card, let web else { return }
            self.placeLivePeek(card, web: web, at: start.interpolated(to: target, by: progress))
        }, completion: { [weak self] in
            self?.peekLiveMotion = nil; self?.layoutPeek()
        })
    }
    /// Ends a live resize still under way, as if it had run its course, before another starts.
    func finishPeekLiveMotion() { if let motion = peekLiveMotion, motion.isRunning { motion.finish() } }
    /// Places the card with its real page filling it, laid out again at every size.
    func placeLivePeek(_ card: Surface, web: NSView, at frame: NSRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        card.frame = frame
        card.subviews.first?.frame = card.bounds
        if web.superview === card.subviews.first { web.frame = card.bounds }
        (card as? PageSurface)?.refreshOutline()
        CATransaction.commit()
    }
    private func fadeLiveCardShadow(_ card: Surface, to opacity: Float, from start: Float? = nil, duration: TimeInterval) {
        guard let layer = card.layer else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = start ?? layer.presentation()?.shadowOpacity ?? layer.shadowOpacity; fade.toValue = opacity
        fade.duration = duration
        layer.shadowOpacity = opacity; layer.add(fade, forKey: "peek.liveShadow")
    }
}

/// The edges of the page area that meet the window's edge rather than the sidebar.
struct PageEdges: OptionSet {
    let rawValue: Int
    static let left = PageEdges(rawValue: 1), right = PageEdges(rawValue: 2), top = PageEdges(rawValue: 4), bottom = PageEdges(rawValue: 8)
    static let windowSides: PageEdges = [.right, .top, .bottom]
}

@MainActor extension BrowserController {
    /// The page area's edges that face the window, where a bounce mustn't carry anything past;
    /// its left too when the sidebar isn't beside it.
    var windowSides: PageEdges { sidebarVisible || sidebarFloat.isVisible ? .windowSides : [.windowSides, .left] }
}

extension NSRect {
    /// Kept within `limit` on those `edges`, so a spring's bounce can't carry it past them.
    func limited(to limit: NSRect, edges: PageEdges) -> NSRect {
        var minX = self.minX, maxX = self.maxX, minY = self.minY, maxY = self.maxY
        if edges.contains(.left) { minX = max(minX, limit.minX) }
        if edges.contains(.right) { maxX = min(maxX, limit.maxX) }
        // Both vertical edges face the window, so which one is up doesn't matter.
        if edges.contains(.top) || edges.contains(.bottom) { minY = max(minY, limit.minY); maxY = min(maxY, limit.maxY) }
        return NSRect(x: minX, y: minY, width: max(0, maxX-minX), height: max(0, maxY-minY))
    }
    /// Part way from this rect to `other`; past 1 carries on beyond it, as a spring's bounce does.
    func interpolated(to other: NSRect, by progress: CGFloat) -> NSRect {
        NSRect(x: minX+(other.minX-minX)*progress, y: minY+(other.minY-minY)*progress,
               width: width+(other.width-width)*progress, height: height+(other.height-height)*progress)
    }
}
