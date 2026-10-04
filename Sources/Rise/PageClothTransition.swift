import AppKit
import WebKit
import MetalKit

/// Deforms a snapshot of the inset web page, leaving native browser chrome and
/// the live WKWebView untouched. Cached history surfaces make the radial reveal
/// immediate; WebKit's real destination replaces the preview after first paint.
@MainActor final class PageClothTransition: NSObject, MTKViewDelegate {
    enum Phase { case idle, dragging, returning }
    private struct Preview {
        let item: WKBackForwardListItem
        let image: CGImage
        let size: CGSize
        let zoom: CGFloat
        let appearance: NSAppearance.Name
        var bytes: Int { image.bytesPerRow * image.height }
    }
    private let theme: () -> RiseTheme
    let renderer = ClothRenderer()
    private var previews: [Preview] = []
    private var snapshotGeneration = 0
    private weak var page: WKWebView?
    private var originalItem: WKBackForwardListItem?
    private var destinationItem: WKBackForwardListItem?
    private var preparedImage: CGImage?
    private var preparedZoom: CGFloat = 1
    private var preparedAppearance: NSAppearance.Name?
    private var view: ClothMetalView?
    private var backdrop: ClothBackdrop?
    private var timer: Timer?
    private var motion = ClothMotion()
    private var distance = 0.0
    private var direction = HistoryDirection.back
    private var committed = false, destinationPresented = false
    private(set) var phase = Phase.idle
    private(set) var uniforms = ClothUniforms()
    private(set) var submittedFrames = 0
    var isActive: Bool { view != nil }
    var hasPreparedSnapshot: Bool { preparedImage != nil }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var updateFrame: ((WKWebView, Double, Bool) -> Void)?
    var resetFrame: (() -> Void)?

    init(theme: @escaping () -> RiseTheme) { self.theme = theme }

    func remember(_ web: WKWebView) {
        guard renderer != nil, web.window != nil, let item = web.backForwardList.currentItem,
              web.bounds.width > 0, web.bounds.height > 0 else { return }
        let size = web.bounds.size, zoom = web.pageZoom, appearance = web.effectiveAppearance.name
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { [weak self, weak web] image, _ in
            guard let self, let web, web.backForwardList.currentItem === item,
                  web.bounds.size == size, web.pageZoom == zoom, web.effectiveAppearance.name == appearance,
                  let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.store(cg, item: item, size: size, zoom: zoom, appearance: appearance)
        }
    }
    private func store(_ image: CGImage, item: WKBackForwardListItem, size: CGSize, zoom: CGFloat, appearance: NSAppearance.Name) {
        previews.removeAll { $0.item === item }
        previews.append(Preview(item: item, image: image, size: size, zoom: zoom, appearance: appearance))
        // Keep a bounded history-image cache, not an extra live WebKit page.
        while previews.count > 8 || previews.reduce(0, { $0 + $1.bytes }) > 64*1024*1024 {
            previews.removeFirst()
        }
    }
    private func preview(_ item: WKBackForwardListItem?, in web: WKWebView) -> CGImage? {
        guard let item else { return nil }
        return previews.last {
            $0.item === item && $0.size == web.bounds.size && $0.zoom == web.pageZoom && $0.appearance == web.effectiveAppearance.name
        }?.image
    }

    func prepare(_ web: WKWebView) {
        cancel()
        guard renderer != nil, !reduceMotion(), web.bounds.width > 0, web.bounds.height > 0 else { return }
        page = web; originalItem = web.backForwardList.currentItem
        preparedZoom = web.pageZoom; preparedAppearance = web.effectiveAppearance.name
        preparedImage = preview(originalItem, in: web)
        let token = snapshotGeneration, size = web.bounds.size, item = originalItem
        let zoom = web.pageZoom, appearance = web.effectiveAppearance.name
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = false
        web.takeSnapshot(with: config) { [weak self, weak web] image, _ in
            guard let self, let web, self.snapshotGeneration == token,
                  web.backForwardList.currentItem === item, web.bounds.size == size,
                  web.pageZoom == zoom, web.effectiveAppearance.name == appearance,
                  let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            if let item { self.store(cg, item: item, size: size, zoom: zoom, appearance: appearance) }
            // A quick finger-up can precede the outgoing snapshot. Let that
            // snapshot join the still-running ripple while its original page
            // is current, rather than silently dropping the entire effect.
            if self.phase == .returning {
                guard self.view == nil, self.motion.elapsed(at: ProcessInfo.processInfo.systemUptime) < ClothMotion.rippleDuration else { return }
            }
            self.preparedImage = cg
            if self.phase == .dragging || self.phase == .returning {
                try? self.renderer?.setOutgoing(cg)
                self.installSurfaceIfNeeded(); self.renderFrame()
            }
        }
    }
    func drag(_ web: WKWebView, direction: HistoryDirection, distance: Double) {
        guard !reduceMotion(), renderer != nil else { return }
        if page !== web || phase == .returning { prepare(web) }
        self.direction = direction; self.distance = distance
        if phase != .dragging {
            phase = .dragging
            destinationItem = direction == .back ? web.backForwardList.backItem : web.backForwardList.forwardItem
            do {
                if let preparedImage { try renderer?.setOutgoing(preparedImage) }
                try renderer?.setIncoming(preview(destinationItem, in: web))
            } catch { cancel(); return }
        }
        installSurfaceIfNeeded(); renderFrame()
    }
    func release(distance: Double, committed: Bool, cancelled: Bool) {
        guard phase == .dragging else { return }
        self.distance = distance; self.committed = committed
        phase = .returning
        motion.release(distance: distance, at: ProcessInfo.processInfo.systemUptime, cancelled: cancelled)
        // First ripple frame is submitted synchronously on finger-up, alongside
        // the spring and before goBack/goForward begins loading the destination.
        renderFrame()
        ensureTimer()
    }
    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.renderFrame()
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func destinationDidCommit(_ web: WKWebView) {
        guard page === web, phase == .returning, committed,
              web.backForwardList.currentItem !== originalItem else { return }
        let token = snapshotGeneration, item = web.backForwardList.currentItem
        let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { [weak self, weak web] image, _ in
            guard let self, let web, self.snapshotGeneration == token, self.phase == .returning,
                  web.backForwardList.currentItem === item,
                  let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.destinationPresented = true
            // Preserve the cached destination for the short reveal. A snapshot
            // taken on didCommit may precede its stylesheet/images arriving.
            if self.renderer?.incoming == nil { try? self.renderer?.setIncoming(cg) }
            self.renderFrame()
        }
    }
    private func installSurfaceIfNeeded() {
        guard view == nil, let renderer, renderer.outgoing != nil, let page, let host = page.superview else { return }
        let backdrop = ClothBackdrop(color: theme().background)
        backdrop.gradientColors = theme().backgroundGradient; backdrop.frame = page.frame
        let view = ClothMetalView(renderer: renderer); view.frame = page.frame; view.delegate = self
        view.corner = page.superview?.layer?.cornerRadius ?? 7
        view.continuous = page.superview?.layer?.cornerCurve == .continuous
        host.addSubview(backdrop, positioned: .above, relativeTo: page)
        host.addSubview(view, positioned: .above, relativeTo: backdrop)
        self.backdrop = backdrop; self.view = view
        ensureTimer()
    }
    private func renderFrame() {
        guard let page, page.superview != nil, !reduceMotion(), page.pageZoom == preparedZoom,
              page.effectiveAppearance.name == preparedAppearance else { cancel(); return }
        if let view, view.frame != page.frame { cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let pull = phase == .dragging ? ClothMotion.pull(distance: distance) : motion.pull(at: now)
        let elapsed = phase == .returning ? motion.elapsed(at: now) : -1
        uniforms = ClothUniforms(size: SIMD2(Float(page.bounds.width), Float(page.bounds.height)),
            pull: Float(pull), elapsed: Float(elapsed),
            strength: phase == .returning && motion.ripples ? Float(motion.strength) : 0,
            originFraction: Float(motion.originFraction), forward: direction == .forward ? 1 : 0,
            reveal: committed && renderer?.incoming != nil ? 1 : 0)
        if view != nil { updateFrame?(page, pull, direction == .forward) }
        view?.setOutline(pull: pull, forward: direction == .forward); view?.draw()
        if phase == .returning, elapsed >= ClothMotion.settlingDuration {
            // A cached preview can cover the first paint, but never remain stuck
            // when a site takes too long or navigation fails.
            if !committed || destinationPresented || !page.isLoading || renderer?.incoming == nil || elapsed >= 2 { cancel() }
        }
    }
    func cancel() {
        snapshotGeneration += 1
        timer?.invalidate(); timer = nil
        view?.delegate = nil; view?.removeFromSuperview(); view = nil
        backdrop?.removeFromSuperview(); backdrop = nil
        resetFrame?()
        page = nil; originalItem = nil; destinationItem = nil; preparedImage = nil
        phase = .idle; distance = 0; committed = false; destinationPresented = false
        motion = ClothMotion(); uniforms = ClothUniforms(); renderer?.clear()
    }
    func cancel(for web: WKWebView) { if page === web { cancel() } }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    func draw(in view: MTKView) {
        guard let renderer, let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let command = renderer.queue.makeCommandBuffer() else { return }
        guard renderer.encode(descriptor, uniforms: uniforms, into: command) else { return }
        submittedFrames += 1
        command.present(drawable); command.commit()
    }
}
