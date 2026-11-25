import AppKit

/// Covers a floating window while it's tucked past the screen's side: under the pointer the window
/// grows a touch (`onHover`), a little less than it does as two fingers move it; a click brings it
/// out, and a right-click shows what its window offers there.
@MainActor final class FloatingTuckHandle: NSView {
    var onClick: (() -> Void)?
    /// What a right-click (or a Control-click) shows while it's tucked.
    var makeMenu: (() -> NSMenu?)?
    /// A drag on the tucked window moves it, as one on its picture does.
    var mouseDrag: ((NSEvent) -> Void)?
    /// The pointer came over the tucked window, or left it: the window grows, or settles back.
    var onHover: ((Bool) -> Void)?
    /// The side the window is tucked past; nil when it isn't, which lets clicks through.
    var edge: FloatingVideoMotion.Edge? {
        didSet {
            guard edge != oldValue else { return }
            update()
        }
    }
    private var hovered = false
    private var shown = false
    /// Whether it's grown under the pointer.
    var isHovered: Bool { shown }
    /// The middle of the part on the screen, in its own coordinates, where a click brings it out.
    var showingCenter: CGPoint {
        let part = showing ?? bounds
        return CGPoint(x: part.midX, y: part.midY)
    }
    private var downPoint: NSPoint?, dragged = false
    /// The part of it on the screen, in its own coordinates.
    var showing: NSRect?
    /// How far tucked the window has to be for the pointer to grow it.
    static let showsFrom: CGFloat = 0.95
    /// Follows the pointer itself, in a window that takes the mouse while it's tucked.
    var tracksHover = false {
        didSet { if tracksHover { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) } }
    }
    /// Whether the pointer coming over it grows it; the veil says, as the window moves.
    var allowsHover: () -> Bool = { true }
    override func mouseEntered(with event: NSEvent) { if tracksHover, allowsHover() { setHovered(true) } }
    override func mouseExited(with event: NSEvent) { if tracksHover { setHovered(false) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Bring Back")
    }
    required init?(coder: NSCoder) { fatalError() }

    func setHovered(_ hovered: Bool) {
        guard hovered != self.hovered else { return }
        self.hovered = hovered; update()
    }
    private func update() {
        let show = edge != nil && hovered
        guard show != shown else { return }
        shown = show
        onHover?(show)
    }

    // Only while tucked does it take the window's clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { edge == nil ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), showMenu(for: event) { return }
        downPoint = event.locationInWindow; dragged = false
    }
    override func rightMouseDown(with event: NSEvent) { if !showMenu(for: event) { super.rightMouseDown(with: event) } }
    override func menu(for event: NSEvent) -> NSMenu? { edge == nil ? nil : makeMenu?() }
    private func showMenu(for event: NSEvent) -> Bool {
        guard let menu = menu(for: event) else { return false }
        setHovered(false)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        if !dragged, hypot(event.locationInWindow.x-downPoint.x, event.locationInWindow.y-downPoint.y) >= 3 {
            dragged = true
            mouseDrag?(NSEvent.mouseEvent(with: .leftMouseDown, location: downPoint, modifierFlags: event.modifierFlags,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) ?? event)
        }
        if dragged { mouseDrag?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { mouseDrag?(event) } else if downPoint != nil { onClick?() }
        downPoint = nil; dragged = false
    }
    override func accessibilityPerformPress() -> Bool { guard edge != nil else { return false }; onClick?(); return true }
}

/// How a floating window looks as it tucks: its picture blurs and darkens by how far it's past
/// the side, heavily once tucked.
private extension NSRect {
    var area: CGFloat { isNull ? 0 : width*height }
}

enum FloatingTuckLook {
    /// The screen a window showing `frame` belongs to: the one most of what shows is on.
    static func screen(holding frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
    }
    /// The sides of `screen` a window can tuck past: those no other display carries on from, where
    /// it would only show again.
    static func tuckableEdges(of screen: NSScreen) -> Set<FloatingVideoMotion.Edge> {
        let frame = screen.frame
        let beside = NSScreen.screens.filter { $0 != screen && $0.frame.minY < frame.maxY && $0.frame.maxY > frame.minY }
        var edges = Set<FloatingVideoMotion.Edge>()
        if !beside.contains(where: { abs($0.frame.maxX-frame.minX) < 1 }) { edges.insert(.left) }
        if !beside.contains(where: { abs($0.frame.minX-frame.maxX) < 1 }) { edges.insert(.right) }
        return edges
    }
    static let blur: CGFloat = 24
    /// Stops darker, fully tucked.
    static let darkening: CGFloat = 1.1
    /// Sets `layer`'s filters for `progress`, and returns the scale about its middle, for the layer
    /// or its sublayers, that keeps the blur's soft edge outside a picture of `size`.
    static func apply(_ progress: CGFloat, to layer: CALayer, size: CGSize) -> CATransform3D {
        guard progress > 0.001 else {
            // A resting zero-radius blur still costs a filter pass every frame.
            layer.filters = nil; return CATransform3DIdentity
        }
        if layer.filters?.count != 2, let blur = CIFilter(name: "CIGaussianBlur"), let dark = CIFilter(name: "CIExposureAdjust") {
            blur.name = "tuckBlur"; dark.name = "tuckDark"; layer.filters = [blur, dark]
        }
        let radius = progress*blur
        layer.setValue(radius, forKeyPath: "filters.tuckBlur.inputRadius")
        layer.setValue(-progress*darkening, forKeyPath: "filters.tuckDark.inputEV")
        let scale = 1+4*radius/max(1, min(size.width, size.height))
        var transform = CATransform3DMakeTranslation(size.width/2, size.height/2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -size.width/2, -size.height/2, 0)
    }
}

/// A page's own floating window (Meet's call) is Chrome's, but its views and layers live in Rise:
/// tucking it, Rise blurs its content in place, as it does its own floating video, and lays a
/// window of its own over it, moving with it, for the tuck handle.
@MainActor final class FloatingPageTuck {
    static let shared = FloatingPageTuck()
    private let veils = NSMapTable<NSWindow, FloatingPageVeil>.weakToStrongObjects()
    var onUntuck: ((NSWindow) -> Void)?

    /// The side `window` is tucked past, if it is.
    func edge(of window: NSWindow) -> FloatingVideoMotion.Edge? { veils.object(forKey: window)?.edge }
    func veil(of window: NSWindow) -> FloatingPageVeil? { veils.object(forKey: window) }

    /// Shows `window` as far tucked as it is past `area`'s side, on its way to `edge` or back.
    func apply(_ window: NSWindow, edge: FloatingVideoMotion.Edge?, area: NSRect, dragging: Bool = false) {
        let progress = FloatingVideoMotion.tuckProgress(content: window.frame, visibleFrame: area)
        let resting = progress <= 0.001 && edge == nil
        if let veil = veils.object(forKey: window) {
            if resting { veil.remove(); veils.removeObject(forKey: window) } else { veil.update(progress: progress, edge: edge, dragging: dragging) }
            return
        }
        guard !resting, window.isVisible else { return }
        let veil = FloatingPageVeil(page: window)
        veil.handle.onClick = { [weak self, weak window] in if let window { self?.onUntuck?(window) } }
        veil.handle.makeMenu = { [weak self, weak window] in
            guard let self, let window else { return nil }
            let menu = NSMenu(), action = MenuAction { [weak self, weak window] in if let window { self?.onUntuck?(window) } }
            let item = NSMenuItem(title: "Untuck", action: #selector(MenuAction.invoke), keyEquivalent: "")
            item.target = action; item.representedObject = action
            menu.addItem(item); return menu
        }
        veils.setObject(veil, forKey: window)
        veil.update(progress: progress, edge: edge, dragging: dragging)
    }
}

@MainActor final class FloatingPageVeil: NSPanel {
    private(set) weak var page: NSWindow?
    private(set) var edge: FloatingVideoMotion.Edge?
    let handle = FloatingTuckHandle()
    private var closeObserver: Any?
    /// How far the page's content shows tucked, blurred to match.
    private(set) var progress: CGFloat = 0
    var pageIsBlurred: Bool { page?.contentView?.layer?.filters?.isEmpty == false }

    init(page: NSWindow) {
        self.page = page
        super.init(contentRect: page.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isReleasedWhenClosed = false
        animationBehavior = .none; ignoresMouseEvents = true; level = page.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: NSRect(origin: .zero, size: page.frame.size))
        content.autoresizesSubviews = true
        handle.frame = content.bounds; handle.autoresizingMask = [.width, .height]; handle.tracksHover = true
        handle.allowsHover = { [weak self] in (self?.progress ?? 0) > FloatingTuckHandle.showsFrom }
        handle.onHover = { [weak page] hovered in if let page { FloatingPageHover.shared.grow(hovered, page) } }
        content.addSubview(handle)
        contentView = content
        page.contentView?.layerUsesCoreImageFilters = true
        page.addChildWindow(self, ordered: .above)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: page, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove() }
        }
    }

    func update(progress: CGFloat, edge: FloatingVideoMotion.Edge?, dragging: Bool = false) {
        guard let page else { return }
        self.edge = edge; self.progress = progress
        // Moving, it's back at its size: the window server's scaling is placed for where it was.
        if dragging || edge == nil { FloatingPageHover.shared.settle(page) }
        if frame != page.frame { setFrame(page.frame, display: false) }
        blur(page, by: progress)
        if let screen = FloatingTuckLook.screen(holding: page.frame) {
            let part = page.frame.intersection(screen.frame)
            handle.showing = part.isNull ? nil : part.offsetBy(dx: -page.frame.minX, dy: -page.frame.minY)
        }
        handle.edge = edge
        ignoresMouseEvents = edge == nil
        // Tracking areas miss a window that moved under a still pointer, as one flicked away does;
        // and fingers moving it aren't pointing at it.
        handle.setHovered(edge != nil && !dragging && progress > FloatingTuckHandle.showsFrom && frame.contains(NSEvent.mouseLocation))
    }

    /// The page's content blurs where it is, grown about its middle (through its sublayers, since
    /// AppKit places its own layer) enough that the blur's soft edge falls outside the window.
    private func blur(_ page: NSWindow, by progress: CGFloat) {
        guard let layer = page.contentView?.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayerTransform = FloatingTuckLook.apply(progress, to: layer, size: layer.bounds.size)
        CATransaction.commit()
    }

    func remove() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        if let page { blur(page, by: 0); FloatingPageHover.shared.settle(page) }
        page?.removeChildWindow(self); orderOut(nil)
    }
}
