import AppKit

/// Slides only the chrome, leaving the fullscreen page and hover strip in place.
/// Reversing under the pointer keeps the spring's current position and velocity.
@MainActor final class FullscreenNavigationSlide {
    private weak var view: NSView?
    weak var companion: NSView?
    private(set) var frame: NSRect
    private var spring = MotionSpring(1)
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?

    init(view: NSView) { self.view = view; frame = view.frame }
    func place(_ frame: NSRect) { self.frame = frame; apply() }
    func setHidden(_ hidden: Bool, animated: Bool) {
        let target: Double = hidden ? 0 : 1
        // Other chrome animations can be placing a normally shown bar. Leave
        // that frame alone when fullscreen has nothing to move.
        if spring.target == target, spring.isResting(within: 0.001), link == nil {
            if let view { companion?.frame = view.frame }
            return
        }
        if spring.target != target { ChromeSlideMotion.configure(&spring, showing: !hidden) }
        spring.target = target
        guard animated, view?.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            settle(); apply(); return
        }
        apply()
        guard link == nil, !spring.isResting(within: 0.001), let view else { return }
        lastTick = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard view?.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            settle(); apply(); return
        }
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        spring.step(dt)
        if spring.isResting(within: 0.001) { settle() }
        apply()
    }
    private func settle() {
        link?.invalidate(); link = nil; lastTick = nil; spring.settle()
    }
    private func apply() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shown = frame.offsetBy(dx: 0, dy: -frame.maxY*CGFloat(1-spring.value))
        view?.frame = shown; companion?.frame = shown
        CATransaction.commit()
    }
}

/// Tracks the top strip even while its navigation bar is offscreen. It never
/// takes clicks from the video underneath or the revealed navigation buttons.
@MainActor final class FullscreenNavigationHover: NSView {
    var changed: (() -> Void)?
    private var popoverObserver: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.isHidden { self.changed?() } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { changed?() }
    override func mouseExited(with event: NSEvent) { changed?() }
    override func mouseMoved(with event: NSEvent) { changed?() }
}

@MainActor extension BrowserController {
    static let fullscreenNavigationKey = "Rise.AutoHideNavigationInSimulatedFullScreen"
    var autoHidesFullscreenNavigation: Bool { preferences.object(forKey: Self.fullscreenNavigationKey) as? Bool ?? true }

    func setAutoHidesFullscreenNavigation(_ value: Bool) {
        preferences.set(value, forKey: Self.fullscreenNavigationKey)
        layoutChrome()
    }
    func overlaysFullscreenNavigation(for tab: BrowserTab?) -> Bool {
        guard let tab else { return false }
        return autoHidesFullscreenNavigation && pageFullscreen.isSimulated && peekTab == nil && pageFullscreen.isActive(in: tab.page.view)
    }
    /// Hover moves only the bar. Fullscreen pages always fill the space behind
    /// it, so neither the video nor its controls jump as it slides.
    func fullscreenContentFrame(for tab: BrowserTab?, regular frame: NSRect) -> NSRect {
        guard overlaysFullscreenNavigation(for: tab) else { return frame }
        return NSRect(x: frame.minX, y: 0, width: frame.width, height: frame.maxY)
    }
    func layoutFullscreenNavigation() {
        let hover = fullscreenNavigationHover
        let active = pageBarTabs.contains { overlaysFullscreenNavigation(for: $0.tab) }
        hover.isHidden = !active
        if active {
            if hover.superview !== root { root.addSubview(hover, positioned: .above, relativeTo: nil) }
            let header = root.convert(NSRect(x: 0, y: 0, width: pageClip.bounds.width, height: PlainNavBar.Metrics.height), from: pageClip)
            hover.frame = NSRect(x: header.minX, y: 0, width: header.width, height: header.maxY)
        }
        refreshFullscreenNavigation()
    }
    /// `pointer` is in window coordinates; explicit points also make the hover
    /// and layout rules testable without moving the user's cursor.
    func refreshFullscreenNavigation(pointer: NSPoint? = nil) {
        guard let window else { return }
        let point = pageClip.convert(pointer ?? window.mouseLocationOutsideOfEventStream, from: nil)
        // Follow the sidebar's destination, not its still-visible closing frames,
        // so both bars start leaving on the same fullscreen change.
        let held = isSidebarShown || palette.isPresented ||
            siteControlsPopover.isShown || siteInfoPopover.isShown || zoomPopover.isShown || capturePopover.isShown || extensionPopup != nil
        // A split's old bar may still be finishing its slide after selection changes.
        // Only the currently selected bar can carry the shared developer header.
        for bar in [navBar, splitBar] { bar.fullscreenSlide.companion = nil }
        for (bar, tab) in pageBarTabs {
            // Include the narrow window margin above the page, so reaching the
            // very top edge reveals the bar too.
            let frame = bar.fullscreenSlide.frame
            let top = min(frame.minY, pageClip.convert(.zero, from: root).y)
            let reveal = NSRect(x: frame.minX, y: top, width: frame.width, height: frame.maxY-top)
            let overlays = overlaysFullscreenNavigation(for: tab)
            bar.fullscreenSlide.companion = bar === selectedBar ? developerBar : nil
            // Keep animating the return after fullscreen has ended as well.
            bar.setFullscreenHidden(overlays && !held && !reveal.contains(point), animated: true)
        }
        if pageBarTabs.isEmpty { navBar.setFullscreenHidden(false, animated: false) }
    }
}
