import AppKit

/// A page's own floating window (Meet's call, from Document Picture-in-Picture) is Chrome's, with
/// its title bar along the top. Two fingers on that bar move it just as they move Rise's floating
/// video: flicked, it springs to the nearest corner; let go slowly, it stays where it's left. It
/// keeps its size throughout: only its place changes, every frame of the display. Flicked off the
/// screen's left or right side, it tucks away past it, as the floating video does
/// (`FloatingPageTuck`), and two fingers anywhere on it then move it.
@MainActor final class FloatingPageGestures {
    static let shared = FloatingPageGestures()
    /// Chrome's picture-in-picture title bar (kTopControlsHeight, Rise's rise_pip::kTopBarHeight).
    static let barHeight: CGFloat = 36
    let abandonedDragTimeout: CFTimeInterval = 1.5
    private var monitor: Any?, globalMonitor: Any?
    private weak var window: NSWindow?
    private var motion: FloatingVideoMotion?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?, lastInput: CFTimeInterval?
    /// The system's momentum after a move belongs to the move, not to the page under the pointer.
    private var swallowsMomentum = false
    private var dragging: Bool { motion?.phase == .dragging }

    func install() {
        guard monitor == nil else { return }
        FloatingPageEntrance.shared.install(); FloatingPageExit.shared.install(); FloatingPageWatcher.shared.install()
        FloatingPageTuck.shared.onUntuck = { [weak self] window in self?.untuck(window) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.route(.from(event), in: event.window, at: event.locationInWindow) == true ? nil : event
        }
    }

    /// Whether a scroll at `point` in `window` is the move's, taken from the page.
    func route(_ input: FloatingVideoScrollInput, in window: NSWindow?, at point: NSPoint) -> Bool {
        if dragging { handle(input); return true }
        if swallowsMomentum {
            if !input.momentumPhase.isEmpty {
                if input.momentumPhase.contains(.ended) || input.momentumPhase.contains(.cancelled) { swallowsMomentum = false }
                return true
            }
            swallowsMomentum = false
        }
        // Tucked, the veil over the window takes the scroll, anywhere on it.
        let veil = window as? FloatingPageVeil
        guard input.momentumPhase.isEmpty, input.phase.contains(.began), let window = veil?.page ?? window else { return false }
        // A dialog the window holds (the auto picture-in-picture choice, a site's permission) is a
        // window of its own over it, and leaves the bar beneath it to move the window.
        var page = window, location = point
        if veil == nil, !Self.isFloatingPage(window), let parent = window.parent, Self.isFloatingPage(parent) {
            let inParent = parent.convertPoint(fromScreen: window.convertPoint(toScreen: point))
            if Self.startsMove(at: inParent, in: parent) { page = parent; location = inParent }
        }
        let moves = input.precise && (veil != nil || Self.startsMove(at: location, in: page))
        if FloatingPageWatcher.shared.watches(page) {
            let reason = !input.precise ? "not a trackpad's" : veil != nil ? "on its tuck veil"
                : !Self.isFloatingChromeWindow(page) ? "not Chrome's floating window"
                : !Self.isFloatingPage(page) ? "the window doesn't hold its page yet"
                : location.y < page.frame.height-Self.barHeight ? "below the bar, so the page's" : "on the bar"
            let verb = moves ? "move" : "don't move"
            FloatingPageLog.logger.notice("Two fingers \(verb, privacy: .public) it: \(reason, privacy: .public), at y \(Int(location.y)) of \(Int(page.frame.height)); \(FloatingPageLog.describe(page), privacy: .public)")
        }
        guard moves else { return false }
        begin(page, at: input.timestamp)
        handle(input)
        return true
    }

    /// Over the title bar of a page's floating window.
    static func startsMove(at point: NSPoint, in window: NSWindow) -> Bool {
        point.y >= window.frame.height-barHeight && isFloatingPage(window)
    }
    /// Chrome's picture-in-picture window holding a page, not its floating video, which has no page.
    static func isFloatingPage(_ window: NSWindow) -> Bool {
        guard isFloatingChromeWindow(window), let content = window.contentView else { return false }
        return holdsPage(content)
    }
    /// Chrome's floating window, which may not hold its page yet as it first shows.
    static func isFloatingChromeWindow(_ window: NSWindow) -> Bool {
        guard let frameless = NSClassFromString("NativeWidgetMacFramelessNSWindow"), window.isKind(of: frameless) else { return false }
        return window.parent == nil && window.level.rawValue >= NSWindow.Level.floating.rawValue
    }
    private static func holdsPage(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)) == "RenderWidgetHostViewCocoa" || view.subviews.contains(where: holdsPage)
    }

    private func handle(_ input: FloatingVideoScrollInput) {
        guard var motion, input.precise else { return }
        let phase = input.phase
        if input.momentumPhase.isEmpty, phase.contains(.began) || phase.contains(.changed) {
            motion.drag(by: input.translation, at: input.timestamp)
            lastInput = CACurrentMediaTime()
        }
        self.motion = motion
        if phase.contains(.ended) || phase.contains(.cancelled) { end(at: input.timestamp, cancelled: phase.contains(.cancelled)) }
    }

    private func begin(_ window: NSWindow, at timestamp: TimeInterval) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        stopClock()
        FloatingPageEntrance.shared.finish(window)
        self.window = window
        let area = placementArea(on: screen)
        var motion = FloatingVideoMotion(frame: window.frame, visibleFrame: area,
                                         tucked: FloatingPageTuck.shared.edge(of: window), tuckable: FloatingTuckLook.tuckableEdges(of: screen))
        motion.begin(at: timestamp)
        self.motion = motion; swallowsMomentum = false
        let tucked = motion.tucked.map { ", tucked \($0)" } ?? ""
        FloatingPageLog.logger.notice("Two fingers take it\(tucked, privacy: .public), within \(FloatingPageLog.describe(area), privacy: .public): \(FloatingPageLog.describe(window), privacy: .public)")
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        startClock()
        // The window slides out from under the pointer, which may then be over another app.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { if self?.dragging == true { self?.handle(.from(event)) } }
        }
    }
    /// Brings a tucked window back onto the screen, from wherever it is on its way.
    func untuck(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if motion == nil || self.window !== window {
            stopClock(); self.window = window
            motion = FloatingVideoMotion(frame: window.frame, visibleFrame: placementArea(on: screen), tucked: FloatingPageTuck.shared.edge(of: window))
        }
        guard motion?.phase != .dragging else { return }
        motion?.untuck()
        FloatingPageTuck.shared.apply(window, edge: nil, area: placementArea(on: screen))
        startClock()
    }
    private func end(at timestamp: TimeInterval, cancelled: Bool) {
        motion?.end(at: timestamp, cancelled: cancelled, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if let motion {
            let verb = cancelled ? "stop" : "let go", tucking = motion.tucked.map { ", tucking \($0)" } ?? ""
            FloatingPageLog.logger.notice("Two fingers \(verb, privacy: .public) at \(FloatingPageLog.describe(motion.frame), privacy: .public), flung \(Int(motion.velocity.dx)), \(Int(motion.velocity.dy)) pt/s\(tucking, privacy: .public)")
        }
        lastInput = nil; swallowsMomentum = !cancelled
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        startClock()
    }
    /// As the floating video's: the screen, or the edges of a browser window that nearly fills it.
    private func placementArea(on screen: NSScreen) -> NSRect {
        let browser = NSApp.orderedWindows.first { $0 is BrowserWindow && $0.isVisible && $0.screen == screen }
        return FloatingVideoMotion.placementArea(visibleFrame: screen.visibleFrame, browserFrame: browser?.frame)
    }

    private func startClock() {
        guard displayLink == nil, let screen = window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); displayLink = link; lastFrameTime = nil
    }
    private func stopClock() {
        displayLink?.invalidate(); displayLink = nil; lastFrameTime = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let window, window.isVisible else { motion = nil; stopClock(); return }
        let elapsed = lastFrameTime.map { link.timestamp-$0 } ?? 1.0/120
        lastFrameTime = link.timestamp
        // Resting fingers send nothing, so allow a pause before giving up.
        if dragging, let lastInput, CACurrentMediaTime()-lastInput > abandonedDragTimeout {
            end(at: ProcessInfo.processInfo.systemUptime, cancelled: true)
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion?.step(elapsed: elapsed, reduceMotion: reduced)
        // Moving the window without resizing it leaves the page's layout and drawing alone.
        if let origin = motion?.frame.origin, origin != window.frame.origin {
            FloatingPageLog.riseIsMoving = true; window.setFrameOrigin(origin); FloatingPageLog.riseIsMoving = false
        }
        if let screen = window.screen ?? NSScreen.main {
            FloatingPageTuck.shared.apply(window, edge: motion?.tucked, area: placementArea(on: screen), dragging: dragging)
        }
        if motion?.phase == .idle {
            FloatingPageLog.logger.notice("Settles: \(FloatingPageLog.describe(window), privacy: .public)")
            motion = nil
        }
        if motion == nil { stopClock() }
    }
}

/// A page's floating window comes in as Rise's floating video does: growing from slightly smaller
/// with a light bounce while Chrome fades it in. Being Chrome's window, with the system's frame and
/// shadow, the window server scales the whole of it.
@MainActor final class FloatingPageEntrance {
    static let shared = FloatingPageEntrance()
    static let startScale = FloatingEntrance.startScale, stiffness = FloatingEntrance.stiffness, dampingRatio = FloatingEntrance.dampingRatio
    private var observers: [Any] = []
    private let entered = NSHashTable<NSWindow>.weakObjects()
    private weak var window: NSWindow?
    private var displayLink: CADisplayLink?, startTime: CFTimeInterval?, waitingSince: CFTimeInterval?
    private typealias SetTransform = @convention(c) (Int32, Int32, CGAffineTransform) -> Int32
    private typealias Connection = @convention(c) () -> Int32
    /// The window server's own calls, absent from the SDK, so looked up as Rise runs.
    private static let setTransform: SetTransform? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowTransform")
        .map { unsafeBitCast($0, to: SetTransform.self) }
    private static let connection: Connection? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID")
        .map { unsafeBitCast($0, to: Connection.self) }

    /// Whether the window server's scaling is there to use, and a window is springing in now.
    static var isAvailable: Bool { setTransform != nil && connection != nil }
    var isEntering: Bool { displayLink != nil }
    func install() {
        guard observers.isEmpty else { return }
        // The engine says so just before it shows the window and fades it in, so the spring
        // starts with its first frame; delivered as posted.
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("RisePictureInPictureWillShow"), object: nil, queue: nil) { note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { FloatingPageEntrance.shared.begin(window) } }
        })
        // Otherwise it's caught as it shows, still faint.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.occlusionState.contains(.visible),
                      FloatingPageGestures.isFloatingChromeWindow(window) else { return }
                FloatingPageEntrance.shared.begin(window)
            }
        })
    }
    private func begin(_ window: NSWindow) {
        guard !entered.contains(window) else { return }
        entered.add(window)
        FloatingPageLog.logger.notice("Comes in: \(FloatingPageLog.describe(window), privacy: .public), holding its page \(FloatingPageGestures.isFloatingPage(window))")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, Self.setTransform != nil, Self.connection != nil,
              let screen = window.screen ?? NSScreen.main else { return }
        finish(self.window)
        self.window = window; startTime = nil; waitingSince = CACurrentMediaTime()
        apply(Self.startScale, to: window)
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); displayLink = link
    }
    /// The spring's scale `time` seconds in: the step response of an underdamped spring from rest.
    static func scale(at time: Double) -> CGFloat {
        let omega = stiffness.squareRoot(), decay = dampingRatio*omega
        let damped = omega*(1-dampingRatio*dampingRatio).squareRoot()
        let remaining = exp(-decay*time)*(cos(damped*time) + decay/damped*sin(damped*time))
        return 1 - (1-startScale)*CGFloat(remaining)
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard let window else { displayLink?.invalidate(); displayLink = nil; return }
        guard window.isVisible else {
            // Held small until it shows, unless it never does.
            if startTime == nil, let waitingSince, CACurrentMediaTime()-waitingSince < 1 { apply(Self.startScale, to: window) } else { finish(window) }
            return
        }
        let start = startTime ?? link.timestamp; startTime = start
        let time = link.targetTimestamp-start, scale = Self.scale(at: time)
        if time > 0.2 && abs(scale-1) < 0.0005 { finish(window); return }
        apply(scale, to: window)
    }
    /// Ends the entrance at full size, as a move taking the window does.
    func finish(_ window: NSWindow?) {
        guard let window, window === self.window else { return }
        displayLink?.invalidate(); displayLink = nil; self.window = nil
        apply(1, to: window)
    }
    /// Shows `window` at `scale` about its middle. The transform takes screen points (top-left
    /// origin) to the window's own, so a smaller window divides by the scale.
    private func apply(_ scale: CGFloat, to window: NSWindow) {
        guard let setTransform = Self.setTransform, let connection = Self.connection,
              let top = NSScreen.screens.first?.frame.maxY else { return }
        let frame = window.frame
        let origin = CGPoint(x: frame.midX-frame.width*scale/2, y: top-frame.midY-frame.height*scale/2)
        _ = setTransform(connection(), Int32(window.windowNumber), CGAffineTransform(scaleX: 1/scale, y: 1/scale).translatedBy(x: -origin.x, y: -origin.y))
    }
}

/// A page's floating window closing from its own X or return button goes as Rise's floating video
/// does. Chrome closes the window at once, so the engine says so first, while it still shows: Rise
/// takes its picture, frame and shadow too, and plays the close on that in a window of its own.
@MainActor final class FloatingPageExit {
    static let shared = FloatingPageExit()
    /// Room around the window for its shadow, and for the blur to spread into.
    static let margin: CGFloat = 60
    private var observer: Any?
    private var leaving: [NSWindow] = []

    func install() {
        guard observer == nil else { return }
        // Delivered as the engine posts it, before the window goes.
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("RisePictureInPictureWillClose"), object: nil, queue: nil) { note in
            MainActor.assumeIsolated { if let window = note.object as? NSWindow { FloatingPageExit.shared.windowWillClose(window) } }
        }
    }
    func windowWillClose(_ window: NSWindow) {
        FloatingPageEntrance.shared.finish(window)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window.isVisible,
              let top = NSScreen.screens.first?.frame.maxY else { return }
        let frame = window.frame.insetBy(dx: -Self.margin, dy: -Self.margin)
        // Only this window's pixels, placed on the screen as they show.
        guard let picture = CGWindowListCreateImage(CGRect(x: frame.minX, y: top-frame.maxY, width: frame.width, height: frame.height),
                                                    .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution]) else { return }
        let stand = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        stand.isOpaque = false; stand.backgroundColor = .clear; stand.hasShadow = false; stand.ignoresMouseEvents = true
        stand.isReleasedWhenClosed = false; stand.animationBehavior = .none; stand.level = window.level
        stand.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true; content.layerUsesCoreImageFilters = true
        content.layer?.contents = picture; content.layer?.contentsGravity = .resize
        content.layer?.contentsScale = window.backingScaleFactor
        stand.contentView = content
        stand.order(.above, relativeTo: window.windowNumber)
        if let layer = content.layer { FloatingClose.play(on: layer, width: window.frame.width) }
        leaving.append(stand)
        DispatchQueue.main.asyncAfter(deadline: .now()+FloatingClose.duration) { [weak self] in
            stand.orderOut(nil); self?.leaving.removeAll { $0 === stand }
        }
    }
}
