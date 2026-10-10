import AppKit
import WebKit

/// Hovering a pull request, merge request or Gmail tab opens its card, which opens and closes at
/// once like a tooltip. While one is open, or just after it closes, another supported tab
/// shows its card immediately, gliding the open one over. The pointer can cross from the tab
/// into the card through a safe triangle, to select its text.
@MainActor final class TabHoverCards {
    static let delay = 0.5, grace = 0.35
    /// How old a preloaded Gmail list gets before browsing refreshes it; opening the card refreshes after a minute.
    static let backgroundRefresh: TimeInterval = 300
    let pullRequestCard = PullRequestTooltip()
    let gmailCard = GmailTooltip()
    fileprivate var showsGmail = false
    fileprivate var card: NSView { showsGmail ? gmailCard : pullRequestCard }
    let summaries: PullRequestSummaries
    fileprivate var hoveredID: UUID?
    fileprivate(set) var shownID: UUID?
    fileprivate var timer: Timer?
    fileprivate var hiddenAt = -Double.infinity
    /// Where the pointer left the tab, while it heads for the card.
    fileprivate var safeOrigin: NSPoint?
    /// Where the pointer is heading from `safeOrigin`: the card, or back from the card to its tab.
    fileprivate var safeTarget: NSRect?
    /// The row the pointer just left, grown over the gaps to its neighbours, so crossing a gap
    /// to the next supported tab keeps the card and glides it over.
    fileprivate var leftRow: NSRect?
    fileprivate var insideCard = false
    /// The Gmail tab asked to pop a conversation out, whose window becomes a Peek.
    weak var popoutSource: WKWebView?
    fileprivate var tracksPointer = false
    init(storageURL: URL) { summaries = PullRequestSummaries(storageURL: storageURL) }
}

@MainActor extension BrowserController {
    func tabHoverChanged(_ id: UUID, hovering: Bool) {
        let hover = tabHoverCards
        if hovering {
            hover.timer?.invalidate()
            let url = tabs.first(where: { $0.id == id })?.url
            guard sidebar.drag == nil, PullRequest(url: url) != nil || GmailAccount(url: url) != nil else {
                hover.hoveredID = nil
                // Crossing another tab on the way to the card doesn't close it.
                if !pointerIsHeadingForCard() { hideTabHoverCard() }
                return
            }
            hover.hoveredID = id; hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil
            if hover.shownID != nil || CACurrentMediaTime()-hover.hiddenAt < TabHoverCards.grace { showTabHoverCard(id); return }
            hover.timer = Timer.scheduledTimer(withTimeInterval: TabHoverCards.delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showTabHoverCard(id) }
            }
        } else {
            guard hover.hoveredID == id else { return }
            hover.hoveredID = nil; hover.timer?.invalidate()
            guard hover.shownID != nil else { return }
            hover.safeOrigin = pointerInRoot; hover.safeTarget = nil
            hover.leftRow = sidebar.rows[id].map { $0.convert($0.bounds, to: root).insetBy(dx: 0, dy: -(TabAppearance.spacing+1)) }
            // Crossing to the next row exits this one first; the next row claims the card in the same turn.
            DispatchQueue.main.async { [weak self] in self?.closeCardIfAbandoned() }
        }
    }
    /// The pointer moved while the card is open: off the tab, outside the card and its safe triangle closes it.
    func tabHoverPointerMoved() {
        let hover = tabHoverCards
        guard hover.shownID != nil, hover.safeOrigin != nil else { return }
        closeCardIfAbandoned()
    }
    /// A click or drag on a tab dismisses the card, and the next one waits for the delay again.
    func tabPressed() {
        let hover = tabHoverCards
        hover.timer?.invalidate(); hover.hoveredID = nil
        hideTabHoverCard(); hover.hiddenAt = -.infinity
    }
    func showTabHoverCard(_ id: UUID) {
        let hover = tabHoverCards
        if let tab = tabs.first(where: { $0.id == id }), GmailAccount(url: tab.url) != nil {
            showGmailTooltip(id); return
        }
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url),
              let row = sidebar.rows[id], row.window != nil else { return }
        hover.shownID = id
        hover.gmailCard.dismiss(); hover.showsGmail = false
        let title = pr.title(fromTab: tab.title)
        hover.summaries.load(pr, title: title) { [weak tab] in
            guard let webView = tab?.webView, PullRequest(url: webView.url) == pr else { return nil }
            return try? await PageAssistant.snapshot(of: webView).text
        }
        hover.summaries.refreshStatus(pr)
        if hover.pullRequestCard.superview !== root {
            root.addSubview(hover.pullRequestCard, positioned: .below, relativeTo: dismissArea)
            hover.pullRequestCard.onPointer = { [weak self] inside in self?.cardPointerChanged(inside) }
            hover.pullRequestCard.onOpenFiles = { [weak self] in self?.openFromPullRequestCard(.files) }
            hover.pullRequestCard.onOpenPipeline = { [weak self] pipeline in self?.openFromPullRequestCard(.pipeline(pipeline)) }
            hover.pullRequestCard.onOpenMergeChecks = { [weak self] in self?.openFromPullRequestCard(.mergeChecks) }
        }
        // The safe triangle needs every pointer move, not only those over tracked views.
        if !hover.tracksPointer, let window { hover.tracksPointer = !window.acceptsMouseMovedEvents; window.acceptsMouseMovedEvents = true }
        let anchor = row.convert(row.bounds, to: root)
        hover.pullRequestCard.present(key: pr.key, content: tooltipContent(pr, title: title), left: sidebar.frame.maxX+6,
                              anchorTop: anchor.minY, maxBottom: root.bounds.height-8, theme: theme,
                              glides: CACurrentMediaTime()-hover.hiddenAt < TabHoverCards.grace)
    }
    /// The card's tab closed, changed accounts, or stopped being a supported page.
    func refreshTabHoverCard() {
        guard let id = tabHoverCards.shownID else { return }
        if tabHoverCards.showsGmail {
            if GmailAccount(url: tabs.first(where: { $0.id == id })?.url) != gmailInbox.request?.account { hideTabHoverCard() }
            return
        }
        if PullRequest(url: tabs.first(where: { $0.id == id })?.url) == nil { hideTabHoverCard() }
    }
    func hideTabHoverCard() {
        let hover = tabHoverCards
        hover.timer?.invalidate(); hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil; hover.insideCard = false
        guard hover.shownID != nil else { return }
        hover.shownID = nil; hover.hiddenAt = CACurrentMediaTime()
        updatePeekCovers()
        if hover.tracksPointer { window?.acceptsMouseMovedEvents = false; hover.tracksPointer = false }
        hover.pullRequestCard.dismiss()
        hover.gmailCard.dismiss()
    }
    func pullRequestSummaryChanged(_ key: String) {
        let hover = tabHoverCards
        guard hover.pullRequestCard.key == key, let id = hover.shownID, let tab = tabs.first(where: { $0.id == id }),
              let pr = PullRequest(url: tab.url), pr.key == key else { return }
        hover.pullRequestCard.update(tooltipContent(pr, title: pr.title(fromTab: tab.title)))
    }
    enum PullRequestCardLink { case files, pipeline(Pipeline), mergeChecks }
    /// Each goes to the card's tab: the file count on the changed files, the pipeline number
    /// with the pipeline's jobs in a Peek over it, and the merge status scrolled to the merge checks.
    private func openFromPullRequestCard(_ link: PullRequestCardLink) {
        guard let id = tabHoverCards.shownID, let tab = tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        switch link {
        case .pipeline(let pipeline): if let url = pipeline.jobsURL { showPeek(url: url) }
        case .files: if let url = pr.filesURL, tab.url != url { tab.load(url) }
        case .mergeChecks:
            guard let url = pr.overviewURL else { return }
            let web = tab.webView
            let onOverview = web.url.map { $0.path.trimmingCharacters(in: ["/"]) == url.path.trimmingCharacters(in: ["/"]) } ?? false
            if !onOverview { tab.load(url) }
            Task { [weak web] in
                // Wait for the overview to be the page loaded, then let the page find its widget.
                for _ in 0..<150 {
                    guard let web else { return }
                    if web.url.map({ $0.path.trimmingCharacters(in: ["/"]) == url.path.trimmingCharacters(in: ["/"]) }) == true, !web.isLoading { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                _ = try? await web?.evaluateJavaScript(Self.scrollToMergeChecks, contentWorld: .defaultClient)
            }
        }
    }
    /// GitLab draws its merge widget after the page loads; this waits up to 10 s for it, then
    /// scrolls it into the middle of the page.
    static let scrollToMergeChecks = """
    (() => {
      const selectors = ['[data-testid="merge-checks"]', '.mr-state-widget', '.mr-widget-section', '#js-vue-mr-widget'];
      let tries = 0;
      const find = () => {
        const widget = selectors.map(s => document.querySelector(s)).find(e => e && e.getBoundingClientRect().height > 0);
        if (widget) widget.scrollIntoView({ block: 'center', behavior: 'smooth' });
        else if (++tries < 50) setTimeout(find, 200);
      };
      find();
    })();
    """
    func cardPointerChanged(_ inside: Bool) {
        let hover = tabHoverCards
        hover.insideCard = inside
        // The pages under the card keep their hover tracking otherwise, and would take the
        // card's pointer and cursor for their own links.
        if inside { for tab in tabs { (tab.webView as? LinkCursorWebView)?.isCovered = true }; (peekTab?.webView as? LinkCursorWebView)?.isCovered = true }
        else { updatePeekCovers() }
        if inside { hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil; return }
        // Heading back from the card to its tab crosses a gap first; a triangle toward the tab
        // keeps the card from blinking out on the way.
        hover.safeOrigin = pointerInRoot
        hover.safeTarget = hover.shownID.flatMap { sidebar.rows[$0] }.map { $0.convert($0.bounds, to: root) }
        DispatchQueue.main.async { [weak self] in self?.closeCardIfAbandoned() }
    }
    private func closeCardIfAbandoned() {
        let hover = tabHoverCards
        guard hover.shownID != nil, hover.hoveredID == nil, !hover.insideCard, !pointerIsHeadingForCard(),
              !pointerIsOverCardTab else { return }
        hideTabHoverCard()
    }
    /// A quick move can land well inside the next row before its tracking area reports the
    /// entry. Over another supported tab, the card waits for that entry and glides over
    /// instead of closing and popping back open.
    private var pointerIsOverCardTab: Bool {
        guard let point = pointerInRoot, let id = sidebar.tabID(at: sidebar.convert(point, from: root)) else { return false }
        let url = tabs.first(where: { $0.id == id })?.url
        return PullRequest(url: url) != nil || GmailAccount(url: url) != nil
    }
    private var pointerInRoot: NSPoint? {
        guard let window else { return nil }
        return root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    /// Inside the card or the gap beside the row just left, or inside the triangle from where
    /// the pointer left (the tab or the card) to the near edge of where it's heading.
    private func pointerIsHeadingForCard() -> Bool {
        let hover = tabHoverCards
        guard hover.shownID != nil, let point = pointerInRoot else { return false }
        let card = hover.card.frame
        if card.contains(point) || hover.leftRow?.contains(point) == true { return true }
        guard let origin = hover.safeOrigin else { return false }
        let target = hover.safeTarget ?? card
        if target.contains(point) || hypot(point.x-origin.x, point.y-origin.y) < 2 { return true }
        let edge = target.minX >= origin.x ? target.minX : target.maxX
        let a = origin, b = NSPoint(x: edge, y: target.minY), c = NSPoint(x: edge, y: target.maxY)
        func side(_ p: NSPoint, _ q: NSPoint, _ r: NSPoint) -> CGFloat { (p.x-r.x)*(q.y-r.y)-(q.x-r.x)*(p.y-r.y) }
        let d1 = side(point, a, b), d2 = side(point, b, c), d3 = side(point, c, a)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }
    private func tooltipContent(_ pr: PullRequest, title: String) -> PullRequestTooltip.Content {
        let entry = tabHoverCards.summaries.entry(for: pr)
        return PullRequestTooltip.Content(title: entry.details?.title ?? title, reference: pr.reference, details: entry.details,
                                          summary: entry.summary, phase: entry.phase)
    }

    func showGmailTooltip(_ id: UUID) {
        let hover = tabHoverCards
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let account = GmailAccount(url: tab.url),
              let row = sidebar.rows[id], row.window != nil else { return }
        hover.pullRequestCard.dismiss(); hover.showsGmail = true; hover.shownID = id
        if hover.gmailCard.superview !== root {
            root.addSubview(hover.gmailCard, positioned: .below, relativeTo: dismissArea)
            hover.gmailCard.onPointer = { [weak self] in self?.cardPointerChanged($0) }
            hover.gmailCard.onLoadMore = { [weak self] in self?.gmailInbox.loadMore() }
            hover.gmailCard.onOpen = { [weak self] email in self?.openGmailEmail(email) }
        }
        if !hover.tracksPointer, let window { hover.tracksPointer = !window.acceptsMouseMovedEvents; window.acceptsMouseMovedEvents = true }
        gmailInbox.prepare(account: account, category: gmailCategory, source: tab.webView, host: root)
        let anchor = row.convert(row.bounds, to: root)
        hover.gmailCard.present(key: account.baseURL.absoluteString+"|"+gmailCategory.rawValue, inbox: gmailInbox,
                            left: sidebar.frame.maxX+6, anchorTop: anchor.minY, maxBottom: root.bounds.height-8,
                            theme: theme, glides: CACurrentMediaTime()-hover.hiddenAt < TabHoverCards.grace)
    }
    func gmailInboxChanged() {
        guard tabHoverCards.showsGmail, tabHoverCards.shownID != nil else { return }
        tabHoverCards.gmailCard.update(gmailInbox)
    }
    /// The tab goes to the card's category, with the email popped out in a Peek over it: Gmail's
    /// light "Open in new window" conversation, not a second Gmail. Without its row, the email
    /// opens in a Peek of Gmail instead.
    private func openGmailEmail(_ email: GmailEmail) {
        guard let id = tabHoverCards.shownID, let request = gmailInbox.request,
              let message = request.account.messageURL(id: email.id), let tab = tabs.first(where: { $0.id == id }) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        let list = request.account.listURL(category: request.category, page: gmailInbox.page(of: email.id))
        if GmailPageReader.route(tab.url) != GmailPageReader.route(list) { tab.load(list) }
        let web = tab.webView
        tabHoverCards.popoutSource = web
        Task { [weak self, weak web] in
            // Up to 7.5 s for the list to show the row, then 2 s for Gmail to open its window.
            for _ in 0..<50 {
                guard let self, let web, self.tabHoverCards.popoutSource === web else { return }
                if !web.isLoading, (try? await web.evaluateJavaScript(GmailPageReader.popOut(email.id), contentWorld: .page)) as? Bool == true {
                    for _ in 0..<40 where self.tabHoverCards.popoutSource === web { try? await Task.sleep(for: .milliseconds(50)) }
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, self.tabHoverCards.popoutSource === web else { return }
            self.tabHoverCards.popoutSource = nil
            self.showPeek(url: message)
        }
    }
    /// While a Gmail tab is open its emails load in the background, so the card opens with them.
    /// The selected Gmail tab's account wins, then the one already loaded.
    func preloadGmailInbox() {
        let gmail = tabs.filter { GmailAccount(url: $0.url) != nil }
        guard let tab = gmail.first(where: { $0.id == selectedID })
                ?? gmail.first(where: { GmailAccount(url: $0.url) == gmailInbox.request?.account }) ?? gmail.first,
              let account = GmailAccount(url: tab.url) else {
            if gmailInbox.request != nil, tabHoverCards.shownID == nil { gmailInbox.tearDown() }
            return
        }
        // The open card keeps its own list until it closes.
        guard tabHoverCards.shownID == nil, root.window != nil else { return }
        gmailInbox.prepare(account: account, category: gmailCategory, source: tab.webView, host: root,
                           refreshAfter: TabHoverCards.backgroundRefresh)
    }
}
