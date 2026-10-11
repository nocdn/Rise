import AppKit
import WebKit
import RiseCore

/// A Peek growing into the page: a still of it springs from the card to the page's frame while
/// the page behind returns to full size, then fades to show the live page, which has moved in.
@MainActor final class PeekPromotion {
    let ghost: PeekGhost
    /// A still of the page that was there, so the new one never shows around the growing card.
    var cover: NSView?
    init(ghost: PeekGhost) { self.ghost = ghost }
}

/// What ⌘Z puts back after a Peek became a tab or a split.
struct PeekUndo {
    enum Kind {
        /// The Peek's page moved into the tab underneath; `tab` holds that tab's page from before.
        case sameTab
        case newTab
        case split(previous: [SplitTabGroup])
    }
    let kind: Kind
    /// The Peek's own page, live and unchanged, or for `sameTab` the page it swapped with.
    let tab: BrowserTab
    let sourceID: UUID?
    let opensNewTab: Bool
    /// The link the Peek grew out of, which it closes back into once it's put back.
    let origin: PeekOrigin?
    let expiry: DispatchWorkItem
}

@MainActor extension BrowserController {
    /// How long ⌘Z can still put the Peek back. Tests shorten it.
    static var peekUndoDuration: TimeInterval = 30
    /// Quicker than the Peek's opening, with a little more bounce as it lands.
    static var peekPromoteSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.24, bounce: 0.25) }
    /// Splitting: the expand's timing without its bounce, so both pages settle straight into their halves.
    static var peekSplitSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.24, bounce: 0) }
    /// The page behind widening back on ⌘Z after a split. Quick, so its right edge catches up with
    /// the card's retreating one early, and without an overshoot, so it eases into the window's edge.
    static var peekWidenSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.14, bounce: 0) }

    /// Grows the Peek into the page, its live page moving in without loading again. In the same
    /// tab, the tab's page from before is held for Back; ⌘ or a link that opens a new tab makes
    /// the Peek's page a tab of its own instead.
    func expandPeek(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let tab = peekTab, !isPromotingPeek else { return }
        guard peekMotionAllowed, let card = peekCard else { promotePeek(tab, modifiers: modifiers, snapshots: (nil, nil)); return }
        if livePeekResize { expandPeekLive(tab, card: card, modifiers: modifiers); return }
        isPromotingPeek = true
        // The Peek, and the page under it, which may start changing straight away.
        let under = (tabs.first { $0.id == peekSourceTabID } ?? selectedTab)?.webView
        var peekImage: NSImage?, underImage: NSImage?, waiting = under == nil ? 1 : 2, finished = false
        let finish = { [weak self, weak tab] in
            guard !finished else { return }
            finished = true
            guard let self else { return }
            self.isPromotingPeek = false
            guard let tab, tab === self.peekTab else { return }
            self.promotePeek(tab, modifiers: modifiers, snapshots: (peekImage, underImage))
        }
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = false
        tab.webView.takeSnapshot(with: configuration) { image, _ in peekImage = image; waiting -= 1; if waiting == 0 { finish() } }
        under?.takeSnapshot(with: configuration) { image, _ in underImage = image; waiting -= 1; if waiting == 0 { finish() } }
        // A busy page mustn't hold the press up.
        DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { finish() }
    }

    func splitPeek() {
        guard let tab = peekTab, !isPromotingPeek else { return }
        let previous = splitGroups, sourceID = peekSourceTabID ?? selectedID, opensNewTab = peekOpensNewTab, origin = peekOrigin
        let finish = { [weak self] in
            guard let self, tab === self.peekTab else { return }
            tab.webView.removeFromSuperview()
            self.peekTab = nil; self.closePeek(); self.tabs.insert(tab, at: 0); self.showSplit(tab)
            self.registerPeekUndo(.split(previous: previous), tab: tab, sourceID: sourceID, opensNewTab: opensNewTab, origin: origin)
        }
        if livePeekResize, peekMotionAllowed, let card = peekCard { splitPeekLive(tab, card: card, finish: finish) } else { finish() }
    }

    func promotePeek(_ tab: BrowserTab, modifiers: NSEvent.ModifierFlags, snapshots: (peek: NSImage?, under: NSImage?)) {
        let source = tabs.first { $0.id == peekSourceTabID } ?? selectedTab
        let opensNewTab = peekOpensNewTab, origin = peekOrigin
        let views = takePeekViews()
        let ghost = snapshots.peek.flatMap { image in views.card.map { coverPeek($0, with: image) } }
        if !modifiers.contains(.command), !opensNewTab, let source {
            // The tab keeps its place and history, as a normal link click would, and takes the
            // Peek's live page; `tab` now holds the tab's page from before, for Back and ⌘Z.
            if selectedID != source.id { select(source.id) }
            handOff(tab, into: source)
            // The page from before stays drawn around the growing card until it covers it all.
            let cover = ghost == nil ? nil : snapshots.under.map { freeze(source.webView, as: $0) }
            registerPeekUndo(.sameTab, tab: tab, sourceID: source.id, opensNewTab: false, origin: origin)
            growPeek(views, ghost: ghost, into: source.webView, cover: cover)
        } else {
            let index = source.flatMap { source in tabs.firstIndex { $0.id == source.id } } ?? 0
            tab.webView.removeFromSuperview()
            tabs.insert(tab, at: index); select(tab.id)
            registerPeekUndo(.newTab, tab: tab, sourceID: source?.id, opensNewTab: opensNewTab, origin: origin)
            growPeek(views, ghost: ghost, into: tab.webView, cover: nil)
        }
        window?.makeFirstResponder(selectedTab?.webView)
        update()
    }

    /// Ends the Peek but leaves its views on screen, for the caller to animate away.
    private func takePeekViews() -> (card: Surface?, backdrop: Surface?, controls: [PeekControl]) {
        if let web = peekTab?.webView {
            historySwipe.cancel(for: web); permissionCoordinator.cancel(for: web)
            if hoveredWebView === web { hideLinkStatus() }
        }
        let views = (card: peekCard, backdrop: peekBackdrop, controls: peekControls)
        finishPeekMotion(); finishPeekPromotion()
        peekSourceTabID = nil; peekOpensNewTab = false; peekSwipePull = 0; peekOrigin = nil
        peekTab = nil; peekCard = nil; peekBackdrop = nil; peekControls = []
        updatePeekCovers()
        return views
    }

    /// Lays a still of the page from before over the page, under the Peek's dimming.
    private func freeze(_ web: WKWebView, as image: NSImage) -> NSView {
        let cover = PeekStandbyView(frame: web.frame)
        cover.wantsLayer = true; cover.layer?.contents = image; cover.layer?.contentsGravity = .resize
        web.superview?.addSubview(cover, positioned: .above, relativeTo: web)
        return cover
    }
    /// A still of the card, standing in for it while it grows.
    private func coverPeek(_ card: Surface, with image: NSImage) -> PeekGhost {
        let ghost = PeekGhost(color: theme.page)
        ghost.pageImage = image; ghost.link.alphaValue = 0
        ghost.pageAspect = card.frame.height/max(1, card.frame.width)
        // Terminal, so a Peek closing meanwhile leaves the page's return to this card.
        ghost.phase = .closing
        root.addSubview(ghost, positioned: .above, relativeTo: card)
        ghost.place(visiblePeekFrame(card))
        return ghost
    }

    private func growPeek(_ views: (card: Surface?, backdrop: Surface?, controls: [PeekControl]), ghost: PeekGhost?,
                          into page: WKWebView, cover: NSView?) {
        let motion = peekMotionAllowed && ghost != nil
        let spring = Self.peekPromoteSpring
        views.card?.removeFromSuperview()
        tuckPeekControls(views.controls, animated: motion)
        recedePage(false, along: motion ? spring : nil)
        if let backdrop = views.backdrop {
            if motion {
                NSAnimationContext.runAnimationGroup({ $0.duration = spring.perceptualDuration*0.7; backdrop.animator().alphaValue = 0 },
                                                     completionHandler: { backdrop.removeFromSuperview() })
            } else { backdrop.removeFromSuperview() }
        }
        guard motion, let ghost else { ghost?.dismantle(); cover?.removeFromSuperview(); return }
        layoutChrome()
        // View geometry leaves out the page's recede, so this is where it settles.
        let target = page.convert(page.bounds, to: root)
        ghost.fadeShadow(to: 0, duration: spring.perceptualDuration)
        ghost.place(target, spring: spring)
        let promotion = PeekPromotion(ghost: ghost); promotion.cover = cover
        peekPromotion = promotion
        // Once it has all but settled, the still fades to the live page, laid out at its new width by then.
        DispatchQueue.main.asyncAfter(deadline: .now()+spring.perceptualDuration*1.5) { [weak self, weak promotion] in
            guard let self, let promotion, promotion === self.peekPromotion else { return }
            self.peekPromotion = nil
            // The card covers the whole page by now, so the page from before can go at once.
            promotion.cover?.removeFromSuperview()
            self.fadePeekView(ghost, to: 0, duration: 0.15)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.16) { ghost.dismantle() }
        }
    }
    func finishPeekPromotion() {
        peekPromotion?.cover?.removeFromSuperview()
        peekPromotion?.ghost.dismantle(); peekPromotion = nil
    }

    // MARK: Undo

    private func registerPeekUndo(_ kind: PeekUndo.Kind, tab: BrowserTab, sourceID: UUID?, opensNewTab: Bool, origin: PeekOrigin?) {
        discardPeekUndo()
        let expiry = DispatchWorkItem { [weak self] in self?.discardPeekUndo() }
        peekUndo = PeekUndo(kind: kind, tab: tab, sourceID: sourceID, opensNewTab: opensNewTab, origin: origin, expiry: expiry)
        if case .split = kind, let group = activeSplitGroup, group.contains(tab.id) {
            splitPeekReturns[group.id] = peekUndo
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.peekUndoDuration, execute: expiry)
    }
    func discardPeekUndo() {
        guard let undo = peekUndo else { return }
        // A page held for Back stays held; only the chance to undo goes.
        peekUndo = nil; undo.expiry.cancel()
    }
    /// ⌘Z shortly after a Peek became a tab or a split, unless an address or search is being typed.
    func handlePeekUndoKey(_ event: NSEvent) -> Bool {
        guard peekUndo != nil, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "z", palette.isHidden,
              !(window?.firstResponder is NSText) else { return false }
        return undoPeekPromotion()
    }
    /// Puts the same live page back in a Peek over the tab it came from, shrinking it back out
    /// of the page it had become, the way it grew.
    @discardableResult func undoPeekPromotion() -> Bool {
        guard let undo = peekUndo else { return false }
        return undoPeekPromotion(undo)
    }
    var canReturnSplitToPeek: Bool {
        guard let group = activeSplitGroup else { return false }
        return tabs.contains { $0.id == group.leftID } && tabs.contains { $0.id == group.rightID }
    }
    @discardableResult func returnSplitToPeek() -> Bool {
        guard canReturnSplitToPeek, let group = activeSplitGroup,
              let right = tabs.first(where: { $0.id == group.rightID }) else { return false }
        // Restored sessions and ordinary splits have no short-lived promotion record.
        // Their right page can still return live to a Peek over the left page.
        let undo = splitPeekReturns[group.id] ?? PeekUndo(kind: .split(previous: splitGroups.filter { $0.id != group.id }),
            tab: right, sourceID: group.leftID, opensNewTab: false, origin: nil, expiry: DispatchWorkItem {})
        return undoPeekPromotion(undo)
    }
    private func undoPeekPromotion(_ undo: PeekUndo) -> Bool {
        let source = undo.sourceID.flatMap { id in tabs.first { $0.id == id } }
        let shown: WKWebView?
        switch undo.kind {
        case .sameTab:
            guard let source, source.backPages.contains(where: { $0 === undo.tab }) else { discardPeekUndo(); return false }
            shown = source.webView
        case .newTab, .split:
            guard tabs.contains(where: { $0 === undo.tab }), tabs.count > 1 else { discardPeekUndo(); return false }
            shown = undo.tab.webView
        }
        if peekUndo?.tab === undo.tab { peekUndo = nil }
        undo.expiry.cancel()
        splitPeekReturns = splitPeekReturns.filter { $0.value.tab !== undo.tab }
        finishPeekPromotion()
        guard peekMotionAllowed, let shown, shown.window === window, !shown.isHiddenOrHasHiddenAncestor else {
            restorePeek(undo, source: source, from: nil); return true
        }
        // Where the page is on screen, and what it shows, for the Peek to shrink back out of.
        let frame = shown.convert(shown.bounds, to: root)
        // Live, the page itself shrinks, so there's no still to wait for.
        if livePeekResize {
            restorePeek(undo, source: source, from: PeekOrigin(webView: nil, rect: .zero, image: nil, rootFrame: frame)); return true
        }
        var finished = false
        let finish = { [weak self] (image: NSImage?) in
            guard !finished else { return }
            finished = true
            self?.restorePeek(undo, source: source, from: PeekOrigin(webView: nil, rect: .zero, image: image, rootFrame: frame))
        }
        let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = false
        shown.takeSnapshot(with: configuration) { image, _ in finish(image) }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { finish(nil) }
        return true
    }
    private func restorePeek(_ undo: PeekUndo, source: BrowserTab?, from standIn: PeekOrigin?) {
        var widening: NSRect?
        switch undo.kind {
        case .sameTab:
            guard let source, let index = source.backPages.lastIndex(where: { $0 === undo.tab }) else { return }
            if selectedID != source.id { select(source.id) }
            // Trade the pages back: the tab's page from before is on show again at once, and the
            // holder has the Peek's live page to put back in the Peek.
            source.backPages.remove(at: index)
            trade(source, with: undo.tab)
            dropForwardPages(of: source)
            // The Peek's page goes straight from the page into the card, never leaving the window.
            undo.tab.webView.setAllMediaPlaybackSuspended(false)
            settle(source, recordsVisit: false)
        case .newTab, .split:
            if case .split = undo.kind, let source, source.webView.superview === pageClip { widening = source.webView.frame }
            detachTab(undo.tab)
            if case .split(let previous) = undo.kind {
                splitGroups = previous.filter { group in
                    tabs.contains { $0.id == group.leftID } && tabs.contains { $0.id == group.rightID }
                }
            }
            if let source { select(source.id) } else if let first = tabs.first { select(first.id) }
        }
        let live = livePeekResize && standIn?.rootFrame != nil
        showPeek(url: undo.tab.url ?? URL(string: "about:blank")!, opensNewTab: undo.opensNewTab, existing: undo.tab,
                 standIn: standIn?.image == nil && !live ? nil : standIn)
        // Start at once, so the page never shows without its card for a frame.
        if live, let standIn, let token = peekMotionToken { playPeekOpen(standIn, token: token) }
        if live, let from = widening, let source, activeSplitGroup == nil, let motion = peekLiveMotion {
            // The real page beside the split widens back on a spring of its own, every frame, ahead
            // of the card shrinking off it; it eases into the window's edge rather than past it.
            let to = pageBody, spring = Self.peekWidenSpring
            pageLayoutHeld = true
            source.webView.frame = from; shapePage(around: [from])
            motion.alongside = { [weak self, weak source] elapsed in
                guard let self, let source else { return }
                let page = from.interpolated(to: to, by: PeekLiveMotion.settledProgress(at: elapsed, along: spring)).limited(to: to, edges: .windowSides)
                source.webView.frame = page; self.shapePage(around: [page])
            }
            motion.afterwards = { [weak self] in self?.pageLayoutHeld = false; self?.layoutChrome() }
        }
        // It closes back into the link it first grew out of, which is on the page again.
        peekOrigin = undo.origin
    }
    /// Takes a tab out of the list without closing its page.
    private func detachTab(_ tab: BrowserTab) {
        splitGroups.removeAll { $0.contains(tab.id) }
        tabs.removeAll { $0 === tab }; recentTabIDs.removeAll { $0 == tab.id }
        findBars.removeValue(forKey: tab.id)?.discard()
        if selectedID == tab.id { selectedID = nil }
        tab.webView.removeFromSuperview()
    }
}
