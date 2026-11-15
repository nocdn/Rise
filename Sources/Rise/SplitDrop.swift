import AppKit
import RiseCore

/// Dragging a tab from the sidebar onto the page to split it, as Dia does (`SplitDropPanel`): the
/// two targets come up as the drag begins, open out once it's over the page, are drawn to it and
/// light as it nears one, and go as it ends. Over the page, the dragged row becomes a picture of
/// its page. Let go on a lit target, the page there slides into the other half while the tab's own
/// page comes into this one from the target, as a Peek becomes a split; the tab chosen stays chosen.
@MainActor final class SplitDropTargets: NSObject {
    enum Phase { case hidden, waiting, open, leaving }
    weak var browser: BrowserController?
    let host = SplitDropHost(frame: .zero)
    let left = SplitDropPanel(side: .left), right = SplitDropPanel(side: .right)
    private(set) var phase = Phase.hidden
    private(set) var lit: SplitDropPanel.Side?
    /// The pointer, in the host's coordinates, while it's over the page.
    private var pointer: NSPoint?
    /// Just come onto the page from the sidebar, and not yet past its safe area.
    private var arriving = false
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    /// What's dragged: its row, the overlay it's lifted into, and its page's picture there.
    private weak var row: NSView?
    private weak var rowShadow: NSView?
    private var preview: SplitDragPreview?
    private var previewOpacity = Spring(value: 0), previewScale = Spring(value: 0.85)
    private var previewCenter = NSPoint.zero
    private var panels: [SplitDropPanel] { [left, right] }
    private(set) var tabID: UUID?

    var isShowing: Bool { phase != .hidden }
    var litPanel: SplitDropPanel? { lit.map { $0 == .left ? left : right } }

    // MARK: The drag

    func begin(_ drag: SidebarDrag, tab: BrowserTab) {
        guard let browser else { return }
        tabID = tab.id
        if host.superview !== browser.root { browser.root.addSubview(host, positioned: .above, relativeTo: browser.pageShadow) }
        host.isHidden = false
        for panel in panels where panel.layer.superlayer !== host.layer { host.layer?.addSublayer(panel.layer) }
        placeHost()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lit = nil; pointer = nil; arriving = false
        panels.forEach { $0.setLit(false) }
        // From nothing: each fades and grows to where it waits, around its own middle.
        if phase == .hidden {
            for panel in panels {
                panel.center.jump(to: waitingCenter(panel))
                panel.scale.jump(to: reduced ? SplitDropPanel.compactScale : SplitDropPanel.appearingScale)
                panel.opacity.jump(to: 0)
            }
        }
        phase = .waiting
        // Its page's picture, for when it's over the page.
        preview?.removeFromSuperview(); preview = nil
        row = drag.view; rowShadow = drag.overlay?.shadowView
        if let overlay = drag.overlay {
            let picture = SplitDragPreview(tab: tab, page: browser.pageBody.size, theme: browser.theme)
            picture.alphaValue = 0
            overlay.addSubview(picture, positioned: .above, relativeTo: nil)
            preview = picture
            previewOpacity.jump(to: 0); previewScale.jump(to: 0.85)
        }
        retarget(); startTicking()
    }
    func move(_ drag: SidebarDrag) {
        guard let browser, phase == .waiting || phase == .open, drag.id == tabID else { return }
        placeHost()
        let inRoot = browser.root.convert(drag.event.locationInWindow, from: nil)
        let overPage = drag.isDetached && browser.pageShadow.frame.contains(inRoot)
        if overPage, phase != .open { arriving = true }
        phase = overPage ? .open : .waiting
        pointer = overPage ? host.convert(inRoot, from: browser.root) : nil
        updateLit()
        if let overlay = drag.overlay { previewCenter = overlay.convert(drag.event.locationInWindow, from: nil) }
        previewOpacity.target = overPage ? 1 : 0
        previewScale.target = overPage ? 1 : 0.85
        retarget(); startTicking()
    }
    /// The drag's over: the targets go, the lit one fading under the page that comes from it when
    /// the tab was let go there; the dragged row comes back if it wasn't.
    func end(dropped: Bool) {
        guard phase != .hidden else { return }
        phase = .leaving; pointer = nil
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for panel in panels {
            panel.opacity.target = 0
            if !(dropped && panel.side == lit) { panel.scale.target = panel.scale.value*0.92 }
            if reduced { panel.opacity.jump(to: 0) }
        }
        if !dropped { lit = nil }
        previewOpacity.target = 0
        if dropped { previewOpacity.jump(to: 0); preview?.alphaValue = 0 }
        startTicking()
    }

    // MARK: Where the targets go

    private func placeHost() {
        guard let browser else { return }
        let frame = browser.pageClip.convert(browser.pageBody, to: browser.root)
        if host.frame != frame { host.frame = frame }
        let body = host.bounds.size
        let unit = min(max(min(body.height*0.61/SplitDropPanel.restSize.height, body.width*0.244/SplitDropPanel.restSize.width), 0.55), 1.2)
        let scale = browser.window?.backingScaleFactor ?? 2
        panels.forEach { $0.size(unit: unit, contentsScale: scale, dark: browser.theme == .dark) }
    }
    private func restCenter(_ panel: SplitDropPanel) -> NSPoint {
        let width = SplitDropPanel.restSize.width*panel.unit, inset = SplitDropPanel.inset*panel.unit
        let x = panel.side == .left ? inset+width/2 : host.bounds.width-inset-width/2
        return NSPoint(x: x, y: host.bounds.midY)
    }
    /// Smaller, its outer edge where it is at rest.
    private func waitingCenter(_ panel: SplitDropPanel) -> NSPoint {
        let width = SplitDropPanel.restSize.width*panel.unit*SplitDropPanel.compactScale, inset = SplitDropPanel.inset*panel.unit
        let x = panel.side == .left ? inset+width/2 : host.bounds.width-inset-width/2
        return NSPoint(x: x, y: host.bounds.midY)
    }
    /// A third of the way in from its edge, the nearer target lights; it goes out a little further back.
    private func updateLit() {
        var next = lit
        if let pointer, host.bounds.width > 0 {
            let u = pointer.x/host.bounds.width
            if next == .left, u > SplitDropPanel.unlitAt { next = nil }
            if next == .right, u < 1-SplitDropPanel.unlitAt { next = nil }
            if pointer.x >= SplitDropPanel.safeArea*left.unit { arriving = false }
            if next == nil { next = u < SplitDropPanel.litAt && !arriving ? .left : u > 1-SplitDropPanel.litAt ? .right : nil }
        } else { next = nil }
        guard next != lit else { return }
        lit = next
        panels.forEach { $0.setLit($0.side == next) }
        // A tap on the trackpad as the tab snaps into one.
        if next != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
    private func retarget() {
        for panel in panels {
            switch phase {
            case .hidden, .leaving: continue
            case .waiting:
                panel.center.send(to: waitingCenter(panel)); panel.scale.target = SplitDropPanel.compactScale; panel.opacity.target = 1
            case .open:
                let rest = restCenter(panel)
                panel.opacity.target = 1
                if panel.side == lit, let pointer {
                    let follow = SplitDropPanel.follow
                    panel.center.send(to: NSPoint(x: rest.x+(pointer.x-rest.x)*follow, y: rest.y+(pointer.y-rest.y)*follow))
                    panel.scale.target = SplitDropPanel.litScale
                } else {
                    // Drawn toward the pointer as it comes its way, more the nearer it gets.
                    var pull: CGFloat = 0
                    if let pointer, host.bounds.width > 0 {
                        let u = pointer.x/host.bounds.width, span = 0.5-SplitDropPanel.litAt
                        let t = min(1, max(0, panel.side == .left ? (0.5-u)/span : (u-0.5)/span))
                        pull = SplitDropPanel.pull*panel.unit*t*t*(panel.side == .left ? 1 : -1)
                    }
                    panel.center.send(to: NSPoint(x: rest.x+pull, y: rest.y))
                    panel.scale.target = 1
                }
            }
        }
    }

    // MARK: Each frame

    private func startTicking() {
        guard link == nil else { return }
        lastTick = nil
        link = host.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = CGFloat(min(1/30, max(0, now-(lastTick ?? now-1/120))))
        lastTick = now
        step(dt)
    }
    /// Moves everything on by `dt`, stopping once it's all where it's going.
    func step(_ dt: CGFloat) {
        let motion = Spring.motion, fade = Spring.fade
        var settled = true
        for panel in panels {
            let leaving = phase == .leaving
            panel.center.step(dt, response: motion.response, damping: motion.damping)
            panel.scale.step(dt, response: leaving ? 0.12 : motion.response, damping: leaving ? 1 : motion.damping)
            panel.opacity.step(dt, response: leaving ? 0.08 : fade.response, damping: fade.damping)
            panel.render()
            settled = settled && panel.center.isSettled && panel.scale.isSettled && panel.opacity.isSettled
        }
        previewOpacity.step(dt, response: 0.1, damping: 1)
        previewScale.step(dt, response: motion.response, damping: motion.damping)
        if let preview {
            let alpha = min(1, max(0, previewOpacity.value))
            preview.place(centeredAt: previewCenter, scale: previewScale.value)
            preview.alphaValue = alpha
            row?.alphaValue = 1-alpha; rowShadow?.alphaValue = 1-alpha
            settled = settled && previewOpacity.isSettled && previewScale.isSettled
        }
        if phase == .leaving, panels.allSatisfy({ $0.opacity.value < 0.01 }), previewOpacity.value < 0.01 { finish(); return }
        if settled { link?.invalidate(); link = nil }
    }
    /// Gone: nothing left over the page, and the row as it was.
    func finish() {
        link?.invalidate(); link = nil
        phase = .hidden; lit = nil; pointer = nil; tabID = nil
        for panel in panels { panel.opacity.jump(to: 0); panel.render(); panel.setLit(false) }
        host.isHidden = true
        row?.alphaValue = 1; rowShadow?.alphaValue = 1
        preview?.removeFromSuperview(); preview = nil
        row = nil; rowShadow = nil
    }
}

/// The dragged tab over the page: a picture of its page, the last taken, or its icon on the page's
/// colour, centred on the pointer, as Dia shows a dragged tab's page.
final class SplitDragPreview: FlippedView {
    static let width: CGFloat = 200
    let size: NSSize
    private let picture = CALayer()
    init(tab: BrowserTab, page: NSSize, theme: RiseTheme) {
        let aspect = page.width > 0 && page.height > 0 ? page.height/page.width : 0.6
        size = NSSize(width: Self.width, height: round(min(max(Self.width*aspect, 100), 140)))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10; layer?.shadowOffset = NSSize(width: 0, height: -4)
        picture.masksToBounds = true; picture.cornerRadius = 7; picture.cornerCurve = .continuous
        picture.borderWidth = 0.5; picture.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        picture.backgroundColor = theme.page.cgColor
        picture.contentsGravity = .resizeAspectFill
        if let image = tab.thumbnail.flatMap({ Self.topCrop($0, to: size) }) {
            picture.contents = image
        } else if let icon = tab.favicon(for: theme) {
            let iconLayer = CALayer()
            iconLayer.contents = icon; iconLayer.contentsGravity = .resizeAspect
            iconLayer.frame = NSRect(x: size.width/2-14, y: size.height/2-14, width: 28, height: 28)
            picture.addSublayer(iconLayer)
        }
        layer?.addSublayer(picture)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); picture.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func place(centeredAt point: NSPoint, scale: CGFloat) {
        let shown = NSSize(width: size.width*scale, height: size.height*scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = NSRect(x: point.x-shown.width/2, y: point.y-shown.height/2, width: shown.width, height: shown.height)
        picture.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        CATransaction.commit()
    }
    /// The page's top, as wide as it is, filling the picture.
    static func topCrop(_ image: NSImage, to size: NSSize) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = size.width/image.size.width
        let shown = NSSize(width: size.width, height: image.size.height*scale)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // Top-aligned: the image's top at the picture's top.
        image.draw(in: NSRect(x: 0, y: size.height-shown.height, width: shown.width, height: shown.height))
        out.unlockFocus()
        return out
    }
}

@MainActor extension BrowserController {
    /// The splits the sidebar shows: those there are, and the one a dropped tab is forming.
    var sidebarSplitGroups: [SplitTabGroup] {
        guard let pending = pendingSplitDrop else { return splitGroups }
        return splitGroups.filter { !$0.contains(pending.leftID) && !$0.contains(pending.rightID) }+[pending]
    }
    /// A tab let go on a target, its page in the card bringing it into its half.
    func isDroppingIntoSplit(_ tab: BrowserTab) -> Bool {
        splitDropMotion != nil && tab.id != selectedID && pendingSplitDrop?.contains(tab.id) == true
    }

    func installSplitDrop() {
        splitDrop.browser = self
        sidebar.onTabDragBegan = { [weak self] drag in
            guard let self, let tab = self.splitDropCandidate(drag) else { return }
            self.splitDrop.begin(drag, tab: tab)
        }
        sidebar.onTabDragMoved = { [weak self] drag in self?.splitDrop.move(drag) }
        sidebar.onTabDragEnded = { [weak self] _ in self?.splitDrop.end(dropped: false) }
        sidebar.onTabDrop = { [weak self] drag, _ in self?.dropOnSplitTarget(drag) ?? false }
    }
    /// A tab a drag could put beside the page: one tab, not the page itself, onto a page on its own.
    func splitDropCandidate(_ drag: SidebarDrag) -> BrowserTab? {
        guard drag.view is TabRow, let current = selectedTab, drag.id != current.id,
              let tab = tabs.first(where: { $0.id == drag.id }), !tab.pinned,
              activeSplitGroup == nil, peekTab == nil, !pageLayoutHeld, splitDropMotion == nil, duplicateMotion == nil,
              current.page.view.superview === pageClip, !pictureInPicture.owns(current), !pictureInPicture.owns(tab),
              !current.isInNativeFullscreen, !tab.isInNativeFullscreen, !isSwitchingTabs else { return nil }
        return tab
    }
    /// Let go on a lit target: the tab comes into that half.
    private func dropOnSplitTarget(_ drag: SidebarDrag) -> Bool {
        guard splitDrop.phase == .open, drag.id == splitDrop.tabID, let panel = splitDrop.litPanel,
              let tab = splitDropCandidate(drag) else { return false }
        let start = splitDrop.host.convert(panel.shownFrame, to: root), radius = panel.cornerRadius
        splitDrop.end(dropped: true)
        dropIntoSplit(tab, side: panel.side, from: start, radius: radius)
        return true
    }

    /// The page slides into the other half as the tab's page comes into this one from its target,
    /// growing from the target's shape into the page's, live, as a Peek becomes a split; then the two
    /// are a split, the page that was there still chosen. The sidebar shows the split at once.
    func dropIntoSplit(_ tab: BrowserTab, side: SplitDropPanel.Side, from start: NSRect, radius startRadius: CGFloat) {
        guard let current = selectedTab else { return }
        let previous = splitGroups
        let group = side == .left ? SplitTabGroup(leftID: tab.id, rightID: current.id) : SplitTabGroup(leftID: current.id, rightID: tab.id)
        pendingSplitDrop = group
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: sidebarSplitGroups, animated: true)
        let join = { [weak self] in
            guard let self else { return }
            self.pendingSplitDrop = nil
            guard self.tabs.contains(where: { $0 === tab }), self.tabs.contains(where: { $0 === current }) else { self.update(); return }
            self.splitGroups.removeAll { $0.contains(current.id) || $0.contains(tab.id) }
            self.splitGroups.append(group)
            self.select(self.selectedID ?? current.id)
            self.registerSplitUndo(group: group.id, previous: previous, selectedID: current.id, addedTabID: nil)
        }
        guard peekMotionAllowed, current.page.view.superview === pageClip else { join(); return }

        // Its page wakes, if it was asleep, to be shown.
        releaseBackgroundPicturePage(tab)
        if tab.needsBlockingReload, tab.page.url != nil { tab.needsBlockingReload = false; tab.page.reloadIgnoringCache() }
        if tab.page.url == nil, !tab.hasAttemptedNavigation, !tab.page.isLoading, let url = tab.requestedURL { tab.load(url) }

        let barHeight = PlainNavBar.Metrics.height, body = pageBody
        let frames = splitFrames(in: body, fraction: 0.5)
        let (newHalf, oldHalf) = side == .left ? (frames.left, frames.right) : (frames.right, frames.left)
        let target = pageClip.convert(NSRect(x: newHalf.minX, y: 0, width: newHalf.width, height: pageClip.bounds.height), to: root)
        pageLayoutHeld = true

        // The card: the page's shape, the tab's bar and page, and its last picture over a page that
        // hasn't drawn yet.
        let card = PageSurface(color: theme.page, radius: PageAppearance.radius)
        card.layer?.masksToBounds = false; card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.2
        card.layer?.shadowRadius = 14; card.layer?.shadowOffset = NSSize(width: 0, height: -3)
        let clip = PageSurface(color: theme.page, radius: PageAppearance.radius)
        clip.layer?.masksToBounds = true; clip.clipsToBounds = true; clip.layer?.cornerCurve = .continuous
        card.addSubview(clip); clip.addSubview(tab.page.view)
        setCovered(false, tab)
        var standIn: NSImageView?
        if let still = tab.thumbnail, tab.page.url == nil || tab.isLoading {
            let view = NSImageView(image: still)
            view.imageScaling = .scaleProportionallyUpOrDown; view.imageAlignment = .alignTop; view.wantsLayer = true
            view.layer?.backgroundColor = theme.page.cgColor
            clip.addSubview(view); standIn = view
        }
        let bar = splitBar
        showPageBar(bar, tab: tab, shown: &splitBarTabID)
        splitBarButtons[0].isEnabled = canNavigate(tab.page, .back); splitBarButtons[1].isEnabled = canNavigate(tab.page, .forward)
        (splitBarButtons[2] as? ReloadButton)?.setMode(tab.isLoading ? .stop : .reload)
        bar.isHidden = false; clip.addSubview(bar)
        root.addSubview(card, positioned: .below, relativeTo: dismissArea)
        func place(_ frame: NSRect, radius: CGFloat) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            card.frame = frame; clip.frame = card.bounds
            card.layer?.cornerRadius = radius; clip.layer?.cornerRadius = radius
            bar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: barHeight)
            let page = NSRect(x: 0, y: barHeight, width: card.bounds.width, height: max(0, card.bounds.height-barHeight))
            tab.page.view.frame = page; standIn?.frame = page
            card.refreshOutline(); clip.refreshOutline()
            CATransaction.commit()
        }
        place(start, radius: startRadius)
        // It comes up in the target's place as the target fades, then takes on the page's shadow.
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; card.animator().alphaValue = 1 }
        let spring = Self.peekSplitSpring
        matchPageShadow(card, duration: spring.perceptualDuration)

        let pageFrom = current.page.view.frame, barFrom = navBar.frame
        splitDropMotion = PeekLiveMotion(on: card, spring: spring, step: { [weak self, weak card, weak current] progress in
            guard let self, card != nil, let current else { return }
            let radius = startRadius+(PageAppearance.radius-startRadius)*min(1, max(0, progress))
            place(start.interpolated(to: target, by: progress), radius: radius)
            let page = pageFrom.interpolated(to: oldHalf, by: progress)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            current.page.view.frame = page
            self.navBar.frame = NSRect(x: page.minX, y: barFrom.minY, width: page.width, height: barFrom.height)
            CATransaction.commit()
            self.shapePage(around: [page])
        }, completion: { [weak self] in
            guard let self else { return }
            self.splitDropMotion = nil; self.pageLayoutHeld = false
            // The tab's page and its bar stay where they settled, now in the page.
            self.pageClip.addSubview(bar, positioned: .above, relativeTo: self.navBar)
            tab.page.view.removeFromSuperview()
            join()
            card.removeFromSuperview()
            if let standIn { self.fadeDuplicateStandIn(standIn, over: tab) }
        })
    }
}
