import AppKit
import RiseCore

@MainActor extension BrowserController {
    var activeSplitGroup: SplitTabGroup? {
        selectedID.flatMap { id in splitGroups.first { $0.contains(id) } }
    }
    var splitTab: BrowserTab? {
        guard let group = activeSplitGroup else { return nil }
        let other = selectedID == group.leftID ? group.rightID : group.leftID
        return tabs.first { $0.id == other }
    }
    var visibleTabIDs: [UUID] {
        if let group = activeSplitGroup { return [group.leftID, group.rightID] }
        return selectedID.map { [$0] } ?? []
    }
    func attachVisiblePages() {
        let visible = Set(visibleTabIDs)
        pictureInPicture.reconcile(visibleIDs: visible)
        for tab in tabs {
            // WebKit's fullscreen window holds the web view until it hands it back.
            if pictureInPicture.owns(tab) || tab.isInNativeFullscreen { continue }
            if !visible.contains(tab.id) { tab.page.view.removeFromSuperview(); continue }
            if tab.needsBlockingReload, tab.page.url != nil { tab.needsBlockingReload = false; tab.page.reloadIgnoringCache() }
            if tab.page.url == nil, !tab.hasAttemptedNavigation, !tab.page.isLoading, let url = tab.requestedURL { tab.load(url) }
            if tab.page.view.superview !== pageClip { pageClip.addSubview(tab.page.view, positioned: .below, relativeTo: developerBar) }
        }
    }
    @objc func toggleSplit() {
        if let selectedID, activeSplitGroup != nil { separateSplit(containing: selectedID); return }
        guard let current = selectedTab else { return }
        if let other = tabs.first(where: { $0.id != current.id }) { showSplit(other) }
        else if let url = current.url {
            let other = configure(BrowserTab(engine: ChromiumEngine.engineForNewTabs)); tabs.insert(other, at: 0); other.load(url); showSplit(other)
        }
    }
    func showSplit(_ tab: BrowserTab) {
        guard let current = selectedID, tab.id != current, tabs.contains(where: { $0.id == tab.id }) else { return }
        splitGroups.removeAll { $0.contains(current) || $0.contains(tab.id) }
        splitGroups.append(SplitTabGroup(leftID: current, rightID: tab.id))
        select(current)
    }
    func separateSplit(containing id: UUID) {
        splitGroups.removeAll { $0.contains(id) }
        attachVisiblePages(); update()
    }
    func focusSplitPage(at event: NSEvent) {
        guard activeSplitGroup != nil, peekTab == nil, palette.isHidden, !isSwitchingTabs else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        guard let hit = root.hitTest(point) else { return }
        for tab in tabs where visibleTabIDs.contains(tab.id) && tab.id != selectedID {
            if hit === tab.page.view || hit.isDescendant(of: tab.page.view) { select(tab.id); return }
        }
    }
}

@MainActor extension BrowserController {
    /// Between split pages, the same as the window's margin around the page.
    static let splitGap = PageAppearance.inset
    /// The two pages' frames in the page area, the left one taking `fraction` of the room.
    func splitFrames(in body: NSRect, fraction: Double) -> (left: NSRect, right: NSRect) {
        let room = max(0, body.width-Self.splitGap), left = (room*CGFloat(fraction)).rounded()
        return (NSRect(x: body.minX, y: body.minY, width: left, height: body.height),
                NSRect(x: body.minX+left+Self.splitGap, y: body.minY, width: room-left, height: body.height))
    }
    /// The page surfaces' outline: one rounded card per page, each its full height, with the
    /// window's background showing between them. No frames means the usual single page.
    func pageOutline(around frames: [NSRect]) -> CGPath? {
        guard !frames.isEmpty else { return nil }
        let path = CGMutablePath(), height = pageClip.bounds.height
        for frame in frames {
            path.addPath(PageOutline.path(in: NSRect(x: frame.minX, y: 0, width: frame.width, height: height),
                                          radius: PageAppearance.radius, continuous: true))
        }
        return path
    }
    func shapePage(around frames: [NSRect]) {
        let outline = pageOutline(around: frames)
        pageShadow.setRestingOutline(outline); pageClip.setRestingOutline(outline, clipContents: true)
    }

    // MARK: The handle between split pages

    func installSplitHandle() {
        splitHandle.isHidden = true
        pageShadow.addSubview(splitHandle, positioned: .above, relativeTo: pageClip)
        var start: Double?
        splitHandle.onDrag = { [weak self] distance in
            guard let self, let group = self.activeSplitGroup else { return }
            self.splitMotion?.stop(); self.splitMotion = nil
            let from = start ?? group.fraction; start = from
            self.setSplitFraction(from+Double(distance/max(1, self.pageBody.width-Self.splitGap)), of: group.id)
        }
        splitHandle.onDragEnd = { [weak self] in start = nil; self?.scheduleSave() }
        splitHandle.onReset = { [weak self] in self?.centerSplit() }
        splitHandle.canReturnToPeek = { [weak self] in self?.canReturnSplitToPeek == true }
        splitHandle.onReturnToPeek = { [weak self] in self?.returnSplitToPeek() }
    }
    func setSplitFraction(_ fraction: Double, of id: UUID) {
        guard let index = splitGroups.firstIndex(where: { $0.id == id }) else { return }
        let range = SplitTabGroup.fractionRange
        splitGroups[index].fraction = min(max(fraction, range.lowerBound), range.upperBound)
        layoutChrome()
    }
    /// A double click on the handle springs the split back to the middle.
    func centerSplit() {
        guard let group = activeSplitGroup, abs(group.fraction-0.5) > 0.001 else { return }
        splitMotion?.stop()
        let from = group.fraction
        guard peekMotionAllowed else { setSplitFraction(0.5, of: group.id); scheduleSave(); return }
        splitMotion = PeekLiveMotion(on: splitHandle, spring: Self.peekOpenSpring, step: { [weak self] progress in
            self?.setSplitFraction(from+(0.5-from)*Double(progress), of: group.id)
        }, completion: { [weak self] in self?.splitMotion = nil; self?.scheduleSave() })
    }
    func layoutSplitHandle() {
        guard let group = activeSplitGroup, !pageLayoutHeld, peekTab == nil else { splitHandle.isHidden = true; return }
        let frames = splitFrames(in: pageBody, fraction: group.fraction)
        splitHandle.frame = NSRect(x: frames.left.maxX, y: 0, width: Self.splitGap, height: pageClip.bounds.height)
        if splitHandle.isHidden {
            splitHandle.isHidden = false
            if peekMotionAllowed { splitHandle.alphaValue = 0; fadePeekView(splitHandle, to: 1, duration: 0.15) }
            splitHandle.refreshHover()
        }
    }

    // MARK: A Peek becoming the right half

    /// The Peek card springs into the right half while the page behind narrows into the left,
    /// both live, laying out at every size; then the Peek's page joins the tab list as the split.
    func splitPeekLive(_ tab: BrowserTab, card: Surface, finish: @escaping () -> Void) {
        guard let source = tabs.first(where: { $0.id == (peekSourceTabID ?? selectedID) }), source.id == selectedID,
              source.page.view.superview === pageClip, activeSplitGroup == nil else { finish(); return }
        finishPeekLiveMotion()
        isPromotingPeek = true; pageLayoutHeld = true
        let spring = Self.peekSplitSpring
        let frames = splitFrames(in: pageBody, fraction: 0.5)
        let pageFrom = source.page.view.frame, cardFrom = card.frame
        // View geometry leaves out the page's recede, so this is where the right half settles.
        let cardTo = pageClip.convert(frames.right, to: root)
        (peekBackdrop as? PeekBackdrop)?.dismiss = nil
        if let backdrop = peekBackdrop {
            NSAnimationContext.runAnimationGroup { $0.duration = spring.perceptualDuration*0.7; backdrop.animator().alphaValue = 0 }
        }
        let controls = peekControls; peekControls = []
        tuckPeekControls(controls, animated: true)
        recedePage(false, along: spring)
        // The card takes on the page's corners and tight shadow as it becomes one.
        let radiusFrom = card.layer?.cornerRadius ?? 8, clip = card.subviews.first
        card.layer?.cornerCurve = .continuous; clip?.layer?.cornerCurve = .continuous
        matchPageShadow(card, duration: spring.perceptualDuration)
        // Its bounce never carries it past the window's edges, only back into its own half.
        let edges = windowSides, page = pageClip.convert(pageClip.bounds, to: root)
        peekLiveMotion = PeekLiveMotion(on: card, spring: spring, step: { [weak self, weak card, weak tab, weak source] progress in
            guard let self, let card, let tab, let source else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let radius = radiusFrom+(PageAppearance.radius-radiusFrom)*min(1, progress)
            card.layer?.cornerRadius = radius; clip?.layer?.cornerRadius = radius
            CATransaction.commit()
            self.placeLivePeek(card, web: tab.page.view, at: cardFrom.interpolated(to: cardTo, by: progress).limited(to: page, edges: edges))
            let page = pageFrom.interpolated(to: frames.left, by: progress)
            source.page.view.frame = page; self.shapePage(around: [page])
        }, completion: { [weak self, weak tab] in
            guard let self else { return }
            self.peekLiveMotion = nil; self.isPromotingPeek = false; self.pageLayoutHeld = false
            guard let tab, tab === self.peekTab else { self.layoutChrome(); return }
            finish()
        })
    }
    /// Fades a card's shadow to the page's own, so nothing changes as it hands over.
    private func matchPageShadow(_ card: Surface, duration: TimeInterval) {
        guard let layer = card.layer, let page = pageShadow.layer else { return }
        let alpha = page.shadowColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 1
        let targets: [(String, Any)] = [("shadowOpacity", page.shadowOpacity*Float(alpha)), ("shadowRadius", page.shadowRadius),
                                        ("shadowOffset", NSValue(size: page.shadowOffset))]
        for (key, value) in targets {
            let fade = CABasicAnimation(keyPath: key)
            fade.fromValue = (layer.presentation() ?? layer).value(forKey: key); fade.toValue = value; fade.duration = duration
            layer.setValue(value, forKey: key); layer.add(fade, forKey: "peek.split.\(key)")
        }
    }
}
