import AppKit

/// Routes precise trackpad events only over visible pages. The engine's own history slide is
/// disabled; ordinary wheel/vertical/page horizontal scrolling still goes to the page. A short
/// isolated DOM probe protects carousels/editors, and, as in Safari, pages that take the wheel
/// themselves, like a drawing canvas that pans: a gesture's first events reach the page at once,
/// and only swipe if it lets them be.
@MainActor final class HistorySwipeController {
    static let worldName = "Rise.HistorySwipe"
    private weak var window: BrowserWindow?
    private let pageAt: (NSEvent) -> WebPage?
    private let feedback: (HistoryDirection?, Double, Bool, Bool?) -> Void
    var isPeekPage: ((WebPage) -> Bool)?
    /// Whether a page can go that way, which can include pages the browser holds beyond its own history.
    var canNavigate: (WebPage, HistoryDirection) -> Bool = { page, direction in direction == .back ? page.canGoBack : page.canGoForward }
    var navigate: (WebPage, HistoryDirection) -> Void = { page, direction in if direction == .back { page.goBack() } else { page.goForward() } }
    var dragPeek: ((Double) -> Void)?
    var releasePeek: ((Bool) -> Void)?
    var cancelPeek: (() -> Void)?
    /// The indicator over the page (`HistorySwipeIndicator`): following the pull, growing into the
    /// list of pages that way once held (nil folds it back), picking from it, and letting go.
    var indicatorDrag: ((WebPage, HistoryDirection, Double, Bool) -> Void)?
    var indicatorList: (([HistoryListEntry]?) -> Void)?
    var indicatorSelect: ((Int) -> Void)?
    var indicatorRelease: (() -> Void)?
    /// The pages that way in the page's own history, nearest first.
    var listEntries: (WebPage, HistoryDirection) -> [HistoryListEntry] = { _, _ in [] }
    /// Goes that many pages, for a page picked in the list.
    var navigateSteps: (WebPage, HistoryDirection, Int) -> Void = { page, direction, steps in
        for _ in 0..<steps { if direction == .back { page.goBack() } else { page.goForward() } }
    }
    /// How long a swipe past the threshold is held before its list comes up, as Dia's does.
    static let listDelay = 0.45
    private var listTimer: DispatchWorkItem?
    private var shownSelection = 0
    var selectionClick: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    private var peekGesture = false
    var thresholdClick: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    private weak var page: WebPage?
    private(set) var gesture = HistorySwipeState()
    private var pending: [NSEvent] = []
    private var probing = false, permitted = false, suppressMomentum = false
    var isActive: Bool { probing || gesture.isTracking }
    private var generation = 0
    private var probeTimeout: DispatchWorkItem?
    init(window: BrowserWindow, pageAt: @escaping (NSEvent) -> WebPage?,
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
    private func probe(_ page: WebPage, at event: NSEvent) {
        let token = generation
        let view = page.view
        var point = view.convert(event.locationInWindow, from: nil)
        if !view.isFlipped { point.y = view.bounds.height-point.y }
        let timeout = DispatchWorkItem { [weak self] in self?.resolveProbe(false, token: token) }
        probeTimeout = timeout
        // A busy web process doesn't swipe; scrolling never waits for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: timeout)
        Task { [weak self, weak page] in
            guard let page else { self?.resolveProbe(false, token: token); return }
            let result = await page.evaluate(Self.scrollProbe,
                arguments: ["x": point.x, "y": point.y, "width": max(1, view.bounds.width), "height": max(1, view.bounds.height)],
                world: Self.worldName)
            self?.resolveProbe(result as? Bool ?? false, token: token)
        }
    }
    private func resolveProbe(_ allows: Bool, token: Int) {
        guard generation == token, probing else { return }
        probing = false; permitted = allows; probeTimeout?.cancel(); probeTimeout = nil
        let events = pending; pending.removeAll()
        // The page has had these already; a swipe takes over their travel.
        if allows { gesture.begin(); events.forEach { _ = handleResolved($0) } }
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
        // A held swipe's list scrolls as a page does, by the user's own scroll direction.
        if gesture.move(dx: Double(dx), dy: Double(event.scrollingDeltaY),
                        canBack: peekGesture || canNavigate(page, .back), canForward: canNavigate(page, .forward)) { thresholdClick() }
        if gesture.consumesScroll {
            // The page stays still; only the arrow answers, and a Peek follows the pull back.
            feedback(gesture.direction, gesture.arrowPull, gesture.isArmed, nil)
            if peekGesture, gesture.direction == .back { dragPeek?(gesture.arrowPull) }
            else if let direction = gesture.direction { updateIndicator(page, direction) }
        }
        return gesture.consumesScroll
    }
    /// The circle follows the pull; held past the threshold, it becomes the list, and further
    /// pull picks further pages. Going back under the threshold folds the list away.
    private func updateIndicator(_ page: WebPage, _ direction: HistoryDirection) {
        indicatorDrag?(page, direction, gesture.arrowPull, gesture.isArmed)
        guard gesture.isArmed else {
            listTimer?.cancel(); listTimer = nil
            if gesture.listBase != nil { gesture.closeList(); indicatorList?(nil) }
            return
        }
        if gesture.listBase == nil, listTimer == nil {
            let token = generation
            let timer = DispatchWorkItem { [weak self, weak page] in
                guard let self, let page, self.generation == token, self.page === page else { return }
                self.listTimer = nil
                guard self.gesture.isTracking, self.gesture.isArmed, self.gesture.listBase == nil else { return }
                let entries = self.listEntries(page, direction)
                guard entries.count >= 2 else { return }
                self.gesture.openList(count: entries.count); self.shownSelection = 0
                self.indicatorList?(entries)
            }
            listTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.listDelay, execute: timer)
        }
        if gesture.listBase != nil, gesture.selection != shownSelection {
            shownSelection = gesture.selection
            indicatorSelect?(shownSelection); selectionClick()
        }
    }
    private func finish(cancelled: Bool) -> Bool {
        let consumed = gesture.consumesScroll, direction = gesture.direction, steps = gesture.steps
        listTimer?.cancel(); listTimer = nil
        if consumed { indicatorRelease?() }
        let page = self.page, committed = gesture.finish(cancelled: cancelled)
        let dismissesPeek = peekGesture && direction == .back
        suppressMomentum = consumed; permitted = false; self.page = nil; peekGesture = false
        feedback(direction, 0, false, committed != nil)
        if dismissesPeek { releasePeek?(committed != nil) }
        // Past the threshold the page simply goes there, at once.
        if !dismissesPeek, let committed, let page {
            if steps > 1 { navigateSteps(page, committed, steps) } else { navigate(page, committed) }
        }
        return consumed
    }
    func cancel(for page: WebPage) { if self.page === page { cancel() } }
    func cancel() {
        generation += 1; probeTimeout?.cancel(); probeTimeout = nil
        listTimer?.cancel(); listTimer = nil
        if gesture.consumesScroll { indicatorRelease?() }
        pending.removeAll(); probing = false; permitted = false; suppressMomentum = false
        let direction = gesture.direction, returnsPeek = peekGesture && direction == .back
        _ = gesture.finish(cancelled: true); page = nil; peekGesture = false
        if returnsPeek { cancelPeek?() }
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
    static func install(on page: WebPage) { page.addScriptToEveryDocument(wheelWatch, world: worldName) }
    // CSS coordinates account for the page's zoom. Shadow DOM is traversed;
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
    /// The swipe's indicator over `page`, cut off at its edges: over the page and its bars, under
    /// the link status, the address palette and its veil.
    func dragHistoryIndicator(on page: WebPage, _ direction: HistoryDirection, pull: Double, armed: Bool) {
        let indicator = historyIndicator
        if indicator.isHidden || indicator.superview !== root {
            indicator.removeFromSuperview()
            root.addSubview(indicator, positioned: .below, relativeTo: linkStatus.superview === root ? linkStatus : nil)
        }
        indicator.frame = page.view.convert(page.view.bounds, to: root)
        indicator.setTheme(theme)
        indicator.drag(direction: direction, pull: pull, armed: armed)
    }
    /// The pages that way in the page's own history, nearest first, with their titles and icons.
    func historyListEntries(for page: WebPage, _ direction: HistoryDirection) -> [HistoryListEntry] {
        guard let history = page.backForwardList else { return [] }
        let indices = direction == .back ? Array((0..<history.index).reversed())
            : Array((history.index+1)..<history.entries.count)
        return indices.prefix(8).map { index in
            let entry = history.entries[index], url = URL(string: entry.url)
            let blank = url == nil || entry.url == "about:blank"
            var title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty {
                title = blank ? "New Tab" : AddressDisplay.text(entry.url)
                if title.hasSuffix("/"), title.dropLast().contains(".") { title.removeLast() }
            }
            if let url { title = historyTitle(title, url: url) }
            let origin = SitePermissions.origin(url)
            let icon = blank ? nil : suggestionFavicons.image(for: url, fetch: false, dark: theme == .dark)
                ?? tabs.first { origin != nil && SitePermissions.origin($0.url) == origin && $0.favicon != nil }?.favicon(for: theme)
            return HistoryListEntry(title: title, icon: icon)
        }
    }
    func historyPage(at event: NSEvent) -> WebPage? {
        // Hit-testing also excludes the URL palette, find panel, and Peek controls.
        guard window?.isKeyWindow == true else { return nil }
        let point = root.convert(event.locationInWindow, from: nil)
        guard let hit = root.hitTest(point) else { return nil }
        let pages = [peekTab?.page, selectedTab?.page, splitTab?.page].compactMap { $0 }
        guard let page = pages.first(where: { $0.view.superview != nil && (hit === $0.view || hit.isDescendant(of: $0.view)) }) else { return nil }
        // A Peek that has gone somewhere doesn't swipe: it neither goes back nor closes, so
        // browsing inside it can't throw it away. Its history is on the toolbar arrows.
        if page === peekTab?.page, peekHasNavigated { return nil }
        if let tab = tabs.first(where: { $0.page === page }), selectedID != tab.id { select(tab.id) }
        return page
    }
}
