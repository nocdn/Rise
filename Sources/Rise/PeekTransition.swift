import AppKit
import WebKit

/// The link a Peek grew out of: its rect in the source page and a snapshot of it.
struct PeekOrigin {
    weak var webView: WKWebView?
    var rect: NSRect
    var image: NSImage?
    /// A whole page the Peek shrinks back out of, as ⌘Z after expanding does, in root coordinates.
    /// It's only where the Peek opens from; closing still goes back into its link.
    var rootFrame: NSRect? = nil
}

/// Stands in for the Peek card while it travels between the clicked link and its
/// resting frame, so the live WKWebView never resizes mid-animation. Snapshots
/// are fitted to the card's width and pinned to its top edge, like Arc.
final class PeekGhost: Surface {
    enum Phase { case opening, closing }
    /// Closing is terminal: a growing card can reverse, a shrinking one only finishes.
    var phase = Phase.opening
    /// Views that leave together with a shrinking card, such as its backdrop.
    var companions: [NSView] = []
    let clip: Surface
    let page = FlippedView()
    let link = FlippedView()
    /// Height/width of each snapshot, fixed up front so late snapshots never stretch.
    var pageAspect: CGFloat?
    var pageImage: NSImage? { didSet { page.layer?.contents = pageImage } }
    var linkImage: NSImage? { didSet { link.layer?.contents = linkImage } }

    init(color: NSColor) {
        clip = Surface(color: color, radius: 8)
        super.init(color: .clear, radius: 8)
        // AppKit clips layer-backed views by default, which would hide the shadow.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8; layer?.shadowOffset = NSSize(width: 0, height: -2)
        clip.layer?.masksToBounds = true; clip.clipsToBounds = true
        for view in [page, link] { view.wantsLayer = true; view.layer?.contentsGravity = .resize; clip.addSubview(view) }
        addSubview(clip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func dismantle() { companions.forEach { $0.removeFromSuperview() }; companions = []; removeFromSuperview() }
    /// With a spring, every layer follows the same curve, so the parts stay aligned.
    func place(_ frame: NSRect, spring: CASpringAnimation? = nil) {
        let linkAspect = linkImage.map { $0.size.height / max(1, $0.size.width) }
        let size = frame.size
        for (view, target) in [(self, frame), (clip, NSRect(origin: .zero, size: size)),
                               (page, NSRect(x: 0, y: 0, width: size.width, height: size.width*(pageAspect ?? size.height/max(1, size.width)))),
                               (link, NSRect(x: 0, y: 0, width: size.width, height: size.width*(linkAspect ?? size.height/max(1, size.width))))] {
            if let spring { view.spring(to: target, along: spring) } else { view.frame = target }
        }
    }
    func fadeShadow(to opacity: Float, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = layer?.presentation()?.shadowOpacity ?? layer?.shadowOpacity; animation.toValue = opacity; animation.duration = duration
        layer?.shadowOpacity = opacity; layer?.add(animation, forKey: "peekShadow")
    }
}

extension NSView {
    /// Moves a layer-backed view to `frame` along `spring`, from wherever it appears now.
    func spring(to frame: NSRect, along spring: CASpringAnimation) {
        guard let layer else { self.frame = frame; return }
        let shown = layer.presentation() ?? layer
        let position = shown.position, bounds = shown.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true); self.frame = frame; CATransaction.commit()
        for (key, from, to) in [("position", NSValue(point: position), NSValue(point: layer.position)),
                                ("bounds", NSValue(rect: bounds), NSValue(rect: layer.bounds))] {
            let animation = spring.copy() as! CASpringAnimation
            animation.keyPath = key; animation.fromValue = from; animation.toValue = to
            animation.duration = animation.settlingDuration
            layer.add(animation, forKey: "peek.\(key)")
        }
    }
}

@MainActor extension BrowserController {
    // A subtle overshoot on the way out; a little less settling back into the link.
    static var peekOpenSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.3, bounce: 0.12) }
    /// ⌘Z shrinking a page back into its Peek: the opening's timing, with the expand's bounce as it lands.
    static var peekUnexpandSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.3, bounce: 0.25) }
    static var peekCloseSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.22, bounce: 0.11) }
    // The page travels under 2% back to full size, so it needs a bouncier spring for
    // its overshoot to be visible at all: about 1 point past its frame per side.
    static var peekPageReturnSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.28, bounce: 0.38) }
    // Finds the link under the pointer (falling back to the focused link) and
    // remembers it in Rise's isolated world so closing can find it again.
    static let peekLinkScript = """
    const selector = 'a[href], area[href]';
    let link = window.__risePeekLink, index = window.__risePeekIndex ?? 0;
    if (locate) {
      const hit = x >= 0 ? document.elementFromPoint(x, y)?.closest?.(selector) : null;
      link = hit ?? document.activeElement?.closest?.(selector) ?? null;
      const rects = link ? [...link.getClientRects()] : [];
      index = Math.max(0, rects.findIndex(r => x >= r.left && x <= r.right && y >= r.top && y <= r.bottom));
      window.__risePeekLink = link; window.__risePeekIndex = index;
    }
    if (!link?.isConnected) return null;
    const r = [...link.getClientRects()][index] ?? link.getBoundingClientRect();
    return r.width >= 1 && r.height >= 1 ? [r.left, r.top, r.width, r.height] : null;
    """

    /// The controls start sliding out this far into the card's opening spring.
    static let peekControlsLead = 0.7
    static let peekControlStagger = 0.02
    /// Sends the controls back behind the closing card, the bottom one first, then removes them.
    func tuckPeekControls(_ controls: [PeekControl], animated: Bool) {
        guard animated, peekMotionAllowed else { controls.forEach { $0.removeFromSuperview() }; return }
        for (index, control) in controls.reversed().enumerated() { control.slideIn(after: Double(index)*Self.peekControlStagger) }
        let done = Double(controls.count)*Self.peekControlStagger+PeekControl.tuckDuration+0.02
        DispatchQueue.main.asyncAfter(deadline: .now()+done) { controls.forEach { $0.removeFromSuperview() } }
    }
    /// Arc insets the page behind a Peek by about 9 points per side.
    static let peekPageScale: CGFloat = 0.982
    var peekMotionAllowed: Bool { window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Sends the lookup to the page immediately, so it is not queued behind other work.
    func peekLink(in web: WKWebView, locate: Bool, completion: @escaping (PeekOrigin?) -> Void) {
        guard let window = web.window, web.magnification == 1, !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 0 else { completion(nil); return }
        let zoom = max(0.01, web.pageZoom)
        var point = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !web.isFlipped { point.y = web.bounds.height - point.y }
        let inside = point.x >= 0 && point.y >= 0 && point.x <= web.bounds.width && point.y <= web.bounds.height
        let arguments: [String: Any] = ["x": inside ? point.x/zoom : -1, "y": inside ? point.y/zoom : -1, "locate": locate]
        web.callAsyncJavaScript(Self.peekLinkScript, arguments: arguments, in: nil, in: .defaultClient) { [weak web] result in
            guard let web, case .success(let value) = result, let box = value as? [NSNumber], box.count == 4 else { completion(nil); return }
            var rect = NSRect(x: box[0].doubleValue*zoom, y: box[1].doubleValue*zoom, width: box[2].doubleValue*zoom, height: box[3].doubleValue*zoom)
            if !web.isFlipped { rect.origin.y = web.bounds.height - rect.maxY }
            rect = rect.insetBy(dx: -3, dy: -2).intersection(web.bounds)
            guard !rect.isEmpty else { completion(nil); return }
            let configuration = WKSnapshotConfiguration(); configuration.rect = rect; configuration.afterScreenUpdates = false
            web.takeSnapshot(with: configuration) { image, _ in completion(PeekOrigin(webView: web, rect: rect, image: image)) }
        }
    }
    func peekLink(in web: WKWebView, locate: Bool) async -> PeekOrigin? {
        await withCheckedContinuation { continuation in peekLink(in: web, locate: locate) { continuation.resume(returning: $0) } }
    }
    /// The origin's rect in root coordinates, if its page is still on screen.
    func peekFrame(of origin: PeekOrigin?) -> NSRect? {
        if let frame = origin?.rootFrame { return frame }
        guard let origin, let web = origin.webView, web.window === window, !web.isHiddenOrHasHiddenAncestor else { return nil }
        return web.convert(origin.rect, to: root)
    }
    /// Shrinks the page (and the backdrop dimming it) slightly about its center
    /// behind a Peek, or restores it. Without a spring the change is immediate.
    func recedePage(_ receded: Bool, along spring: CASpringAnimation?) {
        let scale = receded ? peekRecededPageScale : 1
        for layer in [pageShadow.layer].compactMap({ $0 }) {
            let size = layer.bounds.size, anchor = layer.anchorPoint
            let target = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                CATransform3DMakeTranslation((0.5-anchor.x)*size.width*(1-scale), (0.5-anchor.y)*size.height*(1-scale), 0))
            let shown = layer.presentation()?.transform ?? layer.transform
            CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
            guard let spring else { layer.removeAnimation(forKey: "peek.recede"); continue }
            let animation = spring.copy() as! CASpringAnimation
            animation.keyPath = "transform"; animation.fromValue = NSValue(caTransform3D: shown)
            animation.toValue = NSValue(caTransform3D: target); animation.duration = animation.settlingDuration
            layer.add(animation, forKey: "peek.recede")
        }
    }
    var peekGhosts: [PeekGhost] { root.subviews.compactMap { $0 as? PeekGhost } }
    /// Stops every Peek animation at once, removing whatever it was moving.
    func finishPeekMotion() {
        peekMotionToken = nil
        peekLeftovers.forEach { $0.removeFromSuperview() }; peekLeftovers = []
        peekGhosts.forEach { $0.dismantle() }
    }
    func fadePeekView(_ view: NSView, to alpha: CGFloat, delay: TimeInterval = 0, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = view.layer?.presentation()?.opacity ?? Float(view.alphaValue); animation.toValue = alpha
        animation.beginTime = CACurrentMediaTime()+delay; animation.duration = duration; animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.alphaValue = alpha; view.layer?.add(animation, forKey: "peekFade")
    }
    /// Keeps the travelling card showing the live Peek page as it loads and paints.
    func streamPeekPage(into ghost: PeekGhost, from web: WKWebView) {
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = false
        web.takeSnapshot(with: configuration) { [weak self, weak ghost, weak web] image, _ in
            guard let self, let ghost, let web, ghost.phase == .opening, ghost.superview != nil else { return }
            if let image {
                if ghost.pageImage == nil { self.fadePeekView(ghost.page, to: 1, duration: 0.08) }
                ghost.pageImage = image
            }
            self.streamPeekPage(into: ghost, from: web)
        }
    }

    /// Starts locating the clicked link before the Peek's own page begins loading;
    /// a new page's startup otherwise delays the lookup by well over 100 ms.
    func beginPeekReveal(from source: WKWebView?, standIn: PeekOrigin? = nil) -> UUID? {
        guard peekMotionAllowed else { return nil }
        let token = UUID(); peekMotionToken = token
        if let standIn { DispatchQueue.main.async { [weak self] in self?.playPeekOpen(standIn, token: token) } }
        else if let source { peekLink(in: source, locate: true) { [weak self] in self?.playPeekOpen($0, token: token) } }
        else { DispatchQueue.main.async { [weak self] in self?.playPeekOpen(nil, token: token) } }
        return token
    }
    /// Hides the new Peek until its link is located, then grows it out of the link.
    func revealPeek(_ token: UUID?) {
        guard let token, token == peekMotionToken, let card = peekCard else { return }
        [peekBackdrop, card].forEach { $0?.alphaValue = 0 }
        // The controls wait behind the card's edge and slide out as it lands.
        peekControls.forEach { $0.tuckBehindCard() }
        // A slow page must not hold the Peek back; open from the center instead.
        DispatchQueue.main.asyncAfter(deadline: .now()+0.15) { [weak self] in self?.playPeekOpen(nil, token: token) }
    }
    func playPeekOpen(_ origin: PeekOrigin?, token: UUID) {
        guard token == peekMotionToken, let card = peekCard, let web = peekTab?.webView else { return }
        peekMotionToken = nil
        // A whole page shrinking back into a Peek isn't where it closes to; its link is, set by ⌘Z.
        if origin?.rootFrame == nil { peekOrigin = origin }
        let target = card.frame, start = peekFrame(of: origin)
        if livePeekResize, let start, origin?.rootFrame != nil { shrinkIntoPeekLive(card: card, web: web, from: start); return }
        let ghost = PeekGhost(color: theme.page); ghost.linkImage = origin?.image
        ghost.pageAspect = target.height/max(1, target.width); ghost.page.alphaValue = 0
        root.addSubview(ghost, positioned: .above, relativeTo: card)
        ghost.place(start ?? target.insetBy(dx: target.width*0.04, dy: target.height*0.04))
        if start == nil { ghost.alphaValue = 0; fadePeekView(ghost, to: 1, duration: 0.15) }
        // The link hands over to the page early, while the card is still growing.
        fadePeekView(ghost.link, to: 0, delay: 0.01, duration: 0.09)
        streamPeekPage(into: ghost, from: web)
        let spring = origin?.rootFrame == nil ? Self.peekOpenSpring : Self.peekUnexpandSpring
        ghost.layer?.shadowOpacity = 0; ghost.fadeShadow(to: 0.25, duration: spring.perceptualDuration*0.6)
        ghost.place(target, spring: spring)
        if peekSwipePull > 0 { applyPeekSwipeTransform() }
        recedePage(true, along: spring)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = spring.perceptualDuration*0.7; peekBackdrop?.animator().alphaValue = 1
        }
        // Once the card has all but landed, each control follows 20 ms after the one above it.
        for (index, control) in peekControls.enumerated() {
            control.slideOut(after: spring.perceptualDuration*Self.peekControlsLead+Double(index)*Self.peekControlStagger)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+spring.settlingDuration) { [weak self, weak ghost] in
            guard let self, let ghost, ghost.phase == .opening, ghost.superview != nil else { return }
            ghost.removeFromSuperview()
            guard card === self.peekCard else { return }
            card.alphaValue = 1
        }
    }

    /// Snapshots the closing Peek, then shrinks it back into the link it came from.
    /// `hold` gives the controls a head start going back in before the card moves away.
    func dismissPeek(card: Surface, backdrop: Surface?, page web: WKWebView, origin: PeekOrigin?, hold: TimeInterval = 0) {
        peekLeftovers = [backdrop, card].compactMap { $0 }
        let token = UUID(); peekMotionToken = token
        let earliest = CACurrentMediaTime()+hold
        // Closing should feel immediate; never wait long for the snapshots.
        DispatchQueue.main.asyncAfter(deadline: .now()+max(0.08, hold)) { [weak self] in
            self?.playPeekClose(card: card, backdrop: backdrop, page: nil, origin: origin, token: token)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = false
            async let page = try? web.takeSnapshot(configuration: configuration)
            // The source may have scrolled since opening; find the link again.
            async let link = origin?.webView.asyncFlatMap { await self.peekLink(in: $0, locate: false) }
            let (image, found) = await (page, link)
            let wait = earliest-CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            self.playPeekClose(card: card, backdrop: backdrop, page: image, origin: found ?? origin, token: token)
        }
    }
    /// How long a closing card waits for its controls to start going back in.
    static let peekCloseHold: TimeInterval = 0.05
    func playPeekClose(card: Surface, backdrop: Surface?, page: NSImage?, origin: PeekOrigin?, token: UUID) {
        guard token == peekMotionToken else { return }
        peekMotionToken = nil; peekLeftovers = []
        let ghost = PeekGhost(color: theme.page); ghost.pageImage = page; ghost.linkImage = origin?.image
        ghost.pageAspect = card.frame.height/max(1, card.frame.width); ghost.link.alphaValue = 0
        let start = visiblePeekFrame(card)
        root.addSubview(ghost, positioned: .above, relativeTo: card); ghost.place(start)
        card.removeFromSuperview()
        shrinkPeek(ghost, into: peekFrame(of: origin), backdrop: backdrop)
    }
    /// Springs a card back into its link from wherever it currently appears, so a
    /// Peek can be dismissed mid-open and simply reverses.
    func shrinkPeek(_ ghost: PeekGhost, into end: NSRect?, backdrop: NSView?) {
        // Flatten a pulled opening ghost into its displayed frame before reversing.
        if let layer = ghost.layer, !CATransform3DIsIdentity(layer.transform) || layer.animation(forKey: "peek.swipeReturn") != nil {
            let start = visiblePeekFrame(ghost)
            for view in [ghost, ghost.clip, ghost.page, ghost.link] {
                view.layer?.removeAnimation(forKey: "peek.position")
                view.layer?.removeAnimation(forKey: "peek.bounds")
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "peek.swipeReturn"); layer.transform = CATransform3DIdentity
            ghost.place(start)
            CATransaction.commit()
        }
        ghost.phase = .closing; ghost.companions = [backdrop].compactMap { $0 }
        let spring = Self.peekCloseSpring, duration = spring.perceptualDuration
        ghost.fadeShadow(to: 0, duration: duration)
        if end != nil {
            fadePeekView(ghost.page, to: 0, delay: duration*0.25, duration: duration*0.4)
            fadePeekView(ghost.link, to: 1, delay: duration*0.2, duration: duration*0.35)
        } else { fadePeekView(ghost, to: 0, duration: duration*0.6) }
        let current = ghost.frame
        ghost.place(end ?? current.insetBy(dx: current.width*0.04, dy: current.height*0.04), spring: spring)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration*0.7; backdrop?.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+spring.settlingDuration) { [weak ghost] in ghost?.dismantle() }
    }
}

extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }; return await transform(self)
    }
}
