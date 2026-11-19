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
            // The engine's full-screen window holds the page until it hands it back, and a tab let go
            // on a split's target is in the card bringing it into its half.
            if pictureInPicture.owns(tab) || tab.isInNativeFullscreen || isDroppingIntoSplit(tab) { continue }
            if !visible.contains(tab.id) {
                if tab.page.view.superview !== switcherPictureHost { tab.page.view.removeFromSuperview() }
                continue
            }
            releaseBackgroundPicturePage(tab)
            if tab.needsBlockingReload, tab.page.url != nil { tab.needsBlockingReload = false; tab.page.reloadIgnoringCache() }
            if tab.page.url == nil, !tab.hasAttemptedNavigation, !tab.page.isLoading, let url = tab.requestedURL { tab.load(url) }
            if tab.page.view.superview !== pageClip { pageClip.addSubview(tab.page.view, positioned: .below, relativeTo: developerBar) }
        }
    }
    @objc func toggleSplit() {
        if let selectedID, activeSplitGroup != nil { separateSplit(containing: selectedID); return }
        guard let current = selectedTab else { return }
        let previous = splitGroups
        var added: UUID?
        // Beside the tab before this one, or else the first other.
        let recent = recentTabIDs.lazy.filter { $0 != current.id }.compactMap { id in self.tabs.first { $0.id == id } }.first
        if let other = recent ?? tabs.first(where: { $0.id != current.id }) { showSplit(other) }
        else if let url = current.url {
            let other = configure(BrowserTab()); tabs.insert(other, at: 0); other.load(url); showSplit(other)
            added = other.id
        }
        if let group = activeSplitGroup, splitGroups != previous { registerSplitUndo(group: group.id, previous: previous, selectedID: current.id, addedTabID: added) }
    }
    func registerSplitUndo(group: UUID, previous: [SplitTabGroup], selectedID: UUID, addedTabID: UUID?) {
        splitUndo?.expiry.cancel()
        let expiry = DispatchWorkItem { [weak self] in self?.splitUndo = nil }
        splitUndo = SplitUndo(groupID: group, previous: previous, selectedID: selectedID, addedTabID: addedTabID, expiry: expiry)
        DispatchQueue.main.asyncAfter(deadline: .now()+Self.peekUndoDuration, execute: expiry)
    }
    /// ⌘Z shortly after Split View made a split, unless an address or search is being typed.
    func handleSplitUndoKey(_ event: NSEvent) -> Bool {
        guard splitUndo != nil, event.type == .keyDown,
              keyboardShortcuts.matches("undo:", event), palette.isHidden,
              !(window?.firstResponder is NSText) else { return false }
        return undoSplit()
    }
    /// Back to the one page and the splits there were, closing the copy of the page a split of a
    /// lone tab opened.
    @discardableResult func undoSplit() -> Bool {
        guard let undo = splitUndo else { return false }
        splitUndo = nil; undo.expiry.cancel()
        // Already taken apart, or changed since.
        guard splitGroups.contains(where: { $0.id == undo.groupID }) else { return false }
        splitGroups = undo.previous
        if let added = undo.addedTabID, tabs.contains(where: { $0.id == added }) {
            closeTab(added)
            if closedTabs.last?.id == added { closedTabs.removeLast() }
        }
        if tabs.contains(where: { $0.id == undo.selectedID }) { select(undo.selectedID) }
        attachVisiblePages(); update()
        return true
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
        guard let hit = root.hitTest(point), let group = activeSplitGroup else { return }
        // Each page's own bar too, so its buttons act on its page.
        if hit.isDescendant(of: splitBar) { if selectedID != group.rightID { select(group.rightID) }; return }
        if hit.isDescendant(of: navBar) { if selectedID != group.leftID { select(group.leftID) }; return }
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
        pageEdge.outline = outline
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
        splitHandle.onSwapSides = { [weak self] in self?.swapSplitSides() }
        splitHandle.swapShortcut = { NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.items.first { $0.action == #selector(BrowserController.swapSplitSides) } }.first }
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
    /// both live, laying out at every size, the left page's bar narrowing with it and the Peek's
    /// own bar sliding in along its top; then the Peek's page joins the tab list as the split.
    func splitPeekLive(_ tab: BrowserTab, card: Surface, finish: @escaping () -> Void) {
        guard let source = tabs.first(where: { $0.id == (peekSourceTabID ?? selectedID) }), source.id == selectedID,
              source.page.view.superview === pageClip, activeSplitGroup == nil else { finish(); return }
        finishPeekLiveMotion()
        isPromotingPeek = true; pageLayoutHeld = true
        let spring = Self.peekSplitSpring
        let frames = splitFrames(in: pageBody, fraction: 0.5), barHeight = PlainNavBar.Metrics.height
        let pageFrom = source.page.view.frame, cardFrom = card.frame
        // View geometry leaves out the page's recede, so this is where the right half settles,
        // with room above it for its bar.
        let cardTo = pageClip.convert(NSRect(x: frames.right.minX, y: frames.right.minY-barHeight, width: frames.right.width,
                                             height: frames.right.height+barHeight), to: root)
        let bar = splitBar
        showPageBar(bar, tab: tab, shown: &splitBarTabID)
        splitBarButtons[0].isEnabled = canNavigate(tab.page, .back); splitBarButtons[1].isEnabled = canNavigate(tab.page, .forward)
        (splitBarButtons[2] as? ReloadButton)?.setMode(tab.isLoading ? .stop : .reload)
        // The Peek's own bar is already across the card's top; the split's, alike, takes its place there.
        let barShown = showsPeekBar
        if let clip = card.subviews.first {
            bar.isHidden = false
            if barShown { bar.setColor(peekBar.color, animated: false); clip.addSubview(bar, positioned: .above, relativeTo: peekBar); peekBar.removeFromSuperview() }
            else { clip.addSubview(bar) }
        }
        if let page = tab.page as? ChromiumPage {
            Task { [weak self, weak tab] in
                guard let color = await page.topColor(), let self, let tab else { return }
                self.plainBarColors[tab.id] = color
                if self.splitBarTabID == tab.id { bar.setColor(color, animated: true) }
            }
        }
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
            // The bar comes down into the card's top as the page makes room under it, unless it's there already.
            let inset = barShown ? barHeight : barHeight*min(1, max(0, progress))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if bar.superview === card.subviews.first {
                bar.frame = NSRect(x: 0, y: inset-barHeight, width: card.bounds.width, height: barHeight)
                tab.page.view.frame = NSRect(x: 0, y: inset, width: card.bounds.width, height: card.bounds.height-inset)
            }
            let page = pageFrom.interpolated(to: frames.left, by: progress)
            source.page.view.frame = page; self.navBar.frame.size.width = page.width
            CATransaction.commit()
            self.shapePage(around: [page])
        }, completion: { [weak self, weak tab] in
            guard let self else { return }
            self.peekLiveMotion = nil; self.isPromotingPeek = false; self.pageLayoutHeld = false
            // Where it settled is where the split lays it out, so it hands over without a move.
            self.pageClip.addSubview(bar, positioned: .above, relativeTo: self.navBar)
            guard let tab, tab === self.peekTab else { self.layoutChrome(); return }
            finish()
        })
    }
    /// Fades a card's own shadow out and the page's in, Kero's, with Dark's lit edge, so nothing
    /// changes as it hands over.
    func matchPageShadow(_ card: Surface, duration: TimeInterval) {
        guard let layer = card.layer else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = (layer.presentation() ?? layer).shadowOpacity; fade.toValue = 0; fade.duration = duration
        layer.shadowOpacity = 0; layer.add(fade, forKey: "peek.split.shadowOpacity")
        guard let card = card as? PageSurface else { return }
        card.keroShadows = pageShadow.keroShadows
        card.fadeInShadows(duration: duration)
        guard !pageEdge.isHidden, let clip = card.subviews.first else { return }
        let edge = PageEdge(frame: clip.bounds); edge.autoresizingMask = [.width, .height]
        clip.addSubview(edge); edge.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = duration; edge.animator().alphaValue = 1 }
    }
}

/// A split Split View just made, and what there was before it.
struct SplitUndo {
    let groupID: UUID
    let previous: [SplitTabGroup]
    let selectedID: UUID
    /// The copy of the page opened to split a lone tab.
    let addedTabID: UUID?
    let expiry: DispatchWorkItem
}
