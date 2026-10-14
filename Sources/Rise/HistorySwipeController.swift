import AppKit
import WebKit

/// Routes precise trackpad events only over visible pages. WebKit's large native
/// history slide is disabled; ordinary wheel/vertical/page horizontal scrolling
/// still goes to WebKit. A short isolated DOM probe protects carousels/editors, and,
/// as in Safari, pages that take the wheel themselves, like a drawing canvas that pans:
/// a gesture's first events reach the page at once, and only swipe if it lets them be.
@MainActor final class HistorySwipeController {
    static let world = WKContentWorld.world(name: "Rise.HistorySwipe")
    private weak var window: BrowserWindow?
    private let pageAt: (NSEvent) -> WKWebView?
    private let feedback: (HistoryDirection?, Double, Bool, Bool?) -> Void
    var prepareCloth: ((WKWebView) -> Void)?
    var dragCloth: ((WKWebView, HistoryDirection, Double) -> Void)?
    var releaseCloth: ((Double, Bool, Bool) -> Void)?
    var cancelCloth: (() -> Void)?
    var isPeekPage: ((WKWebView) -> Bool)?
    /// Whether a page can go that way, which can include pages the browser holds beyond its own history.
    var canNavigate: (WKWebView, HistoryDirection) -> Bool = { page, direction in direction == .back ? page.canGoBack : page.canGoForward }
    var navigate: (WKWebView, HistoryDirection) -> Void = { page, direction in if direction == .back { page.goBack() } else { page.goForward() } }
    var dragPeek: ((Double) -> Void)?
    var releasePeek: ((Bool) -> Void)?
    var cancelPeek: (() -> Void)?
    private var peekGesture = false
    var thresholdClick: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    private weak var page: WKWebView?
    private(set) var gesture = HistorySwipeState()
    private var pending: [NSEvent] = []
    private var probing = false, permitted = false, suppressMomentum = false
    var isActive: Bool { probing || gesture.isTracking }
    private var clothPrepared = false
    private var generation = 0
    private var probeTimeout: DispatchWorkItem?
    init(window: BrowserWindow, pageAt: @escaping (NSEvent) -> WKWebView?,
         feedback: @escaping (HistoryDirection?, Double, Bool, Bool?) -> Void) {
        self.window = window; self.pageAt = pageAt; self.feedback = feedback
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel else { return false }
        let terminal = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        guard event.hasPreciseScrollingDeltas || terminal || !event.momentumPhase.isEmpty else { return false }
        if !event.momentumPhase.isEmpty {
            if probing { hold(event); return true }
            return handleMomentum(event)
        }
        if event.phase.contains(.began) {
            cancel()
            guard let page = pageAt(event) else { return false }
            peekGesture = isPeekPage?(page) == true
            guard peekGesture || canNavigate(page, .back) || canNavigate(page, .forward) else { return false }
            self.page = page; probing = true; pending = []
            if !peekGesture, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 {
                prepareCloth?(page); clothPrepared = true
            }
            hold(event)
            probe(page, at: event)
            return true
        }
        if probing { hold(event); return true }
        return permitted ? route(event) : false
    }
    /// While the probe decides, the page already gets the event, so it scrolls without
    /// waiting and can show whether it takes the wheel; a swipe replays it afterwards.
    private func hold(_ event: NSEvent) {
        pending.append(event); window?.deliverPageScroll(event)
    }
    private func probe(_ page: WKWebView, at event: NSEvent) {
        let token = generation
        let point = page.convert(event.locationInWindow, from: nil)
        let timeout = DispatchWorkItem { [weak self] in self?.resolveProbe(false, token: token) }
        probeTimeout = timeout
        // A busy web process doesn't swipe; scrolling never waits for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: timeout)
        Task { [weak self, weak page] in
            guard let page else { self?.resolveProbe(false, token: token); return }
            let result = try? await page.callAsyncJavaScript(Self.scrollProbe,
                arguments: ["x": point.x, "y": point.y, "width": max(1, page.bounds.width), "height": max(1, page.bounds.height)],
                in: nil, contentWorld: Self.world)
            self?.resolveProbe(result as? Bool ?? false, token: token)
        }
    }
    private func resolveProbe(_ allows: Bool, token: Int) {
        guard generation == token, probing else { return }
        probing = false; permitted = allows; probeTimeout?.cancel(); probeTimeout = nil
        let events = pending; pending.removeAll()
        // The page has had these already; a swipe takes over their travel.
        if allows { gesture.begin(); events.forEach { _ = handleResolved($0) } }
        else { cancelCloth?(); clothPrepared = false }
    }
    private func handleResolved(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            return handleMomentum(event)
        }
        return permitted ? route(event) : false
    }
    private func handleMomentum(_ event: NSEvent) -> Bool {
        // Some drivers omit finger-up and momentum-began. Any momentum event
        // ends the finger gesture once; its deltas never add navigation travel.
        if permitted, gesture.isTracking { _ = finish(cancelled: event.momentumPhase.contains(.cancelled)) }
        let consumed = suppressMomentum
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { suppressMomentum = false }
        return consumed
    }
    private func route(_ event: NSEvent) -> Bool {
        guard let page else { cancel(); return false }
        if event.phase.contains(.cancelled) || event.phase.contains(.ended) {
            return finish(cancelled: event.phase.contains(.cancelled))
        }
        guard event.phase.contains(.began) || event.phase.contains(.changed), gesture.isTracking else { return false }
        // Undo the user's scroll preference: physical right = back, left = forward.
        let dx = event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
        if gesture.move(dx: Double(dx), dy: Double(event.scrollingDeltaY),
                        canBack: peekGesture || canNavigate(page, .back), canForward: canNavigate(page, .forward)) { thresholdClick() }
        if gesture.consumesScroll {
            feedback(gesture.direction, gesture.arrowPull, gesture.isArmed, nil)
            if let direction = gesture.direction {
                if peekGesture, direction == .back { dragPeek?(gesture.arrowPull) }
                else {
                    if !clothPrepared { prepareCloth?(page); clothPrepared = true }
                    dragCloth?(page, direction, gesture.distance)
                }
            }
        }
        return gesture.consumesScroll
    }
    private func finish(cancelled: Bool) -> Bool {
        let consumed = gesture.consumesScroll, direction = gesture.direction, distance = gesture.distance
        let page = self.page, committed = gesture.finish(cancelled: cancelled)
        let dismissesPeek = peekGesture && direction == .back
        suppressMomentum = consumed; permitted = false; self.page = nil; peekGesture = false
        feedback(direction, 0, false, committed != nil)
        if dismissesPeek { releasePeek?(committed != nil) }
        else if consumed { releaseCloth?(distance, committed != nil, cancelled) }
        else { cancelCloth?() }
        if !dismissesPeek, let committed, let page {
            navigate(page, committed)
        }
        return consumed
    }
    func cancel(for page: WKWebView) { if self.page === page { cancel() } }
    func cancel() {
        generation += 1; probeTimeout?.cancel(); probeTimeout = nil
        pending.removeAll(); probing = false; permitted = false; suppressMomentum = false
        clothPrepared = false
        let direction = gesture.direction, returnsPeek = peekGesture && direction == .back
        _ = gesture.finish(cancelled: true); page = nil; peekGesture = false
        if returnsPeek { cancelPeek?() }
        cancelCloth?()
        if let direction { feedback(direction, 0, false, false) }
    }
    /// Notes when the page cancels a wheel event, which a page that pans or zooms with the
    /// trackpad does, from Rise's own world so pages never see it.
    static let wheelWatch = #"""
    (() => {
      const wheel = window.riseWheel = { prevented: -Infinity };
      addEventListener('wheel', event => {
        setTimeout(() => { if (event.defaultPrevented) wheel.prevented = performance.now(); }, 0);
      }, { capture: true, passive: true });
    })();
    """#
    private static let watched = NSHashTable<WKUserContentController>.weakObjects()
    static func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        // window.open can supply a configuration sharing the opener's controller.
        guard !watched.contains(controller) else { return }
        watched.add(controller)
        controller.addUserScript(WKUserScript(source: wheelWatch, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }
    // CSS coordinates account for WKWebView.pageZoom. Shadow DOM is traversed;
    // iframe contents are conservatively left alone, including cross-origin ones.
    // A page that cancelled the gesture's first wheel events keeps the gesture.
    static let scrollProbe = #"""
    let node = document.elementFromPoint(x * innerWidth / width, y * innerHeight / height);
    while (node?.shadowRoot) {
        const child = node.shadowRoot.elementFromPoint(x * innerWidth / width, y * innerHeight / height);
        if (!child || child === node) break;
        node = child;
    }
    while (node) {
        if (node.matches?.('iframe, frame, embed, object')) return false;
        const style = getComputedStyle(node);
        if (node.scrollWidth > node.clientWidth + 1 &&
            /^(auto|scroll|overlay)$/.test(style.overflowX)) return false;
        node = node.parentElement || node.getRootNode()?.host;
    }
    const root = document.scrollingElement;
    if (root && root.scrollWidth > root.clientWidth + 1 &&
        !/^(hidden|clip)$/.test(getComputedStyle(root).overflowX)) return false;
    const wheel = window.riseWheel;
    if (!wheel) return true;
    const takesWheel = () => performance.now() - wheel.prevented < 300;
    if (takesWheel()) return false;
    await new Promise(resolve => setTimeout(resolve, 50));
    return !takesWheel();
    """#
}

@MainActor extension BrowserController {
    func historyPage(at event: NSEvent) -> WKWebView? {
        // Hit-testing also excludes the URL palette, find panel, and Peek controls.
        guard window?.isKeyWindow == true else { return nil }
        let point = root.convert(event.locationInWindow, from: nil)
        guard let hit = root.hitTest(point) else { return nil }
        let pages = [peekTab?.webView, selectedTab?.webView, splitTab?.webView].compactMap { $0 }
        guard let page = pages.first(where: { $0.superview != nil && (hit === $0 || hit.isDescendant(of: $0)) }) else { return nil }
        // A Peek that has gone somewhere doesn't swipe: it neither goes back nor closes, so
        // browsing inside it can't throw it away. Its history is on the toolbar arrows.
        if page === peekTab?.webView, peekHasNavigated { return nil }
        if let tab = tabs.first(where: { $0.webView === page }), selectedID != tab.id { select(tab.id) }
        return page
    }
}
