import AppKit
import RiseCore

/// Swapping a split's sides: a still of each page, with its bar, springs across to the other
/// side on a split's timing, the left one passing under the right, while the pages swap
/// underneath; the stills then fade to the live pages.
@MainActor extension BrowserController {
    /// The split's pages trade places, each keeping its share of the room.
    @objc func swapSplitSides() {
        guard let group = activeSplitGroup, splitGroups.contains(where: { $0.id == group.id }) else { return }
        guard peekMotionAllowed, !pageLayoutHeld, peekTab == nil, splitSwapMotion == nil,
              let left = tabs.first(where: { $0.id == group.leftID }), let right = tabs.first(where: { $0.id == group.rightID }),
              left.page.view.superview === pageClip, right.page.view.superview === pageClip else { swapSplitGroupSides(group.id); return }
        let bars = [splitHalfBar(navBar), splitHalfBar(splitBar)]
        var stills: [NSImage?] = [nil, nil], waiting = 2, started = false
        let start = { [weak self] in
            guard !started else { return }
            started = true
            guard let self, self.activeSplitGroup?.id == group.id, self.splitSwapMotion == nil, !self.pageLayoutHeld else { return }
            self.animateSplitSwap(group, stills: stills, bars: bars)
        }
        for (index, page) in [left.page, right.page].enumerated() {
            Task { stills[index] = await page.snapshot(width: nil); waiting -= 1; if waiting == 0 { start() } }
        }
        // A busy page mustn't hold the swap up.
        DispatchQueue.main.asyncAfter(deadline: .now()+0.08) { start() }
    }
    private func swapSplitGroupSides(_ id: UUID) {
        guard let index = splitGroups.firstIndex(where: { $0.id == id }) else { return }
        let group = splitGroups[index]
        splitGroups[index].leftID = group.rightID; splitGroups[index].rightID = group.leftID
        splitGroups[index].fraction = 1-group.fraction
        attachVisiblePages(); update(); scheduleSave()
    }
    private func splitHalfBar(_ bar: PlainNavBar) -> NSImage? {
        guard !bar.isHidden, bar.bounds.width > 0, let bitmap = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return nil }
        bar.cacheDisplay(in: bar.bounds, to: bitmap)
        let image = NSImage(size: bar.bounds.size); image.addRepresentation(bitmap)
        return image
    }
    private func animateSplitSwap(_ group: SplitTabGroup, stills: [NSImage?], bars: [NSImage?]) {
        let before = splitFrames(in: pageBody, fraction: group.fraction)
        let after = splitFrames(in: pageBody, fraction: 1-group.fraction)
        // Each half from the top of its bar to the page's foot, in the window's view.
        func half(_ frame: NSRect) -> NSRect { pageClip.convert(NSRect(x: frame.minX, y: 0, width: frame.width, height: frame.maxY), to: root) }
        let starts = [half(before.left), half(before.right)], ends = [half(after.right), half(after.left)]
        // The window's background where the pages were, so only the stills show as they cross.
        let backdrop = Surface(); backdrop.fill = theme.background
        backdrop.frame = pageShadow.convert(pageShadow.bounds, to: root)
        root.addSubview(backdrop, positioned: .below, relativeTo: dismissArea)
        let ghosts = (0..<2).map { index in
            SplitSwapGhost(page: stills[index], bar: bars[index], barHeight: PlainNavBar.Metrics.height, color: theme.page)
        }
        // The left one first, so it passes under the right.
        for ghost in ghosts { root.addSubview(ghost, positioned: .below, relativeTo: dismissArea); ghost.frame = starts[ghosts.firstIndex { $0 === ghost }!] }
        swapSplitGroupSides(group.id)
        let spring = Self.splitSwapSpring
        splitSwapMotion = PeekLiveMotion(on: backdrop, spring: spring, step: { progress in
            let lift = sin(.pi*min(1, max(0, progress)))
            for (index, ghost) in ghosts.enumerated() {
                var frame = starts[index].interpolated(to: ends[index], by: progress)
                // The one passing under sinks back a little as it goes; the other lifts.
                if index == 0 { frame = frame.insetBy(dx: frame.width*0.02*lift, dy: frame.height*0.02*lift) }
                ghost.place(frame, lift: index == 1 ? lift : 0, dim: index == 0 ? lift : 0)
            }
        }, completion: { [weak self] in
            guard let self else { return }
            self.splitSwapMotion = nil
            let views: [NSView] = ghosts+[backdrop]
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; views.forEach { $0.animator().alphaValue = 0 } },
                                                 completionHandler: { views.forEach { $0.removeFromSuperview() } })
        })
    }
    /// A split's own timing, with no bounce, so the pages settle straight into their sides.
    static var splitSwapSpring: CASpringAnimation { peekSplitSpring }
}

/// A still of one side of a split: its bar over its page, in the page's corners and shadow.
@MainActor final class SplitSwapGhost: NSView {
    private let clip = CALayer(), barLayer = CALayer(), pageLayer = CALayer(), shade = CALayer()
    private let barHeight: CGFloat
    init(page: NSImage?, bar: NSImage?, barHeight: CGFloat, color: NSColor) {
        self.barHeight = barHeight
        super.init(frame: .zero)
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor; layer.shadowOpacity = Float(PageAppearance.shadowOpacity)
        layer.shadowRadius = PageAppearance.shadowBlur; layer.shadowOffset = CGSize(width: 0, height: -PageAppearance.shadowOffset)
        clip.masksToBounds = true; clip.cornerRadius = PageAppearance.radius; clip.cornerCurve = .continuous
        clip.backgroundColor = color.cgColor
        barLayer.contents = bar; barLayer.contentsGravity = .resize
        pageLayer.contents = page; pageLayer.contentsGravity = .resizeAspectFill
        shade.backgroundColor = NSColor.black.cgColor; shade.opacity = 0
        [pageLayer, barLayer, shade].forEach(clip.addSublayer)
        layer.addSublayer(clip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// `lift` raises its shadow and `dim` darkens it, each from 0 to 1.
    func place(_ frame: NSRect, lift: CGFloat, dim: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.frame = frame
        let bounds = CGRect(origin: .zero, size: frame.size)
        clip.frame = bounds; shade.frame = bounds
        // The layer isn't flipped: the bar sits at the top, which is its far edge.
        barLayer.frame = CGRect(x: 0, y: bounds.height-barHeight, width: bounds.width, height: barHeight)
        pageLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height-barHeight))
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: PageAppearance.radius, cornerHeight: PageAppearance.radius, transform: nil)
        layer?.shadowOpacity = Float(PageAppearance.shadowOpacity+(0.22-PageAppearance.shadowOpacity)*lift)
        layer?.shadowRadius = PageAppearance.shadowBlur+8*lift
        shade.opacity = Float(0.06*dim)
        CATransaction.commit()
    }
}
