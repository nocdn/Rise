import AppKit
import os
import WebKit

/// Snap's finger-phase adapter. System momentum is consumed, since the copied
/// spring runs its own flick after the finger phase ends.
struct FloatingVideoScrollInput {
    var phase: NSEvent.Phase
    var momentumPhase: NSEvent.Phase = []
    var translation: CGVector = .zero
    var timestamp: TimeInterval
    var precise = true

    static func from(_ event: NSEvent) -> Self {
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        return Self(phase: event.phase, momentumPhase: event.momentumPhase,
                    translation: CGVector(dx: -event.scrollingDeltaX*direction, dy: event.scrollingDeltaY*direction),
                    timestamp: event.timestamp, precise: event.hasPreciseScrollingDeltas)
    }
}

@MainActor final class FloatingVideoWindow: NSPanel {
    let videoHost = FlippedView()
    let overlay = FloatingVideoOverlay()
    /// The last picture, shown while the page itself is back in its tab.
    private let frozenFrame = NSImageView()
    var showsFrozenFrame: Bool { !frozenFrame.isHidden }
    /// A two-finger drag whose lift-off never arrives ends after this long
    /// without input, instead of running its display link indefinitely.
    var abandonedDragTimeout: CFTimeInterval = 1.5
    private var lastTrackpadInput: CFTimeInterval?
    var isDragging: Bool { motion.phase == .dragging }
    nonisolated static let shadowInset: CGFloat = 48
    private let surface = NSView()
    private weak var referenceWindow: NSWindow?
    private var resizeMotion: FloatingVideoResizeMotion?
    /// The source page's viewport. Its canvas cannot grow beyond it.
    private var sourceViewport: NSSize?
    var videoFrame: NSRect { frame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset) }
    private(set) var hasVideoFrame = false
    private(set) var videoFrameIntervals: [TimeInterval] = []
    var onVideoSizeChange: ((NSSize, CGFloat) -> Void)?
    private(set) var renderedFrameCount = 0
    var onClose: (() -> Void)?
    var onReturn: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onSeek: ((Double, Bool) -> Void)?
    private var localPinchMonitor: Any?
    private var globalPinchMonitor: Any?
    private var spaceMonitor: Any?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    /// Whether the video takes clicks at all. Even then, the transparent
    /// margin around it that holds the shadow passes them to the windows beneath.
    private var acceptsMouse = false { didSet { updateMousePassThrough() } }
    private var motion: FloatingVideoMotion
    private var displayLink: CADisplayLink?
    private var lastFrameTime: TimeInterval?
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var mouseLocation: NSPoint?
    private var screenObserver: NSObjectProtocol?
    private(set) var isDismissing = false
    private var dismissalID = UUID()

    init(aspectRatio: CGFloat, screen: NSScreen, referenceWindow: NSWindow? = nil) {
        let aspect = min(3, max(0.45, aspectRatio))
        self.referenceWindow = referenceWindow
        let available = FloatingVideoMotion.placementArea(visibleFrame: screen.visibleFrame, browserFrame: referenceWindow?.frame)
        var size = NSSize(width: min(360, available.width*0.30), height: 0)
        size.height = size.width/aspect
        if size.height > available.height*0.4 { size.height = available.height*0.4; size.width = size.height*aspect }
        let shadowInset = Self.shadowInset
        size.width += shadowInset*2; size.height += shadowInset*2
        let limits = FloatingVideoMotion.originBounds(size: size, visibleFrame: available, contentInset: shadowInset)
        // Opens in the bottom-right corner.
        let frame = NSRect(origin: NSPoint(x: limits.maxX, y: limits.minY), size: size)
        motion = FloatingVideoMotion(frame: frame, visibleFrame: available, contentInset: shadowInset)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "YouTube Picture in Picture"
        isReleasedWhenClosed = false; isFloatingPanel = true; hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true; isExcludedFromWindowsMenu = false
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        animationBehavior = .utilityWindow; ignoresMouseEvents = true
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true; content.layerUsesCoreImageFilters = true
        contentView = content
        surface.frame = content.bounds.insetBy(dx: shadowInset, dy: shadowInset)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 16; surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true; surface.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.shadowColor = NSColor.black.cgColor
        content.layer?.shadowOpacity = 0.20; content.layer?.shadowRadius = 12
        content.layer?.shadowOffset = CGSize(width: 0, height: -3)
        content.layer?.shadowPath = CGPath(roundedRect: surface.frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
        content.addSubview(surface)
        videoHost.setAccessibilityHidden(true)
        // Shows only the page's canvas. While a resize waits for the canvas,
        // the surface's black shows instead of the page around it.
        videoHost.clipsToBounds = true
        videoHost.frame = surface.bounds
        overlay.frame = surface.bounds
        frozenFrame.imageScaling = .scaleAxesIndependently; frozenFrame.isHidden = true
        frozenFrame.setAccessibilityElement(false)
        surface.addSubview(videoHost); surface.addSubview(frozenFrame); surface.addSubview(overlay)
        overlay.closeAction = { [weak self] in self?.onClose?() }
        overlay.returnAction = { [weak self] in self?.onReturn?() }
        overlay.togglePlayback = { [weak self] in self?.onTogglePlayback?() }
        overlay.minimizeAction = { [weak self] in self?.onMinimize?() }
        overlay.seek = { [weak self] fraction, final in self?.onSeek?(fraction, final) }
        overlay.mouseDrag = { [weak self] event in self?.handleMouse(event) }
        overlay.pinch = { [weak self] event in self?.handleMagnification(event.magnification, phase: event.phase) }
        observeScreenChanges()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The invisible shadow margin may extend beyond the screen. Motion
        // and resizing constrain the visible video, rather than this margin.
        frameRect
    }

    private func placementArea(on screen: NSScreen) -> NSRect {
        FloatingVideoMotion.placementArea(visibleFrame: screen.visibleFrame, browserFrame: referenceWindow?.frame)
    }
    private func resizing(on screen: NSScreen) -> FloatingVideoResizeMotion {
        FloatingVideoResizeMotion(videoFrame: videoFrame, visibleFrame: placementArea(on: screen), maximumSize: sourceViewport)
    }

    private func applyVideoFrame(_ videoFrame: NSRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let outer = videoFrame.insetBy(dx: -Self.shadowInset, dy: -Self.shadowInset)
        // AppKit rounds window frames. Align once instead of letting floating
        // point noise make a settled size oscillate by a point.
        let aligned = NSRect(x: outer.minX.rounded(), y: outer.minY.rounded(),
                             width: outer.width.rounded(), height: outer.height.rounded())
        setFrame(aligned, display: true)
        if let content = contentView {
            surface.frame = content.bounds.insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
            // Stretches the page's last picture to the new size until it redraws.
            videoHost.frame = surface.bounds; videoHost.bounds = NSRect(origin: canvasOrigin, size: canvasSize ?? surface.bounds.size)
            overlay.frame = surface.bounds
            overlay.needsLayout = true; overlay.layoutSubtreeIfNeeded()
            content.layer?.shadowPath = CGPath(roundedRect: surface.frame, cornerWidth: 16, cornerHeight: 16, transform: nil)
        }
        CATransaction.commit()
        // Redrawing at every step of a pinch would show each new size before
        // the page paints it, so the picture stretches until the size settles.
        if resizeMotion.map({ $0.phase == .idle }) ?? true { onVideoSizeChange?(surface.bounds.size, backingScaleFactor) }
    }

    func attach(_ webView: WKWebView) {
        let viewport = webView.frame.size
        webView.removeFromSuperview()
        // Keep the original player alive and its viewport stable. Its decoded
        // frames are drawn into its local canvas; remote video layers can go
        // black when reparented between NSWindows.
        videoHost.bounds = NSRect(origin: .zero, size: videoHost.frame.size)
        webView.frame = NSRect(origin: .zero, size: viewport); webView.autoresizingMask = []
        videoHost.addSubview(webView); sourceViewport = viewport
    }

    /// The size the page's canvas draws the picture at, in the page's points.
    /// The video host scales it to fill the window.
    private(set) var canvasSize: NSSize?
    /// Where in the page the picture is drawn, in the page's points.
    private(set) var canvasOrigin = NSPoint.zero
    /// The page painted the picture at this size and place, so the video host shows it.
    func didResizeVideo(to size: NSSize, at origin: NSPoint = .zero) {
        canvasSize = size; canvasOrigin = origin
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoHost.frame = surface.bounds; videoHost.bounds = NSRect(origin: origin, size: size)
        CATransaction.commit()
    }

    func freeze(_ image: NSImage) {
        frozenFrame.frame = videoHost.frame; frozenFrame.image = image; frozenFrame.isHidden = false
    }
    func clearFrozenFrame() {
        guard !frozenFrame.isHidden else { return }
        frozenFrame.isHidden = true; frozenFrame.image = nil
    }

    /// Keeps WebKit in a live window while the first decoded frame arrives,
    /// without taking clicks over the nearly transparent panel.
    func showForFirstFrame() {
        alphaValue = 0.01; acceptsMouse = false; orderFrontRegardless()
    }

    func didRenderVideo(frames: Int, interval: Double) {
        if frames < renderedFrameCount { videoFrameIntervals.removeAll(keepingCapacity: true) }
        if frames > renderedFrameCount && interval > 0 && interval.isFinite {
            videoFrameIntervals.append(interval/1000)
            if videoFrameIntervals.count > 180 { videoFrameIntervals.removeFirst(videoFrameIntervals.count-180) }
        }
        hasVideoFrame = true; renderedFrameCount = frames
    }

    func showPlayback(paused: Bool) { overlay.playButton.setPaused(paused, animated: true) }
    func showProgress(time: Double, duration: Double) { overlay.progress.show(time: time, duration: duration) }

    func present() {
        installEventMonitors()
        observeScreenChanges(); orderFrontRegardless()
        fitToScreen(); acceptsMouse = true; overlay.refreshHover()
        NSApp.addWindowsItem(self, title: title, filename: false)
        // A window that isn't showing yet grows in; one called back mid-dismissal springs back to full size.
        if alphaValue < 0.05 { springIn() } else { scale(to: 1) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            animator().alphaValue = 1
        }
    }

    /// The window grows from slightly smaller with a light bounce, while a
    /// quick blur clears to sharp.
    private func springIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = contentView?.layer else { return }
        scale(to: 1, from: 0.9)

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.name = "springInBlur"; blur.setValue(0, forKey: kCIInputRadiusKey)
        let unblur = CABasicAnimation(keyPath: "filters.springInBlur.inputRadius")
        unblur.fromValue = 1*backingScaleFactor; unblur.toValue = 0
        unblur.duration = 0.16; unblur.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in
            // A resting zero-radius blur still costs a filter pass every frame.
            MainActor.assumeIsolated { if layer?.animation(forKey: "springInBlur") == nil { layer?.filters = nil } }
        }
        layer.filters = [blur]; layer.add(unblur, forKey: "springInBlur")
        CATransaction.commit()
    }

    /// Scales the window about its center: springing up to full size with a
    /// light bounce, or quickly down as it leaves.
    private func scale(to scale: CGFloat, from start: CGFloat? = nil) {
        guard let layer = contentView?.layer else { return }
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        func scaled(_ scale: CGFloat) -> CATransform3D {
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            return CATransform3DTranslate(transform, -center.x, -center.y, 0)
        }
        let current = start.map(scaled) ?? layer.presentation()?.transform ?? layer.transform
        let target = scale == 1 ? CATransform3DIdentity : scaled(scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "scale"); layer.transform = target
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !CATransform3DEqualToTransform(current, target) else { return }
        let animation: CABasicAnimation
        if scale == 1 {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1; spring.stiffness = 420; spring.damping = 2*0.62*sqrt(420)
            spring.duration = spring.settlingDuration; animation = spring
        } else {
            animation = CABasicAnimation(keyPath: "transform")
            animation.duration = 0.18; animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        }
        animation.fromValue = current; animation.toValue = target
        layer.add(animation, forKey: "scale")
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true; stopMotion(); acceptsMouse = false; removeEventMonitors()
        let token = UUID(); dismissalID = token
        // Shrinks a touch as it fades.
        if animated { scale(to: 0.95) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dismissalID == token else { return }
                self.orderOut(nil); NSApp.removeWindowsItem(self)
                if let observer = self.screenObserver { NotificationCenter.default.removeObserver(observer); self.screenObserver = nil }
                completion()
            }
        }
    }

    func closeImmediately() {
        dismissalID = UUID(); isDismissing = true; stopMotion(); acceptsMouse = false; removeEventMonitors()
        orderOut(nil); NSApp.removeWindowsItem(self)
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer); screenObserver = nil }
    }

    func cancelDismissal() {
        dismissalID = UUID(); isDismissing = false
        present()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .magnify {
            handleMagnification(event.magnification, phase: event.phase); return
        }
        if event.type == .endGesture, resizeMotion?.phase == .pinching {
            handleMagnification(0, phase: .ended); return
        }
        if event.type == .scrollWheel, event.hasPreciseScrollingDeltas { handleScroll(event); return }
        super.sendEvent(event)
    }

    /// AppKit sends a pinch to the key window, which this panel never is, so
    /// one that begins over the video is taken wherever it is delivered. With
    /// Rise in the background, the global monitor sees it (without consuming it).
    private func installEventMonitors() {
        guard localPinchMonitor == nil else { return }
        localPinchMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.pinchTypes) { [weak self] event in
            // Not `self?.routePinch(event) ?? event`: that turns "handled" (nil) back into the event.
            guard let self else { return event }
            return self.routePinch(event)
        }
        // A trackpad pinch travels as a raw gesture event (type 29) that only
        // the receiving app turns into magnify, so a global monitor for magnify
        // alone never fires; watching raw gestures catches it.
        globalPinchMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.pinchTypes.union(.gesture)) { [weak self] event in
            MainActor.assumeIsolated {
                let event = event.type == .gesture ? event.cgEvent.flatMap(NSEvent.init(cgEvent:)) ?? event : event
                _ = self?.routePinch(event)
            }
        }
        // The panel never takes keyboard focus, so Space reaches Rise's key window.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.routeSpace(event)
        }
        // The panel ignores the mouse outside the video, so it never sees the
        // pointer come back over it; watch the pointer everywhere instead.
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.pointerTypes) { [weak self] event in
            self?.updateMousePassThrough(); return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.pointerTypes) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        }
    }
    private static let pointerTypes: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]

    /// Takes the mouse only over the video's rounded shape, so the shadow
    /// margin never blocks clicks or hover in the windows beneath it. A press
    /// keeps the current state until it is released, so a scrub or a drag that
    /// strays into the margin continues; so does a pinch or a two-finger drag,
    /// whose gesture would otherwise reach the page beneath.
    func updateMousePassThrough() {
        if acceptsMouse, resizeMotion?.phase == .pinching || motion.phase == .dragging { return }
        let pointer = pointerLocation()
        let over = acceptsMouse && NSBezierPath(roundedRect: videoFrame, xRadius: 16, yRadius: 16).contains(pointer)
        guard over == ignoresMouseEvents, !acceptsMouse || NSEvent.pressedMouseButtons == 0 else { return }
        ignoresMouseEvents = !over
        // Tracking areas miss the crossing that happened while the panel ignored the mouse.
        overlay.refreshHover()
    }
    /// A pinch arrives as magnify events, bracketed by the gesture's begin and end.
    private static let pinchTypes: NSEvent.EventTypeMask = [.magnify, .beginGesture, .endGesture]

    private func removeEventMonitors() {
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor); self.localPointerMonitor = nil }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor); self.globalPointerMonitor = nil }
        if let localPinchMonitor { NSEvent.removeMonitor(localPinchMonitor); self.localPinchMonitor = nil }
        if let globalPinchMonitor { NSEvent.removeMonitor(globalPinchMonitor); self.globalPinchMonitor = nil }
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor); self.spaceMonitor = nil }
    }
    /// Returns nil when the pinch resized this window.
    func routePinch(_ event: NSEvent) -> NSEvent? {
        // A pinch whose last magnify went elsewhere still ends with the gesture.
        if event.type == .endGesture, resizeMotion?.phase == .pinching, !isDismissing {
            handleMagnification(0, phase: .ended); return event
        }
        // Even one addressed to this panel goes to the key window, so take it here.
        guard event.type == .magnify, !isDismissing, isVisible, acceptsMouse else { return event }
        if resizeMotion?.phase != .pinching {
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
            guard event.phase.contains(.began) || event.phase.contains(.changed),
                  videoFrame.contains(point) || videoFrame.contains(NSEvent.mouseLocation) else { return event }
        }
        handleMagnification(event.magnification, phase: event.phase)
        return nil
    }

    /// Space plays or pauses while the pointer is over the video, and never
    /// reaches the page behind it. Returns nil when it was handled.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    func routeSpace(_ event: NSEvent) -> NSEvent? { routeSpace(event, pointer: pointerLocation()) }
    func routeSpace(_ event: NSEvent, pointer: NSPoint) -> NSEvent? {
        guard event.type == .keyDown || event.type == .keyUp, event.keyCode == 49,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        let over = videoFrame.contains(pointer) || overlay.controlsVisible
        guard over, !isDismissing, isVisible else {
            // Only near the video, so ordinary Space presses elsewhere stay quiet.
            if event.type == .keyDown, videoFrame.insetBy(dx: -24, dy: -24).contains(pointer) {
                Self.log.notice("Space reached the page beside Picture in Picture: pointer=\(pointer.debugDescription) video=\(self.videoFrame.debugDescription) dismissing=\(self.isDismissing) visible=\(self.isVisible)")
            }
            return event
        }
        if event.type == .keyDown, !event.isARepeat { overlay.toggle() }
        return nil
    }
    private static let log = Logger(subsystem: "Rise", category: "PictureInPicture")

    func handleScroll(_ event: NSEvent) {
        handleGesture(.from(event))
    }

    func handleGesture(_ input: FloatingVideoScrollInput) {
        guard !isDismissing, input.precise, resizeMotion?.phase != .pinching else { return }
        let phase = input.phase
        if input.momentumPhase.isEmpty,
           phase.contains(.began) || phase.contains(.changed) && motion.phase != .dragging {
            beginDrag(at: input.timestamp)
        }
        if motion.phase == .dragging, input.momentumPhase.isEmpty,
           phase.contains(.began) || phase.contains(.changed) {
            motion.drag(by: input.translation, at: input.timestamp)
            lastTrackpadInput = CACurrentMediaTime()
        }
        if motion.phase == .dragging, phase.contains(.ended) || phase.contains(.cancelled) {
            endDrag(at: input.timestamp, cancelled: phase.contains(.cancelled))
        }
    }

    func handleMagnification(_ magnification: CGFloat, phase: NSEvent.Phase) {
        guard !isDismissing, magnification.isFinite else { return }
        if phase.contains(.began) || (phase.contains(.changed) || phase.isEmpty) && resizeMotion?.phase != .pinching {
            guard let screen = screen ?? NSScreen.main else { return }
            stopMotion()
            resizeMotion = resizing(on: screen)
            resizeMotion?.begin()
        }
        guard var resize = resizeMotion else { return }
        if phase.contains(.began) || phase.contains(.changed) || phase.isEmpty { resize.magnify(by: magnification) }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            resize.end(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        resizeMotion = resize; applyVideoFrame(resize.videoFrame)
        if let screen = screen ?? NSScreen.main {
            motion = FloatingVideoMotion(frame: frame, visibleFrame: placementArea(on: screen), contentInset: Self.shadowInset)
        }
        if resize.phase == .settling { startClock() } else if resize.phase == .idle { updateMousePassThrough() }
    }

    private func handleMouse(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown: mouseLocation = location; beginDrag(at: event.timestamp); lastTrackpadInput = nil
        case .leftMouseDragged:
            if let previous = mouseLocation { motion.drag(by: CGVector(dx: location.x-previous.x, dy: location.y-previous.y), at: event.timestamp) }
            mouseLocation = location
        case .leftMouseUp: mouseLocation = nil; endDrag(at: event.timestamp, cancelled: false)
        default: break
        }
    }

    private func beginDrag(at timestamp: TimeInterval) {
        guard !isDismissing else { return }
        guard let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if var resize = resizeMotion { resize.finish(); resizeMotion = nil; applyVideoFrame(resize.videoFrame) }
        motion = FloatingVideoMotion(frame: frame, visibleFrame: placementArea(on: screen), contentInset: Self.shadowInset)
        motion.begin(at: timestamp)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        startClock()
        // A moving window can leave the pointer during a two-finger gesture.
        // Continue receiving that gesture until its finger phase ends.
        if localScrollMonitor == nil {
            localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.motion.phase == .dragging else { return event }
                self.handleScroll(event); return nil
            }
            globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { if self?.motion.phase == .dragging { self?.handleScroll(event) } }
            }
        }
    }

    private func endDrag(at timestamp: TimeInterval, cancelled: Bool) {
        motion.end(at: timestamp, cancelled: cancelled, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastTrackpadInput = nil; stopScrollCapture(); startClock()
    }

    private func startClock() {
        guard displayLink == nil, let screen = screen ?? NSScreen.main else { return }
        // A view-bound link can stop when WebKit changes occlusion while the
        // player migrates. The screen clock keeps the floating window moving.
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common); displayLink = link; lastFrameTime = nil
    }
    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = lastFrameTime.map { link.timestamp-$0 } ?? 1.0/120
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lastFrameTime = link.timestamp
        // Resting fingers send nothing, so allow a pause before giving up.
        if motion.phase == .dragging, let last = lastTrackpadInput, CACurrentMediaTime()-last > abandonedDragTimeout {
            endDrag(at: ProcessInfo.processInfo.systemUptime, cancelled: true)
        }
        if var resize = resizeMotion, resize.phase == .settling {
            resize.step(elapsed: elapsed, reduceMotion: reduced)
            resizeMotion = resize; applyVideoFrame(resize.videoFrame)
            if let screen = screen ?? NSScreen.main {
                motion = FloatingVideoMotion(frame: frame, visibleFrame: placementArea(on: screen), contentInset: Self.shadowInset)
            }
        } else {
            motion.step(elapsed: elapsed, reduceMotion: reduced)
            setFrameOrigin(motion.frame.origin)
        }
        if motion.phase == .idle && resizeMotion?.phase != .settling {
            displayLink?.invalidate(); displayLink = nil; lastFrameTime = nil
            updateMousePassThrough(); overlay.refreshHover()
        }
    }
    private func stopScrollCapture() {
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor); self.localScrollMonitor = nil }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor); self.globalScrollMonitor = nil }
    }
    private func stopMotion() { stopScrollCapture(); displayLink?.invalidate(); displayLink = nil; lastFrameTime = nil }
    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
    }
    private func fitToScreen() {
        guard !isDismissing, let screen = screen ?? NSScreen.main else { return }
        stopMotion()
        var resize = resizing(on: screen)
        resize.finish(); resizeMotion = nil; applyVideoFrame(resize.videoFrame)
        motion = FloatingVideoMotion(frame: frame, visibleFrame: placementArea(on: screen), contentInset: Self.shadowInset)
    }
}
