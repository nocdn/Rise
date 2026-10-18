import AppKit

/// A page's own floating window (Meet's call, from Document Picture-in-Picture) is Chrome's, with
/// its title bar along the top. Two fingers on that bar move it just as they move Rise's floating
/// video: flicked, it springs to the nearest corner; let go slowly, it stays where it's left. It
/// grows a touch while they move it, with the floating video's spring; being Chrome's window, not a
/// picture, it grows by its frame, about its middle.
@MainActor final class FloatingPageGestures {
    static let shared = FloatingPageGestures()
    /// Chrome's picture-in-picture title bar (kTopControlsHeight).
    static let barHeight: CGFloat = 34
    let abandonedDragTimeout: CFTimeInterval = 1.5
    private var monitor: Any?, globalMonitor: Any?
    private weak var window: NSWindow?
    private var motion: FloatingVideoMotion?
    private var lift = FloatingLift()
    /// The window's own size, without the lift.
    private var size = NSSize.zero
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?, lastInput: CFTimeInterval?
    /// The system's momentum after a move belongs to the move, not to the page under the pointer.
    private var swallowsMomentum = false
    private var dragging: Bool { motion?.phase == .dragging }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.route(event) == true ? nil : event
        }
    }

    /// Whether `event` is the move's, taken from the page.
    private func route(_ event: NSEvent) -> Bool {
        let input = FloatingVideoScrollInput.from(event)
        if dragging { handle(input); return true }
        if swallowsMomentum {
            if !input.momentumPhase.isEmpty {
                if input.momentumPhase.contains(.ended) || input.momentumPhase.contains(.cancelled) { swallowsMomentum = false }
                return true
            }
            swallowsMomentum = false
        }
        guard input.precise, input.momentumPhase.isEmpty, input.phase.contains(.began),
              let window = event.window, Self.startsMove(at: event.locationInWindow, in: window) else { return false }
        begin(window, at: input.timestamp)
        handle(input)
        return true
    }

    /// Over the title bar of a page's floating window.
    static func startsMove(at point: NSPoint, in window: NSWindow) -> Bool {
        point.y >= window.frame.height-barHeight && isFloatingPage(window)
    }
    /// Chrome's picture-in-picture window holding a page, not its floating video, which has no page.
    static func isFloatingPage(_ window: NSWindow) -> Bool {
        guard let frameless = NSClassFromString("NativeWidgetMacFramelessNSWindow"), window.isKind(of: frameless),
              window.parent == nil, window.level.rawValue >= NSWindow.Level.floating.rawValue,
              let content = window.contentView else { return false }
        return holdsPage(content)
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
        // Caught while still lifted from the last move, it keeps the size it had before it.
        if self.window !== window || lift.isResting && !lift.lifted { size = window.frame.size }
        if self.window !== window { lift = FloatingLift() }
        self.window = window
        let frame = NSRect(x: window.frame.midX-size.width/2, y: window.frame.midY-size.height/2, width: size.width, height: size.height)
        var motion = FloatingVideoMotion(frame: frame, visibleFrame: placementArea(on: screen))
        motion.begin(at: timestamp)
        self.motion = motion; swallowsMomentum = false; lift.lift(true)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        startClock()
        // The window slides out from under the pointer, which may then be over another app.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { if self?.dragging == true { self?.handle(.from(event)) } }
        }
    }
    private func end(at timestamp: TimeInterval, cancelled: Bool) {
        motion?.end(at: timestamp, cancelled: cancelled, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastInput = nil; swallowsMomentum = !cancelled; lift.lift(false)
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
        guard let window, window.isVisible else { motion = nil; lift = FloatingLift(); stopClock(); return }
        let elapsed = lastFrameTime.map { link.timestamp-$0 } ?? 1.0/120
        lastFrameTime = link.timestamp
        // Resting fingers send nothing, so allow a pause before giving up.
        if dragging, let lastInput, CACurrentMediaTime()-lastInput > abandonedDragTimeout {
            end(at: ProcessInfo.processInfo.systemUptime, cancelled: true)
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion?.step(elapsed: elapsed, reduceMotion: reduced)
        lift.step(elapsed: elapsed)
        // The middle follows the move, and the lift grows the window about it.
        let base = motion?.frame ?? NSRect(x: window.frame.midX-size.width/2, y: window.frame.midY-size.height/2,
                                           width: size.width, height: size.height)
        let grown = NSSize(width: round(size.width*lift.value), height: round(size.height*lift.value))
        let frame = NSRect(x: base.midX-grown.width/2, y: base.midY-grown.height/2, width: grown.width, height: grown.height)
        if frame != window.frame { window.setFrame(frame, display: true) }
        if motion?.phase == .idle { motion = nil }
        if motion == nil && lift.isResting { stopClock() }
    }
}
