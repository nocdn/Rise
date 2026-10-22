import AppKit

/// Measured against Dia's floating sidebar: it rests one page margin in from the
/// window's edges, rounded and lifted a little off the page.
enum SidebarFloatAppearance {
    /// How close to the window's left edge the pointer comes before the sidebar slides out.
    static let edge: CGFloat = 8
    static let inset = PageAppearance.inset
    static let radius: CGFloat = 12
    static let shadowOpacity: Float = 0.15
    static let shadowRadius: CGFloat = 10
}

/// Watches the window's left edge while the sidebar is collapsed. Clicks pass through.
final class SidebarEdgeView: NSView {
    var touched: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { touched?() }
    // A button held on the way in (a text selection, say) is let go here.
    override func mouseMoved(with event: NSEvent) { touched?() }
}

/// Casts the floating sidebar's shadow onto the page. The sidebar clips its own layer to
/// its rounded corners, which would cut off a shadow of its own.
final class SidebarShadowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.masksToBounds = false; layer?.shadowColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// With the sidebar collapsed, the pointer at the window's left edge slides the same
/// sidebar out over the page, and it tucks away once the pointer leaves it. Toggling the
/// sidebar meanwhile docks it, the page making room beside it.
@MainActor final class SidebarFloat {
    /// 0 tucked past the window's edge, 1 out over the page.
    fileprivate var slide = MotionSpring(1)
    /// 0 floating over the page, 1 docked beside it.
    fileprivate var dock = MotionSpring(1)
    fileprivate var link: CADisplayLink?
    fileprivate var lastTick: CFTimeInterval?
    fileprivate var watch: Timer?
    /// Where AppKit puts the traffic lights beside a docked sidebar, and how far they're carried from there.
    fileprivate var dockedOrigins: [NSPoint] = []
    fileprivate var carried = NSPoint.zero
    let edge = SidebarEdgeView()
    let shadow = SidebarShadowView()
    /// The sidebar is out, or on its way out.
    var isOut: Bool { slide.target > 0 }
    /// Still on screen, including on its way back in.
    var isVisible: Bool { slide.target > 0 || slide.value != 0 || slidesDocked }
    /// Collapsing, the docked sidebar slides off to the left as the page widens after it,
    /// keeping its docked shape; `dock` runs it from 1 to 0.
    fileprivate(set) var slidesDocked = false
    var slideProgress: CGFloat { CGFloat(slide.value) }
    var dockProgress: CGFloat { CGFloat(dock.value) }
    init() {
        // Quick, with a few points of overshoot as it lands.
        slide.configure(response: 0.185, bounce: 0.2)
        dock.configure(response: Self.dockResponse, bounce: 0)
    }
    static let dockResponse = 0.15
    /// Quick, with a gentler spring than sliding out.
    fileprivate func configureCollapse() { dock.configure(response: 0.17, bounce: 0.15) }
    /// Opening lands with the same small overshoot as sliding out.
    fileprivate func configureOpen() { dock.configure(response: 0.185, bounce: 0.2) }
    fileprivate func configureDock() {
        dock.configure(response: Self.dockResponse, bounce: 0)
    }
}

@MainActor extension BrowserController {
    /// The sidebar is docked, or floating out over the page.
    var isSidebarShown: Bool { sidebarVisible || sidebarFloat.isOut }
    var isSidebarFloating: Bool { !sidebarVisible && sidebarFloat.isOut }

    func installSidebarEdge() {
        sidebarFloat.edge.touched = { [weak self] in self?.sidebarEdgeTouched() }
        root.addSubview(sidebarFloat.edge, positioned: .above, relativeTo: pageShadow)
        root.addSubview(sidebarFloat.shadow, positioned: .below, relativeTo: sidebar)
    }
    /// Places the sidebar between floating over the page and docked beside it, and
    /// returns where the page's left edge goes.
    func layoutFloatingSidebar(in bounds: NSRect, width: CGFloat) -> CGFloat {
        let float = sidebarFloat, inset = SidebarFloatAppearance.inset
        let docksFully = sidebarVisible || float.slidesDocked
        let slide = docksFully ? 1 : float.slideProgress, dock = docksFully ? float.dockProgress : 0
        let docked = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        if float.slidesDocked {
            sidebar.frame = docked.offsetBy(dx: -width*(1-dock), dy: 0)
        } else {
            // Floating, it's always the ideal width, easing to the sidebar's own as it docks.
            let floating = SidebarWidth.ideal
            let out = NSRect(x: inset-(floating+inset+2*SidebarFloatAppearance.shadowRadius)*(1-slide), y: inset, width: floating, height: bounds.height-2*inset)
            sidebar.frame = NSRect(x: out.minX+(docked.minX-out.minX)*dock, y: out.minY+(docked.minY-out.minY)*dock,
                                   width: out.width+(docked.width-out.width)*dock, height: out.height+(docked.height-out.height)*dock)
        }
        let lift = float.slidesDocked ? 0 : 1-dock, radius = SidebarFloatAppearance.radius*lift
        // Plain's docked sidebar is the window's wash; over the page, it's solid.
        sidebar.fill = theme.isPlain && lift == 0 ? .clear : theme.background
        sidebar.layer?.cornerCurve = .continuous; sidebar.cornerRadius = radius
        let dark = theme == .dark
        sidebar.layer?.borderWidth = lift > 0 ? 0.5 : 0
        sidebar.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent((dark ? 0.1 : 0.08)*lift).cgColor
        // Floating, it covers the page and takes the clicks there.
        let overPage = lift > 0 && (sidebarVisible || float.isVisible)
        let subviews = root.subviews
        if let own = subviews.firstIndex(of: sidebar), let page = subviews.firstIndex(of: pageShadow), (own > page) != overPage {
            root.addSubview(sidebar, positioned: overPage ? .above : .below, relativeTo: pageShadow)
        }
        let shadow = float.shadow
        if let own = root.subviews.firstIndex(of: sidebar), root.subviews.firstIndex(of: shadow) != own-1 {
            root.addSubview(shadow, positioned: .below, relativeTo: sidebar)
        }
        shadow.isHidden = !overPage
        if overPage, let layer = shadow.layer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shadow.frame = sidebar.frame
            // Cast mostly toward the page, setting the sidebar apart from it.
            layer.shadowOffset = NSSize(width: 2, height: -1)
            layer.shadowRadius = SidebarFloatAppearance.shadowRadius
            layer.shadowOpacity = SidebarFloatAppearance.shadowOpacity*(dark ? 2 : 1)*Float(lift)
            layer.shadowPath = PageOutline.path(in: shadow.bounds, radius: radius, continuous: true)
            CATransaction.commit()
        }
        float.edge.frame = NSRect(x: 0, y: 0, width: SidebarFloatAppearance.edge, height: bounds.height)
        float.edge.isHidden = sidebarVisible || float.isOut
        return PageAppearance.inset+(width-PageAppearance.inset)*dock
    }
    private var trafficLights: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }
    /// Moves the traffic lights by the sidebar's offset from its docked place, so they ride with it.
    func carryTitlebarControls(by offset: NSPoint) {
        let float = sidebarFloat
        // Unmoved, they're already in place: AppKit moving them carries them straight back, below.
        // Laying the whole titlebar out on every update cost each tab close a frame or two.
        if !float.dockedOrigins.isEmpty, offset == float.carried { return }
        if float.dockedOrigins.isEmpty {
            // AppKit lays the titlebar out again whenever it changes; they're carried straight back.
            for button in trafficLights {
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) { [weak self] _ in
                    // AppKit can settle a button again right after saying it moved, so check once more.
                    MainActor.assumeIsolated { self?.placeTrafficLights() }
                    DispatchQueue.main.async { self?.placeTrafficLights() }
                }
            }
        }
        let returning = float.carried != .zero && offset == .zero
        float.carried = offset
        // AppKit lays the titlebar out again when anything in it changes; let it finish first.
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        if returning {
            for (button, docked) in zip(trafficLights, float.dockedOrigins) where button.frame.origin != docked { button.setFrameOrigin(docked) }
        }
        placeTrafficLights()
    }
    private func placeTrafficLights() {
        let float = sidebarFloat
        // Docked, they're where AppKit wants them, which is where they're carried from.
        if float.carried == .zero { float.dockedOrigins = trafficLights.map(\.frame.origin); return }
        for (button, docked) in zip(trafficLights, float.dockedOrigins) {
            guard let parent = button.superview else { continue }
            let origin = NSPoint(x: docked.x+float.carried.x, y: docked.y+(parent.isFlipped ? float.carried.y : -float.carried.y))
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
    func sidebarEdgeTouched() {
        guard !sidebarVisible, !sidebarFloat.isOut, window?.isKeyWindow == true, NSEvent.pressedMouseButtons == 0,
              !palette.isPresented, !isSwitchingTabs else { return }
        revealFloatingSidebar()
    }
    func revealFloatingSidebar() {
        guard !sidebarVisible else { return }
        let float = sidebarFloat
        float.link?.invalidate(); float.link = nil
        float.slidesDocked = false; float.configureDock()
        float.dock.target = 0; float.dock.settle()
        float.slide.target = 1
        if float.watch == nil {
            let watch = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watchFloatingSidebar() } }
            RunLoop.main.add(watch, forMode: .common); float.watch = watch
        }
        animateSidebarFloat()
    }
    func tuckFloatingSidebar() {
        guard isSidebarFloating else { return }
        stopWatchingFloatingSidebar()
        tabPressed(); sidebar.newTab.resetHover()
        sidebarFloat.slide.target = 0
        animateSidebarFloat()
    }
    /// Toggling the sidebar: a floating one docks, the page sliding over to make room;
    /// otherwise it appears or disappears at once.
    func settleSidebarFloat(docking: Bool) {
        let float = sidebarFloat
        stopWatchingFloatingSidebar()
        if docking && sidebarVisible {
            float.configureDock()
            float.slide.target = 1; float.dock.target = 1
            animateSidebarFloat(); return
        }
        // Toggled, the docked sidebar springs in and out from the window's edge.
        if !sidebarVisible && float.dock.value > 0 || sidebarVisible {
            float.slidesDocked = true
            if sidebarVisible { float.configureOpen() } else { float.configureCollapse() }
            float.slide.target = sidebarVisible ? 1 : 0; float.slide.settle()
            float.dock.target = sidebarVisible ? 1 : 0
            animateSidebarFloat(); return
        }
        float.link?.invalidate(); float.link = nil
        float.slidesDocked = false; float.configureDock()
        let value: Double = sidebarVisible ? 1 : 0
        float.slide.target = value; float.slide.settle()
        float.dock.target = value; float.dock.settle()
    }
    /// Docks the sidebar without its spring, for something about to point into it.
    func showSidebarAtOnce() {
        guard !sidebarVisible else { return }
        toggleSidebar()
        let float = sidebarFloat
        float.link?.invalidate(); float.link = nil
        float.slide.settle(); float.dock.settle()
        if float.slidesDocked { float.slidesDocked = false; float.configureDock() }
        layoutSidebarFloat()
    }
    private func stopWatchingFloatingSidebar() {
        sidebarFloat.watch?.invalidate(); sidebarFloat.watch = nil
    }
    /// Menus, drags, popovers and the address palette opened from the sidebar hold it out,
    /// as does the pointer anywhere left of its right edge, even outside the window.
    var holdsFloatingSidebar: Bool {
        guard let window else { return false }
        if RunLoop.current.currentMode == .eventTracking || NSEvent.pressedMouseButtons != 0 { return true }
        if palette.isPresented || sidebar.drag != nil || tabHoverCards.shownID != nil { return true }
        if [siteControlsPopover, downloadsPopover, siteInfoPopover].contains(where: \.isShown) { return true }
        var responder = window.firstResponder as? NSView
        if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSView }
        if responder?.isDescendant(of: sidebar) == true { return true }
        let pointer = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // Measured against where it rests, so it holds while still sliding out under the pointer.
        return pointer.x <= SidebarFloatAppearance.inset+SidebarWidth.ideal
    }
    private func watchFloatingSidebar() {
        let float = sidebarFloat
        guard isSidebarFloating else { stopWatchingFloatingSidebar(); return }
        placeTrafficLights()
        // Off the sidebar, even onto its shadow, it tucks straight away.
        if !holdsFloatingSidebar { tuckFloatingSidebar() }
    }
    private func animateSidebarFloat() {
        let float = sidebarFloat
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            float.link?.invalidate(); float.link = nil
            float.slide.settle(); float.dock.settle()
            if float.slidesDocked { float.slidesDocked = false; float.configureDock() }
            layoutSidebarFloat(); return
        }
        guard float.link == nil else { return }
        float.lastTick = CACurrentMediaTime()
        let link = root.displayLink(target: self, selector: #selector(tickSidebarFloat(_:)))
        link.add(to: .main, forMode: .common); float.link = link
        layoutSidebarFloat()
    }
    @objc private func tickSidebarFloat(_ link: CADisplayLink) {
        let float = sidebarFloat
        let now = CACurrentMediaTime(), dt = min(0.05, now-(float.lastTick ?? now)); float.lastTick = now
        float.slide.step(dt); float.dock.step(dt)
        if float.slide.isResting(within: 0.001) && float.dock.isResting(within: 0.001) {
            float.slide.settle(); float.dock.settle(); link.invalidate(); float.link = nil
            if float.slidesDocked { float.slidesDocked = false; float.configureDock() }
        }
        layoutSidebarFloat()
    }
    fileprivate func layoutSidebarFloat() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChrome(); root.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
}
