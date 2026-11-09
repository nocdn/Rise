import AppKit

/// What the tab list's scrolling shows: its edges dissolving where more tabs lie past them, as
/// shadcn's scroll-fade (ui.shadcn.com/docs/utils/scroll-fade), and a pill for the chosen tab once
/// it's scrolled out of the list.
enum SidebarScrollCues {
    /// As deep as scroll-fade's: 12% of the list, up to 40 points.
    static func fadeDepth(height: CGFloat) -> CGFloat { min(40, height*0.12) }
    /// How far from an end the fade takes to appear fully, as scroll-fade's reveal.
    static let reveal: CGFloat = 96
    /// How much of what's clipped at each edge shows as a fade, 0 to 1: none at the list's very
    /// top or bottom, or in a list that doesn't scroll. Rubber-banding past an end stays at none.
    struct Edges: Equatable {
        var top: CGFloat, bottom: CGFloat
        init(top: CGFloat, bottom: CGFloat) { self.top = top; self.bottom = bottom }
        init(offset: CGFloat, contentHeight: CGFloat, viewHeight: CGFloat) {
            top = min(1, max(0, offset)/reveal)
            bottom = min(1, max(0, contentHeight-viewHeight-offset)/reveal)
        }
    }
    enum Direction: Equatable { case above, below }
    /// A row showing less than this much, inside the fade, reads as gone.
    static let visibleMargin: CGFloat = 12
    /// Where a row lies when it's out of what the list shows, or nil while it's in view.
    static func direction(of row: NSRect, visible: NSRect) -> Direction? {
        if row.maxY <= visible.minY+visibleMargin { return .above }
        if row.minY >= visible.maxY-visibleMargin { return .below }
        return nil
    }
}

/// The chosen tab's favicon and an arrow towards its row, over the edge of the list it's past.
/// Clicking it scrolls back to the tab.
@MainActor final class ChosenTabPill: NSButton {
    static let size = NSSize(width: 50, height: 26)
    /// How far inside the list's edge it floats.
    static let inset: CGFloat = 8
    private static let up = TablerIcon.image("M12 19V5m6 6l-6-6m-6 6l6-6", size: 16, strokeWidth: 1.25, description: "Above")
    private static let down = TablerIcon.image("M12 5v14m6-6l-6 6m-6-6l6 6", size: 16, strokeWidth: 1.25, description: "Below")
    let icon = FaviconView(frame: NSRect(x: 10, y: 5, width: 16, height: 16))
    let arrow = NSImageView(frame: NSRect(x: 28, y: 5, width: 16, height: 16))
    /// The chosen tab's own look: its fill, Light's ring and Dark's lit edge and shadows.
    private let tabLook = PlainTabBackground()
    /// Where it's pointing, or nil when it's gone or going.
    private(set) var direction: SidebarScrollCues.Direction?
    /// AppKit turns a button's clipping back on; its shadow lies outside it.
    override var clipsToBounds: Bool { get { false } set {} }
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isBordered = false; title = ""; wantsLayer = true; isHidden = true; alphaValue = 0
        setAccessibilityLabel("Show current tab")
        layer?.masksToBounds = false
        layer?.cornerRadius = Self.size.height/2; layer?.cornerCurve = .continuous
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.size.height/2, cornerHeight: Self.size.height/2, transform: nil)
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.shadowRadius = 6
        arrow.imageScaling = .scaleNone
        tabLook.frame = bounds; tabLook.radius = Self.size.height/2
        tabLook.show(chosen: true, hovered: false, animated: false)
        [tabLook, icon, arrow].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Rows take a click through to the window's first mouse; so does this.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func apply(_ theme: RiseTheme) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Drawn as the chosen tab is, over the sidebar's own colour, so it's solid as the rows pass under it.
        layer?.backgroundColor = theme.background.cgColor
        tabLook.dark = theme == .dark
        layer?.shadowOpacity = theme == .dark ? 0.32 : 0.12
        CATransaction.commit()
        arrow.contentTintColor = theme.sidebarIcon
    }
    /// Takes the row's favicon, or its empty placeholder.
    func showIcon(of row: TabRow) {
        icon.contentTintColor = row.icon.contentTintColor
        if let image = row.icon.image {
            if icon.image !== image { icon.image = image }
        } else { icon.showEmptyPlaceholder(theme: row.theme) }
    }
    /// How it comes out: from under half its size, a little towards the edge it's by, so it rises
    /// from the list's bottom and drops from its top, with a slight bounce as it lands.
    static let entranceScale: CGFloat = 0.45, entranceSlide: CGFloat = 30
    static let entranceFade: TimeInterval = 0.09, exitFade: TimeInterval = 0.1
    /// Where the entrance starts, scaling around the pill's middle rather than its layer's corner.
    nonisolated static func entranceStart(_ direction: SidebarScrollCues.Direction, size: CGSize, anchor: CGPoint) -> CATransform3D {
        let center = CGPoint(x: (0.5-anchor.x)*size.width, y: (0.5-anchor.y)*size.height)
        var transform = CATransform3DMakeTranslation(-center.x, -center.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(entranceScale, entranceScale, 1))
        return CATransform3DConcat(transform, CATransform3DMakeTranslation(center.x, center.y+(direction == .above ? -entranceSlide : entranceSlide), 0))
    }
    private var animates: Bool { window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private func fade(to alpha: CGFloat, duration: TimeInterval, completion: @escaping @MainActor () -> Void = {}) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        } completionHandler: { MainActor.assumeIsolated { completion() } }
    }
    private func comeOut(_ next: SidebarScrollCues.Direction) {
        guard animates, let layer else { alphaValue = 1; return }
        alphaValue = 0
        fade(to: 1, duration: Self.entranceFade)
        let pop = CASpringAnimation(perceptualDuration: 0.24, bounce: 0.26)
        pop.keyPath = "transform"
        pop.fromValue = NSValue(caTransform3D: Self.entranceStart(next, size: layer.bounds.size, anchor: layer.anchorPoint))
        pop.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "Rise.PillEntrance")
    }
    /// Comes out at a new place when it appears or changes sides, and fades quickly when its tab's in view.
    func show(_ next: SidebarScrollCues.Direction?, at frame: NSRect?) {
        let previous = direction
        direction = next
        guard let next, let frame else {
            guard previous != nil else { return }
            guard animates else { alphaValue = 0; isHidden = true; return }
            fade(to: 0, duration: Self.exitFade) { [weak self] in
                if self?.direction == nil { self?.isHidden = true }
            }
            return
        }
        if self.frame != frame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.frame = frame
            CATransaction.commit()
        }
        guard next != previous else { return }
        arrow.image = next == .above ? Self.up : Self.down
        isHidden = false
        comeOut(next)
    }
}

extension SidebarView {
    /// Fades the list's edges for where it's scrolled, and points to the chosen tab if it's past them.
    func updateScrollCues() {
        let clip = scroll.contentView
        updateScrollFade(SidebarScrollCues.Edges(offset: clip.bounds.minY, contentHeight: rowsHost.frame.height, viewHeight: clip.bounds.height))
        guard !isRevealingChosenTab, drag == nil, !isSearchingTabs, let id = selectedTabID, let row = displayedRow(for: id), !row.isHidden,
              let direction = SidebarScrollCues.direction(of: row.frame, visible: clip.bounds) else {
            chosenPill.show(nil, at: nil); return
        }
        if let tab = rows[id] { chosenPill.showIcon(of: tab) }
        let y = direction == .above ? scroll.frame.minY+ChosenTabPill.inset : scroll.frame.maxY-ChosenTabPill.inset-ChosenTabPill.size.height
        let frame = NSRect(x: ((bounds.width-ChosenTabPill.size.width)/2).rounded(), y: y.rounded(),
                           width: ChosenTabPill.size.width, height: ChosenTabPill.size.height)
        chosenPill.show(direction, at: frame)
    }
    private func updateScrollFade(_ edges: SidebarScrollCues.Edges) {
        guard scrollFade.frame != scroll.bounds || shownEdges != edges else { return }
        shownEdges = edges
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scrollFade.frame = scroll.bounds
        let height = max(1, scroll.bounds.height), depth = SidebarScrollCues.fadeDepth(height: height)/height
        scrollFade.locations = [0, NSNumber(value: Double(depth)), NSNumber(value: Double(1-depth)), 1]
        scrollFade.colors = [NSColor.black.withAlphaComponent(1-edges.top).cgColor, NSColor.black.cgColor,
                             NSColor.black.cgColor, NSColor.black.withAlphaComponent(1-edges.bottom).cgColor]
        // Without a fade, the list needn't draw through a mask.
        scroll.layer?.mask = edges.top == 0 && edges.bottom == 0 ? nil : scrollFade
        CATransaction.commit()
    }
    /// Scrolls the chosen tab to the middle of the list, or as near as the list's ends allow, clear
    /// of its fading edges: a quick ease out, with the pill fading away first rather than following.
    @objc func revealChosenTab() {
        guard let id = selectedTabID, let row = displayedRow(for: id) else { return }
        let clip = scroll.contentView
        let limit = max(0, rowsHost.frame.height-clip.bounds.height)
        let target = NSPoint(x: clip.bounds.minX, y: min(limit, max(0, row.frame.midY-clip.bounds.height/2)))
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clip.scroll(to: target); scroll.reflectScrolledClipView(clip); return
        }
        isRevealingChosenTab = true
        updateScrollCues()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.isRevealingChosenTab = false
                self.scroll.reflectScrolledClipView(clip)
                self.updateScrollCues()
            }
        }
    }
}
