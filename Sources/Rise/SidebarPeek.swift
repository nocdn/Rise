import AppKit

enum SidebarWidth {
    /// The width the sidebar is designed around. Resizing snaps to it with a haptic tick.
    static let ideal: CGFloat = 220
    /// The ideal width before it narrowed; a sidebar saved there moves with it.
    static let previousIdeal: CGFloat = 228
    static let range: ClosedRange<CGFloat> = 200...360
    /// How close a resize has to come to `ideal` to snap to it.
    static let snap: CGFloat = 8
    /// Holding Control-Command widens the sidebar, to show longer titles.
    static let wide = ideal*1.35
    static let peekKeys: NSEvent.ModifierFlags = [.control, .command]
    static let peekResponse = 0.12

    /// The width for a resize to `x`, held at `ideal` while within `snap` of it.
    static func resized(to x: CGFloat) -> CGFloat {
        let width = min(range.upperBound, max(range.lowerBound, x))
        return abs(width-ideal) <= snap ? ideal : width
    }
}

/// While Control-Command is held, the sidebar is wider, and a collapsed one opens until
/// the keys are released. Tabs can still be switched, closed and dragged meanwhile, and
/// toggling the sidebar keeps a peeked one open.
@MainActor final class SidebarPeek {
    fileprivate(set) var isActive = false
    /// The peek opened a collapsed sidebar, so letting go closes it again.
    fileprivate(set) var openedSidebar = false
    /// 0 at the sidebar's own width, 1 at its peek width.
    fileprivate var spring = MotionSpring(0)
    fileprivate var link: CADisplayLink?
    fileprivate var lastTick: CFTimeInterval?
    var progress: CGFloat { CGFloat(spring.value) }
    init() { spring.configure(response: SidebarWidth.peekResponse, bounce: 0) }
}

@MainActor extension BrowserController {
    var displayedSidebarWidth: CGFloat {
        sidebarWidth+(max(sidebarWidth, SidebarWidth.wide)-sidebarWidth)*sidebarPeek.progress
    }
    /// Dragging the grip, snapping to the ideal width with a tick on arrival.
    func resizeSidebar(to x: CGFloat) {
        let width = SidebarWidth.resized(to: x)
        if width == SidebarWidth.ideal && sidebarWidth != SidebarWidth.ideal {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        sidebarWidth = width; layoutChrome(); scheduleSave()
    }
    func sidebarPeekModifiersChanged(_ flags: NSEvent.ModifierFlags) {
        if flags.intersection([.command, .control, .option, .shift]) == SidebarWidth.peekKeys { beginSidebarPeek() }
        else { endSidebarPeek() }
    }
    /// Toggling the sidebar while a peek holds a collapsed one open keeps it open; letting
    /// go then only narrows it. True when that's what the toggle did.
    func keepPeekedSidebar() -> Bool {
        guard sidebarPeek.openedSidebar, sidebarVisible else { return false }
        sidebarPeek.openedSidebar = false
        return true
    }
    func beginSidebarPeek() {
        let peek = sidebarPeek
        guard !peek.isActive, !isSwitchingTabs else { return }
        peek.isActive = true
        if sidebarVisible { animateSidebarPeek(to: 1); return }
        // A collapsed sidebar opens as ⌘B shows it, already wide.
        peek.spring.target = 1; peek.spring.settle()
        toggleSidebar(); peek.openedSidebar = true
    }
    func endSidebarPeek() {
        let peek = sidebarPeek
        guard peek.isActive else { return }
        peek.isActive = false
        guard peek.openedSidebar else { animateSidebarPeek(to: 0); return }
        peek.openedSidebar = false
        peek.link?.invalidate(); peek.link = nil
        peek.spring.target = 0; peek.spring.settle()
        if sidebarVisible { toggleSidebar() }
    }
    private func animateSidebarPeek(to target: Double) {
        let peek = sidebarPeek
        peek.spring.target = target
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            peek.link?.invalidate(); peek.link = nil; peek.spring.settle(); layoutSidebarPeek(); return
        }
        guard peek.link == nil else { return }
        peek.lastTick = CACurrentMediaTime()
        let link = root.displayLink(target: self, selector: #selector(tickSidebarPeek(_:)))
        link.add(to: .main, forMode: .common); peek.link = link
    }
    @objc private func tickSidebarPeek(_ link: CADisplayLink) {
        let peek = sidebarPeek
        let now = CACurrentMediaTime(), dt = min(0.05, now-(peek.lastTick ?? now)); peek.lastTick = now
        peek.spring.step(dt)
        if peek.spring.isResting(within: 0.001) { peek.spring.settle(); link.invalidate(); peek.link = nil }
        layoutSidebarPeek()
    }
    private func layoutSidebarPeek() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChrome(); root.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
}
