import AppKit

/// A Peek waiting underneath a second one opened from a link inside it.
struct ParkedPeek {
    let tab: BrowserTab, card: Surface, backdrop: Surface?, controls: [ChromeButton]
    let origin: PeekOrigin?, sourceTabID: UUID?, opensNewTab: Bool
}

/// Two levels of Peek. Behind a second Peek, the first recedes and dims as the page does
/// behind one, and the page recedes and dims a little further. Closing takes off only the
/// top Peek; the one underneath comes back to the front.
@MainActor extension BrowserController {
    static let deepPageScale: CGFloat = 0.97
    static let parkedPeekScale: CGFloat = peekPageScale
    /// Extra dimming over the page, and the first Peek's dimming, behind a second Peek.
    static let deepPageDim: CGFloat = 0.35, parkedPeekDim: CGFloat = 0.5
    /// A second Peek is this much narrower per side than the first.
    static let nestedPeekSideInset: CGFloat = 56

    /// A Peek opened from a link inside the only open Peek stacks on top of it.
    func opensNestedPeek(from source: NSView?) -> Bool {
        source != nil && source === peekTab?.webView && parkedPeek == nil
    }
    /// Moves the open Peek underneath, so a second can open over it.
    func parkPeek() {
        guard let tab = peekTab, let card = peekCard else { return }
        // A first Peek still growing jumps to rest before it recedes.
        finishPeekMotion(); card.alphaValue = 1
        if peekSwipePull != 0 { returnPeekFromSwipe() }
        parkedPeek = ParkedPeek(tab: tab, card: card, backdrop: peekBackdrop, controls: peekControls,
                                origin: peekOrigin, sourceTabID: peekSourceTabID, opensNewTab: peekOpensNewTab)
        peekTab = nil; peekCard = nil; peekBackdrop = nil; peekControls = []; peekOrigin = nil
        if let web = hoveredWebView, web === tab.webView { hideLinkStatus() }
        let dim = PeekBackdrop(color: theme.background.withAlphaComponent(Self.deepPageDim))
        dim.dismiss = { [weak self] in self?.closePeek(animated: true) }
        dim.frame = pageClip.bounds
        pageClip.addSubview(dim, positioned: .above, relativeTo: parkedPeek?.backdrop); peekPageDim = dim
        if peekMotionAllowed {
            // The first Peek recedes and the page dims further as the new Peek grows, all on
            // its open spring (see `playPeekOpen`); its controls step aside right away.
            dim.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                parkedPeek?.controls.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: { [weak self] in self?.hideParkedControls() }
        } else {
            // Without motion nothing recedes, as with a single Peek; only the dimming changes.
            parkedPeek?.controls.forEach { $0.alphaValue = 0 }; hideParkedControls()
        }
    }
    /// The Peek underneath becomes the open one again.
    func unparkPeek(animated: Bool) {
        guard let parked = parkedPeek else { return }
        parkedPeek = nil
        peekTab = parked.tab; peekCard = parked.card; peekBackdrop = parked.backdrop; peekControls = parked.controls
        peekOrigin = parked.origin; peekSourceTabID = parked.sourceTabID; peekOpensNewTab = parked.opensNewTab
        // Both travel under 2% back, so they take the page's bouncier return spring, as
        // the page does when a single Peek closes.
        let spring = animated ? Self.peekPageReturnSpring : nil
        scale(parked.card, to: 1, along: spring)
        let dim = peekPageDim; peekPageDim = nil
        parked.controls.forEach { $0.isHidden = false }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.peekCloseSpring.perceptualDuration*0.7
                dim?.animator().alphaValue = 0
                parked.controls.forEach { $0.animator().alphaValue = 1 }
            } completionHandler: { dim?.removeFromSuperview() }
        } else {
            dim?.removeFromSuperview(); parked.controls.forEach { $0.alphaValue = 1 }
        }
        if animated { recedePage(true, along: spring) }
        window?.makeFirstResponder(parked.tab.webView)
    }
    /// Where a second Peek rests: narrower than the first, and as much taller than the
    /// receded first Peek as a first Peek is than the receded page behind it.
    var nestedPeekFrame: NSRect {
        let first = firstPeekFrame
        let taller = first.height-pageShadow.frame.height*Self.peekPageScale
        let dy = max(2, (first.height*(1-Self.parkedPeekScale)-taller)/2)
        return first.insetBy(dx: Self.nestedPeekSideInset, dy: dy)
    }
    /// Only the top Peek's page takes hover and sets the cursor; everything under it is covered.
    func updatePeekCovers() {
        let top = peekTab?.webView
        for tab in tabs { (tab.webView as? LinkCursorWebView)?.isCovered = top != nil }
        (parkedPeek?.tab.webView as? LinkCursorWebView)?.isCovered = true
        (top as? LinkCursorWebView)?.isCovered = false
    }
    /// Leaves Peek entirely, both levels at once.
    func closeAllPeeks() {
        closePeek()
        if peekTab != nil { closePeek() }
    }
    func layoutParkedPeek() {
        peekPageDim?.frame = pageClip.bounds
        guard let parked = parkedPeek else { return }
        parked.backdrop?.frame = pageClip.bounds
        let card = parked.card
        // The frame ignores the receding transform; a spring in flight keeps running.
        CATransaction.begin(); CATransaction.setDisableActions(true); card.frame = firstPeekFrame; CATransaction.commit()
        (card as? PageSurface)?.refreshOutline()
        card.subviews.first?.frame = card.bounds; parked.tab.webView.frame = card.bounds
        if card.layer?.animation(forKey: "peek.recede") == nil { scale(card, to: Self.parkedPeekScale, along: nil) }
    }
    private func hideParkedControls() {
        parkedPeek?.controls.forEach { $0.isHidden = true }
    }
    /// Scales a view about its center, springing from wherever it appears now.
    func scale(_ view: NSView, to scale: CGFloat, along spring: CASpringAnimation?) {
        guard let layer = view.layer else { return }
        let size = layer.bounds.size, anchor = layer.anchorPoint
        let target = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation((0.5-anchor.x)*size.width*(1-scale), (0.5-anchor.y)*size.height*(1-scale), 0))
        let shown = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
        guard let spring else { layer.removeAnimation(forKey: "peek.recede"); return }
        let animation = spring.copy() as! CASpringAnimation
        animation.keyPath = "transform"; animation.fromValue = NSValue(caTransform3D: shown)
        animation.toValue = NSValue(caTransform3D: target); animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "peek.recede")
    }
}
