import AppKit
import RiseCore

/// ⇧⌘D's copy of the page, shown as a card lifting off it, as a Peek floats over a page, then
/// springing into the right half with its own bar while the page narrows into the left, as a Peek
/// does becoming a split. Until the copy has drawn, the card shows a still of the page.
@MainActor extension BrowserController {
    /// How far the card comes in off the page's edges as it lifts, and how quickly.
    static let duplicateLift: CGFloat = 0.015
    static var duplicateLiftSpring: CASpringAnimation { CASpringAnimation(perceptualDuration: 0.1, bounce: 0) }
    /// The slide into the right half starts this soon after the lift, while it's still rising.
    static let duplicateSlideDelay: TimeInterval = 0.03

    @objc func duplicateIntoSplit() {
        guard let current = selectedTab, let url = current.url, duplicateMotion == nil else { return }
        let previous = splitGroups
        let copy = configure(BrowserTab())
        copy.load(url)
        let join = { [weak self] in
            guard let self else { return }
            self.tabs.insert(copy, at: self.tabs.firstIndex { $0.id == current.id } ?? 0)
            if self.selectedID == current.id { self.showSplit(copy) } else {
                // Something else was chosen meanwhile; the pair still forms, out of sight.
                self.splitGroups.removeAll { $0.contains(current.id) }
                self.splitGroups.append(SplitTabGroup(leftID: current.id, rightID: copy.id)); self.update()
            }
            if let group = self.splitGroups.first(where: { $0.contains(copy.id) }) {
                self.registerSplitUndo(group: group.id, previous: previous, selectedID: current.id, addedTabID: copy.id)
            }
        }
        // From a split, or without motion, the copy takes its half at once.
        guard peekMotionAllowed, activeSplitGroup == nil, current.page.view.superview === pageClip, !pageLayoutHeld,
              peekTab == nil, !pictureInPicture.owns(current) else { join(); return }
        plainBarColors[copy.id] = plainBarColors[current.id]
        var started = false
        let start = { [weak self] (still: NSImage?) in
            guard !started else { return }
            started = true
            guard let self, self.selectedID == current.id, self.activeSplitGroup == nil, self.peekTab == nil else { join(); return }
            self.liftCopy(copy, of: current, still: still, join: join)
        }
        // The press shows at once: a busy page's still mustn't hold it up.
        Task { start(await current.page.snapshot(width: nil)) }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.08) { start(nil) }
    }

    private func liftCopy(_ copy: BrowserTab, of current: BrowserTab, still: NSImage?, join: @escaping () -> Void) {
        let barHeight = PlainNavBar.Metrics.height, body = pageBody
        let whole = pageClip.convert(pageClip.bounds, to: root)
        let frames = splitFrames(in: body, fraction: 0.5)
        let right = pageClip.convert(NSRect(x: frames.right.minX, y: 0, width: frames.right.width, height: pageClip.bounds.height), to: root)
        let lift = Self.duplicateLift
        pageLayoutHeld = true

        // The card: the page's own shape, its bar, the copy's page, and the still over it.
        let card = PageSurface(color: theme.page, radius: PageAppearance.radius)
        card.layer?.masksToBounds = false; card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0
        card.layer?.shadowRadius = 8; card.layer?.shadowOffset = NSSize(width: 0, height: -2)
        let clip = PageSurface(color: theme.page, radius: PageAppearance.radius)
        clip.layer?.masksToBounds = true; clip.clipsToBounds = true; clip.layer?.cornerCurve = .continuous
        card.addSubview(clip); clip.addSubview(copy.page.view)
        let standIn = NSImageView(image: still ?? NSImage())
        standIn.imageScaling = .scaleNone; standIn.imageAlignment = .alignTopLeft; standIn.wantsLayer = true
        standIn.layer?.backgroundColor = theme.page.cgColor
        clip.addSubview(standIn)
        let bar = splitBar
        showPageBar(bar, tab: copy, shown: &splitBarTabID)
        bar.show(url: current.url, title: current.title)
        splitBarButtons[0].isEnabled = false; splitBarButtons[1].isEnabled = false
        (splitBarButtons[2] as? ReloadButton)?.setMode(.reload)
        bar.isHidden = false; clip.addSubview(bar)
        root.addSubview(card, positioned: .below, relativeTo: dismissArea)
        func place(_ frame: NSRect) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            card.frame = frame; clip.frame = card.bounds
            bar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: barHeight)
            let page = NSRect(x: 0, y: barHeight, width: card.bounds.width, height: max(0, card.bounds.height-barHeight))
            copy.page.view.frame = page; standIn.frame = page
            card.refreshOutline(); clip.refreshOutline()
            CATransaction.commit()
        }
        place(whole)

        // One motion: it lifts off the page, its shadow coming up under it, and is already on its
        // way into the right half as it does, the page narrowing into the left; the lift eases away
        // as it settles, into the page's own shadow.
        let liftSpring = Self.duplicateLiftSpring, spring = Self.peekSplitSpring, edges = windowSides
        let pageFrom = current.page.view.frame, delay = Self.duplicateSlideDelay
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0; shadow.toValue = 0.25; shadow.duration = liftSpring.perceptualDuration
        shadow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        card.layer?.shadowOpacity = 0.25; card.layer?.add(shadow, forKey: "duplicate.lift")
        DispatchQueue.main.asyncAfter(deadline: .now()+liftSpring.perceptualDuration) { [weak self, weak card] in
            guard let self, let card, card.superview != nil else { return }
            self.matchPageShadow(card, duration: spring.perceptualDuration)
        }
        let motion = PeekLiveMotion(on: card, spring: spring, step: { _ in }, completion: { [weak self] in
            guard let self else { return }
            self.duplicateMotion = nil; self.pageLayoutHeld = false
            // The copy and its bar stay where they settled, now in the page; the still stays over
            // the copy until it has drawn.
            self.pageClip.addSubview(bar, positioned: .above, relativeTo: self.navBar)
            copy.page.view.removeFromSuperview()
            join()
            card.removeFromSuperview()
            self.fadeDuplicateStandIn(standIn, over: copy)
        })
        motion.alongside = { [weak self] elapsed in
            guard let self else { return }
            let slide = elapsed.isInfinite ? 1 : PeekLiveMotion.settledProgress(at: max(0, elapsed-delay), along: spring)
            let lifting = elapsed.isInfinite ? 0 : min(1, PeekLiveMotion.progress(at: elapsed, along: liftSpring))*(1-min(1, slide))
            let base = whole.interpolated(to: right, by: slide)
            place(base.insetBy(dx: whole.width*lift*lifting, dy: whole.height*lift*lifting).limited(to: whole, edges: edges))
            let page = pageFrom.interpolated(to: frames.left, by: slide)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            current.page.view.frame = page; self.navBar.frame.size.width = page.width
            CATransaction.commit()
            self.shapePage(around: [page])
        }
        duplicateMotion = motion
    }

    /// The still of the page fades to the copy once the copy has loaded, or soon regardless.
    func fadeDuplicateStandIn(_ standIn: NSImageView, over copy: BrowserTab) {
        guard copy.page.view.superview === pageClip else { return }
        standIn.frame = copy.page.view.frame
        pageClip.addSubview(standIn, positioned: .above, relativeTo: copy.page.view)
        let deadline = CACurrentMediaTime()+1.5
        func check() {
            guard standIn.superview != nil else { return }
            let ready = !copy.isLoading && copy.page.url != nil || CACurrentMediaTime() > deadline
            guard ready, copy.page.view.superview === pageClip else {
                if copy.page.view.superview !== pageClip { standIn.removeFromSuperview(); return }
                DispatchQueue.main.asyncAfter(deadline: .now()+0.05) { check() }; return
            }
            standIn.frame = copy.page.view.frame
            fadePeekView(standIn, to: 0, duration: 0.15)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.16) { standIn.removeFromSuperview() }
        }
        check()
    }
}
