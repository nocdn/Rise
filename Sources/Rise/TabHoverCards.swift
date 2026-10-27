import AppKit

/// Hovering a tab shows its title and rename hint, or a pull request, merge request, Gmail, Proton Mail,
/// Google Chat or Google Calendar preview. Each appears and disappears at once, without a fade. Moving to a neighboring
/// tab keeps the hover session warm. Interactive previews glide over and allow crossing
/// into the card through a safe triangle to select text.
@MainActor final class TabHoverCards {
    static let delay = 0.5, grace = 0.35
    /// How old a preloaded Gmail list gets before browsing refreshes it; opening the card refreshes after a minute.
    static let backgroundRefresh: TimeInterval = 300
    /// Calendar refreshes more often, so a new event's countdown appears in time.
    static let calendarRefresh: TimeInterval = 120
    let pullRequestCard = PullRequestTooltip()
    let gmailCard = GmailTooltip()
    let chatCard = GoogleChatTooltip()
    let calendarCard = CalendarTooltip()
    let titleCard = TabTitleTooltip(frame: .zero)
    fileprivate enum Kind { case title, pullRequest, gmail, protonMail, chat, calendar }
    fileprivate var kind = Kind.title
    fileprivate var card: NSView {
        switch kind { case .title: titleCard; case .pullRequest: pullRequestCard; case .gmail, .protonMail: gmailCard; case .chat: chatCard; case .calendar: calendarCard }
    }
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
    /// The page, as its view, asked to pop an email out, whose popup goes in a Peek.
    weak var popoutSource: NSView?
    /// Over the whole window while a card shows, for its safe triangle (`trackPointer`).
    fileprivate var pointerArea: NSTrackingArea?
    init(storageURL: URL) { summaries = PullRequestSummaries(storageURL: storageURL) }
    /// Tabs whose card is interactive, rather than their title.
    static func hasPreview(_ url: URL?) -> Bool {
        PullRequest(url: url) != nil || GmailAccount(url: url) != nil || ProtonMailAccount(url: url) != nil
            || GoogleChatAccount(url: url) != nil || CalendarAccount(url: url) != nil
    }
}

@MainActor extension BrowserController {
    func tabHoverChanged(_ id: UUID, hovering: Bool) {
        let hover = tabHoverCards
        if hovering {
            hover.timer?.invalidate()
            guard sidebar.drag == nil, sidebar.pinnedDrag == nil, tabs.contains(where: { $0.id == id }), (sidebar.anchor(for: id) != nil && !sidebar.isRenaming(id)) else {
                hover.hoveredID = nil
                // Crossing another tab on the way to the card doesn't close it.
                if !pointerIsHeadingForCard() { hideTabHoverCard() }
                return
            }
            let url = tabs.first(where: { $0.id == id })?.url
            if hover.shownID != nil, hover.kind != .title, !TabHoverCards.hasPreview(url), pointerIsHeadingForCard() {
                // Preserve the route through neighboring tabs into an interactive preview.
                hover.hoveredID = nil; return
            }
            if let shown = hover.shownID, shown != id, hover.kind != .title, TabHoverCards.hasPreview(url), hover.safeOrigin != nil,
               pointerIsHeadingForCard() {
                // Another preview's tab, crossed on the way into the open card: it waits to see
                // whether the pointer stays.
                hover.hoveredID = id; awaitAim(id, from: pointerInRoot); return
            }
            hover.hoveredID = id; hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil
            // Only previews hand over to the next preview at once; a title waits its full delay
            // every time, and whatever was showing goes first.
            let warm = hover.shownID != nil || CACurrentMediaTime()-hover.hiddenAt < TabHoverCards.grace
            if warm, hover.kind != .title, TabHoverCards.hasPreview(url) { showTabHoverCard(id); return }
            if hover.shownID != nil { hideTabHoverCard(); hover.hoveredID = id }
            // Previews (pull requests, mail, Calendar) wait as long as the motion tester has them set to.
            let delay = TabHoverCards.hasPreview(url) ? CardMotion.hoverDelay : TabHoverCards.delay
            hover.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showTabHoverCard(id) }
            }
        } else {
            guard hover.hoveredID == id else { return }
            hover.hoveredID = nil; hover.timer?.invalidate()
            guard hover.shownID != nil else { return }
            if hover.kind == .title { hideTabHoverCard(); return }
            hover.safeOrigin = pointerInRoot; hover.safeTarget = nil
            hover.leftRow = sidebar.anchor(for: id).map { $0.convert($0.bounds, to: root).insetBy(dx: 0, dy: -(TabAppearance.spacing+1)) }
            // Crossing to the next row exits this one first; the next row claims the card in the same turn.
            DispatchQueue.main.async { [weak self] in self?.closeCardIfAbandoned() }
        }
    }
    /// The pointer moved while the card is open: off the tab, outside the card and its safe triangle closes it.
    func tabHoverPointerMoved() {
        let hover = tabHoverCards
        if hover.kind == .title, let id = hover.shownID {
            guard let row = sidebar.anchor(for: id), let point = pointerInRoot,
                  row.visibleRect.intersection(row.bounds).contains(row.convert(point, from: root)) else {
                hideTabHoverCard(); return
            }
            return
        }
        guard hover.shownID != nil, hover.safeOrigin != nil else { return }
        // Turning away from the card over another preview's tab hands the card to it at once.
        if let id = hover.hoveredID, id != hover.shownID, !pointerIsHeadingForCard() { handCardOver(id); return }
        closeCardIfAbandoned()
    }
    /// The card stays while the pointer crosses another preview's tab toward it. Pausing there,
    /// or heading anywhere but the card, gives that tab its own card.
    private func awaitAim(_ id: UUID, from last: NSPoint?) {
        let hover = tabHoverCards
        hover.timer?.invalidate()
        hover.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tabHoverCards.hoveredID == id, self.tabHoverCards.shownID != id else { return }
                let point = self.pointerInRoot
                let resting = point.flatMap { point in last.map { hypot(point.x-$0.x, point.y-$0.y) < 3 } } ?? true
                if resting || !self.pointerIsHeadingForCard() { self.handCardOver(id) } else { self.awaitAim(id, from: point) }
            }
        }
    }
    private func handCardOver(_ id: UUID) {
        let hover = tabHoverCards
        hover.timer?.invalidate(); hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil
        showTabHoverCard(id)
    }
    /// A click or drag on a tab dismisses the card, and the next one waits for the delay again.
    func tabPressed() {
        let hover = tabHoverCards
        hover.timer?.invalidate(); hover.hoveredID = nil
        hideTabHoverCard(); hover.hiddenAt = -.infinity
    }
    func showTabHoverCard(_ id: UUID) {
        let hover = tabHoverCards
        guard hover.hoveredID == id, sidebar.drag == nil, sidebar.pinnedDrag == nil, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let row = sidebar.anchor(for: id), row.window != nil, !sidebar.isRenaming(id) else { return }
        if GmailAccount(url: tab.url) != nil {
            showGmailTooltip(id); return
        }
        if ProtonMailAccount(url: tab.url) != nil {
            showProtonMailTooltip(id); return
        }
        if GoogleChatAccount(url: tab.url) != nil {
            showChatTooltip(id); return
        }
        if CalendarAccount(url: tab.url) != nil {
            showCalendarTooltip(id); return
        }
        guard let pr = PullRequest(url: tab.url) else {
            hover.pullRequestCard.dismiss(); hover.gmailCard.dismiss(); hover.chatCard.dismiss(); hover.calendarCard.dismiss(); hover.kind = .title; hover.shownID = id
            raiseHoverCard(hover.titleCard)
            trackPointer(true)
            hover.titleCard.showsHint = !(row is PinnedTabTile)
            hover.titleCard.present(title: tab.title, beside: row.convert(row.bounds, to: root), left: sidebar.frame.maxX+6,
                                    pinned: row is PinnedTabTile, theme: theme)
            return
        }
        // Only a pull request's own card, just gone, glides over to the next; any other card
        // goes out with its motion and this one comes in with its own.
        let glides = hover.kind == .pullRequest && CACurrentMediaTime()-hover.hiddenAt < TabHoverCards.grace
        hover.shownID = id
        hover.gmailCard.dismiss(); hover.chatCard.dismiss(); hover.calendarCard.dismiss(); hover.titleCard.dismiss(); hover.kind = .pullRequest
        let title = pr.title(fromTab: tab.title)
        hover.summaries.load(pr, title: title) { [weak tab] in
            guard let page = tab?.page, PullRequest(url: page.url) == pr else { return nil }
            return try? await PageAssistant.snapshot(of: page).text
        }
        hover.summaries.refreshStatus(pr)
        if hover.pullRequestCard.superview !== root {
            hover.pullRequestCard.onPointer = { [weak self] inside in self?.cardPointerChanged(inside) }
            hover.pullRequestCard.onOpenFiles = { [weak self] in self?.openFromPullRequestCard(.files) }
            hover.pullRequestCard.onWantsBreakdown = { [weak self] in
                guard let self, let id = self.tabHoverCards.shownID, let tab = self.tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url) else { return }
                self.tabHoverCards.summaries.loadBreakdown(pr)
            }
            hover.pullRequestCard.onOpenPipeline = { [weak self] pipeline in self?.openFromPullRequestCard(.pipeline(pipeline)) }
            hover.pullRequestCard.onOpenMergeChecks = { [weak self] in self?.openFromPullRequestCard(.mergeChecks) }
            hover.pullRequestCard.onRegenerate = { [weak self] in self?.regenerateTabCardSummary() }
            hover.pullRequestCard.onEdit = { [weak self] key, title, summary in self?.tabHoverCards.summaries.setCustom(key, title: title, summary: summary) }
            hover.pullRequestCard.onShowCustom = { [weak self] key, shown in self?.tabHoverCards.summaries.showCustom(key, shown) }
        }
        raiseHoverCard(hover.pullRequestCard)
        // The safe triangle needs every pointer move, not only those over tracked views.
        trackPointer(true)
        let anchor = previewAnchor(row)
        hover.pullRequestCard.present(key: pr.key, content: tooltipContent(pr, title: title), left: sidebar.frame.maxX+6,
                              placement: .beside(top: anchor.top, maxBottom: root.bounds.height-8), theme: theme,
                              glides: glides, fromTab: true, growsFrom: anchor.growsFrom)
    }
    /// The card's tab closed, changed accounts, or stopped being a supported page.
    func refreshTabHoverCard() {
        guard let id = tabHoverCards.shownID else { return }
        guard let tab = tabs.first(where: { $0.id == id }), (sidebar.anchor(for: id) != nil && !sidebar.isRenaming(id)) else { hideTabHoverCard(); return }
        if tabHoverCards.kind == .title {
            tabHoverCards.titleCard.update(title: tab.title, theme: theme)
            return
        }
        if tabHoverCards.kind == .gmail {
            if GmailAccount(url: tabs.first(where: { $0.id == id })?.url) != gmailInbox.request?.account { hideTabHoverCard() }
            return
        }
        if tabHoverCards.kind == .protonMail {
            if ProtonMailAccount(url: tabs.first(where: { $0.id == id })?.url) != protonMailInbox.request?.account { hideTabHoverCard() }
            return
        }
        if tabHoverCards.kind == .chat {
            if GoogleChatAccount(url: tabs.first(where: { $0.id == id })?.url) != chatInbox.request?.account { hideTabHoverCard() }
            return
        }
        if tabHoverCards.kind == .calendar {
            if CalendarAccount(url: tabs.first(where: { $0.id == id })?.url) != calendarAgenda.account { hideTabHoverCard() }
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
        trackPointer(false)
        hover.pullRequestCard.dismiss()
        hover.gmailCard.dismiss()
        hover.chatCard.dismiss()
        hover.calendarCard.dismiss()
        hover.titleCard.dismiss()
    }
    func pullRequestSummaryChanged(_ key: String) {
        linkCardSummaryChanged(key)
        let hover = tabHoverCards
        guard hover.pullRequestCard.key == key, let id = hover.shownID, let tab = tabs.first(where: { $0.id == id }),
              let pr = PullRequest(url: tab.url), pr.key == key else { return }
        hover.pullRequestCard.update(tooltipContent(pr, title: pr.title(fromTab: tab.title)))
    }
    private func regenerateTabCardSummary() {
        guard let id = tabHoverCards.shownID, let tab = tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url) else { return }
        regenerateSummary(pr, title: pr.title(fromTab: tab.title), page: tab.page)
    }
    /// The ⋯ menu's Regenerate: a new description, reading the page when it's the request's own.
    func regenerateSummary(_ pr: PullRequest, title: String, page: WebPage?) {
        tabHoverCards.summaries.regenerate(pr, title: title) { [weak page] in
            guard let page, PullRequest(url: page.url) == pr else { return nil }
            return try? await PageAssistant.snapshot(of: page).text
        }
    }
    enum PullRequestCardLink { case files, pipeline(Pipeline), mergeChecks }
    /// Each goes to the card's tab: the file count on the changed files, the pipeline number
    /// with the pipeline's jobs in a Peek over it, and the merge status scrolled to the merge checks.
    private func openFromPullRequestCard(_ link: PullRequestCardLink) {
        guard let id = tabHoverCards.shownID, let tab = tabs.first(where: { $0.id == id }), let pr = PullRequest(url: tab.url) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        open(link, of: pr, in: tab)
    }
    func open(_ link: PullRequestCardLink, of pr: PullRequest, in tab: BrowserTab) {
        switch link {
        case .pipeline(let pipeline): if let url = pipeline.jobsURL { showPeek(url: url) }
        case .files: if let url = pr.filesURL, tab.url != url { tab.load(url) }
        case .mergeChecks:
            guard let url = pr.overviewURL else { return }
            let web = tab.page
            let onOverview = web.url.map { $0.path.trimmingCharacters(in: ["/"]) == url.path.trimmingCharacters(in: ["/"]) } ?? false
            if !onOverview { tab.load(url) }
            Task { [weak web] in
                // Wait for the overview to be the page loaded, then let the page find its widget.
                for _ in 0..<150 {
                    guard let web else { return }
                    if web.url.map({ $0.path.trimmingCharacters(in: ["/"]) == url.path.trimmingCharacters(in: ["/"]) }) == true, !web.isLoading { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                _ = try? await web?.evaluate("return " + Self.scrollToMergeChecks, arguments: [:], in: nil, world: .named("Rise.HoverCards"))
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
        if inside { for tab in tabs { setCovered(true, tab) }; if let peekTab { setCovered(true, peekTab) } }
        else { updatePeekCovers() }
        if inside { hover.safeOrigin = nil; hover.safeTarget = nil; hover.leftRow = nil; return }
        // Heading back from the card to its tab crosses a gap first; a triangle toward the tab
        // keeps the card from blinking out on the way.
        hover.safeOrigin = pointerInRoot
        hover.safeTarget = hover.shownID.flatMap { sidebar.anchor(for: $0) }.map { $0.convert($0.bounds, to: root) }
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
        return TabHoverCards.hasPreview(tabs.first(where: { $0.id == id })?.url)
    }
    var pointerInRoot: NSPoint? {
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
    /// Hover cards go over everything on the page, Peeks and their controls included, which
    /// are added later and would otherwise sit above a card added before them.
    /// The safe triangle needs every pointer move, not only those over tracked views. A tracking
    /// area over the window brings them through `sendEvent`; the window's own mouse-moved events
    /// would go to the focused page too, which sets its cursor (a text cursor over its text)
    /// over the card's links.
    func trackPointer(_ tracks: Bool) {
        let hover = tabHoverCards
        if tracks, hover.pointerArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: PointerMovesSink.shared, userInfo: nil)
            root.addTrackingArea(area); hover.pointerArea = area
        } else if !tracks, let area = hover.pointerArea {
            root.removeTrackingArea(area); hover.pointerArea = nil
        }
    }
    func raiseHoverCard(_ card: NSView) {
        if let index = root.subviews.firstIndex(of: dismissArea), index > 0, root.subviews[index-1] === card { return }
        root.addSubview(card, positioned: .below, relativeTo: dismissArea)
    }
    /// Where a preview card starts and grows from: level with a row's top, out of the row beside
    /// it; a pinned tile's card starts level with the tile's bottom and comes out of its
    /// bottom-right corner.
    func previewAnchor(_ row: NSView) -> (top: CGFloat, growsFrom: NSPoint?) {
        let frame = row.convert(row.bounds, to: root)
        return row is PinnedTabTile ? (frame.maxY, NSPoint(x: frame.maxX, y: frame.maxY)) : (frame.minY, nil)
    }
    func tooltipContent(_ pr: PullRequest, title: String) -> PullRequestTooltip.Content {
        let entry = tabHoverCards.summaries.entry(for: pr)
        // A card that couldn't be described says so rather than standing empty.
        let summary = entry.phase == .failed && entry.summary.isEmpty ? PullRequestSummaries.failure(pr) : entry.summary
        return PullRequestTooltip.Content(title: entry.details?.title ?? title, reference: pr.reference, details: entry.details,
                                          summary: summary, phase: entry.phase, inputTokens: entry.inputTokens, custom: entry.custom,
                                          breakdownPending: tabHoverCards.summaries.isLoadingBreakdown(pr))
    }

    func showGmailTooltip(_ id: UUID) {
        let hover = tabHoverCards
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let account = GmailAccount(url: tab.url),
              let row = sidebar.anchor(for: id), row.window != nil else { return }
        hover.pullRequestCard.dismiss(); hover.chatCard.dismiss(); hover.calendarCard.dismiss(); hover.titleCard.dismiss(); hover.kind = .gmail; hover.shownID = id
        // Proton Mail shares the card, so each sets its own actions as it shows.
        hover.gmailCard.onPointer = { [weak self] in self?.cardPointerChanged($0) }
        hover.gmailCard.onLoadMore = { [weak self] in self?.gmailInbox.loadMore() }
        hover.gmailCard.onOpen = { [weak self] email in self?.openGmailEmail(email) }
        raiseHoverCard(hover.gmailCard)
        trackPointer(true)
        gmailInbox.prepare(account: account, category: gmailCategory, source: tab.page, host: root)
        let anchor = previewAnchor(row)
        hover.gmailCard.present(key: account.baseURL.absoluteString+"|"+gmailCategory.rawValue, inbox: gmailInbox,
                            left: sidebar.frame.maxX+6, anchorTop: anchor.top, maxBottom: root.bounds.height-8,
                            theme: theme, growsFrom: anchor.growsFrom)
    }
    func gmailInboxChanged() {
        guard tabHoverCards.kind == .gmail, tabHoverCards.shownID != nil else { return }
        tabHoverCards.gmailCard.update(gmailInbox)
    }

    /// Gmail's card, with the Proton Mail inbox.
    func showProtonMailTooltip(_ id: UUID) {
        let hover = tabHoverCards
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let account = ProtonMailAccount(url: tab.url),
              let row = sidebar.anchor(for: id), row.window != nil else { return }
        hover.pullRequestCard.dismiss(); hover.chatCard.dismiss(); hover.calendarCard.dismiss(); hover.titleCard.dismiss(); hover.kind = .protonMail; hover.shownID = id
        hover.gmailCard.onPointer = { [weak self] in self?.cardPointerChanged($0) }
        hover.gmailCard.onLoadMore = { [weak self] in self?.protonMailInbox.loadMore() }
        hover.gmailCard.onOpen = { [weak self] email in self?.openProtonMailEmail(email) }
        raiseHoverCard(hover.gmailCard)
        trackPointer(true)
        protonMailInbox.prepare(.init(account: account), source: tab.page, host: root)
        let anchor = previewAnchor(row)
        hover.gmailCard.present(key: account.baseURL.absoluteString, inbox: protonMailInbox,
                                left: sidebar.frame.maxX+6, anchorTop: anchor.top, maxBottom: root.bounds.height-8,
                                theme: theme, growsFrom: anchor.growsFrom)
    }
    func protonMailInboxChanged() {
        guard tabHoverCards.kind == .protonMail, tabHoverCards.shownID != nil else { return }
        tabHoverCards.gmailCard.update(protonMailInbox)
    }
    /// The tab opens the email beside its inbox, as Proton's own list does: a change of route when
    /// Proton is open there, or Proton opening at the email.
    private func openProtonMailEmail(_ email: GmailEmail) {
        guard let id = tabHoverCards.shownID, let request = protonMailInbox.request,
              let message = request.account.messageURL(id: email.id, page: protonMailInbox.page(of: email.id)),
              let tab = tabs.first(where: { $0.id == id }) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        let web = tab.page
        guard ProtonMailAccount(url: web.url) == request.account, !web.isLoading else { tab.load(message); return }
        let route = message.path + (message.fragment.map { "#" + $0 } ?? "")
        Task { [weak tab, weak web] in
            guard let web, (try? await web.evaluate(ProtonMailPageReader.open, arguments: ["route": route], in: nil,
                                                    world: .named(ProtonMailPageReader.world))) as? Bool != true
            else { return }
            tab?.load(message)
        }
    }
    /// Chat's DMs, newest first; opening the card rereads its list, which Chat keeps current.
    func showChatTooltip(_ id: UUID) {
        let hover = tabHoverCards
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let account = GoogleChatAccount(url: tab.url),
              let row = sidebar.anchor(for: id), row.window != nil else { return }
        hover.pullRequestCard.dismiss(); hover.gmailCard.dismiss(); hover.calendarCard.dismiss(); hover.titleCard.dismiss(); hover.kind = .chat; hover.shownID = id
        hover.chatCard.onPointer = { [weak self] in self?.cardPointerChanged($0) }
        hover.chatCard.onLoadMore = { [weak self] in self?.chatInbox.loadMore() }
        hover.chatCard.onOpen = { [weak self] conversation in self?.openChatConversation(conversation) }
        raiseHoverCard(hover.chatCard)
        trackPointer(true)
        chatInbox.prepare(.init(account: account), source: tab.page, host: root, refreshAfter: 5)
        let anchor = previewAnchor(row)
        hover.chatCard.present(key: account.baseURL.absoluteString, inbox: chatInbox,
                               left: sidebar.frame.maxX+6, anchorTop: anchor.top, maxBottom: root.bounds.height-8,
                               theme: theme, growsFrom: anchor.growsFrom)
    }
    func chatInboxChanged() {
        guard tabHoverCards.kind == .chat, tabHoverCards.shownID != nil else { return }
        tabHoverCards.chatCard.update(chatInbox)
    }
    /// The tab opens the conversation as Chat's Home does, beside its list. Home comes first if
    /// the tab is elsewhere in Chat, and an older conversation is scrolled to.
    private func openChatConversation(_ conversation: ChatConversation) {
        guard let id = tabHoverCards.shownID, let request = chatInbox.request, let tab = tabs.first(where: { $0.id == id }) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        let web = tab.page
        Task { [weak tab, weak web] in
            var wentHome = false
            // Up to 20 s, for a Chat that has to load first.
            for _ in 0..<130 {
                guard let tab, let web, GoogleChatAccount(url: web.url) == request.account || !wentHome else { return }
                if !web.isLoading, GoogleChatAccount(url: web.url) == request.account {
                    let result = try? await web.evaluate(GoogleChatPageReader.open, arguments: ["id": conversation.id], in: nil,
                                                         world: .named(GoogleChatPageReader.world)) as? String
                    if result == "opened" || result == "missing" { return }
                    if result == "away", !GoogleChatAccount.isHome(web.url), !wentHome { wentHome = true; tab.load(request.account.homeURL) }
                } else if !wentHome, !web.isLoading { wentHome = true; tab.load(request.account.homeURL) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
    /// As Gmail's: the selected Chat tab's account wins, then the one already loaded.
    func preloadChatInbox() {
        let chats = tabs.filter { GoogleChatAccount(url: $0.url) != nil }
        guard let tab = chats.first(where: { $0.id == selectedID })
                ?? chats.first(where: { GoogleChatAccount(url: $0.url) == chatInbox.request?.account }) ?? chats.first,
              let account = GoogleChatAccount(url: tab.url) else {
            if chatInbox.request != nil, tabHoverCards.shownID == nil { chatInbox.tearDown() }
            return
        }
        guard tabHoverCards.shownID == nil, root.window != nil else { return }
        chatInbox.prepare(.init(account: account), source: tab.page, host: root, refreshAfter: TabHoverCards.backgroundRefresh)
    }
    /// As Gmail's: the selected Proton Mail tab's account wins, then the one already loaded.
    func preloadProtonMailInbox() {
        let proton = tabs.filter { ProtonMailAccount(url: $0.url) != nil }
        guard let tab = proton.first(where: { $0.id == selectedID })
                ?? proton.first(where: { ProtonMailAccount(url: $0.url) == protonMailInbox.request?.account }) ?? proton.first,
              let account = ProtonMailAccount(url: tab.url) else {
            if protonMailInbox.request != nil, tabHoverCards.shownID == nil { protonMailInbox.tearDown() }
            return
        }
        guard tabHoverCards.shownID == nil, root.window != nil else { return }
        protonMailInbox.prepare(.init(account: account), source: tab.page, host: root, refreshAfter: TabHoverCards.backgroundRefresh)
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
        let web = tab.page
        tabHoverCards.popoutSource = web.view
        Task { [weak self, weak web] in
            // Up to 7.5 s for the list to show the row, then 2 s for Gmail to open its window.
            for _ in 0..<50 {
                guard let self, let web, self.tabHoverCards.popoutSource === web.view else { return }
                // Run as if from a click, which Gmail's window needs on Chromium.
                if !web.isLoading, (try? await web.evaluate("return " + GmailPageReader.popOut(email.id), arguments: [:], in: nil, world: .page)) as? Bool == true {
                    for _ in 0..<40 where self.tabHoverCards.popoutSource === web.view { try? await Task.sleep(for: .milliseconds(50)) }
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self, self.tabHoverCards.popoutSource === web?.view else { return }
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
        gmailInbox.prepare(account: account, category: gmailCategory, source: tab.page, host: root,
                           refreshAfter: TabHoverCards.backgroundRefresh)
    }

    func showCalendarTooltip(_ id: UUID) {
        let hover = tabHoverCards
        guard hover.hoveredID == id, isSidebarShown, window?.isVisible == true,
              let tab = tabs.first(where: { $0.id == id }), let account = CalendarAccount(url: tab.url),
              let row = sidebar.anchor(for: id), row.window != nil else { return }
        hover.pullRequestCard.dismiss(); hover.gmailCard.dismiss(); hover.chatCard.dismiss(); hover.titleCard.dismiss(); hover.kind = .calendar; hover.shownID = id
        if hover.calendarCard.superview !== root {
            hover.calendarCard.onPointer = { [weak self] in self?.cardPointerChanged($0) }
            hover.calendarCard.onRetry = { [weak self] in self?.calendarAgenda.retry() }
            hover.calendarCard.onOpen = { [weak self] event in self?.openCalendarEvent(event) }
        }
        raiseHoverCard(hover.calendarCard)
        trackPointer(true)
        calendarAgenda.prepare(account: account, source: tab.page, host: root)
        let anchor = previewAnchor(row)
        hover.calendarCard.present(key: account.baseURL.absoluteString, agenda: calendarAgenda,
                                   left: sidebar.frame.maxX+6, anchorTop: anchor.top, maxBottom: root.bounds.height-8,
                                   theme: theme, growsFrom: anchor.growsFrom)
    }
    func calendarAgendaChanged() {
        refreshCalendarBadges()
        guard tabHoverCards.kind == .calendar, tabHoverCards.shownID != nil else { return }
        tabHoverCards.calendarCard.update(calendarAgenda)
    }
    /// The card's tab opens the event's details, as a click on its chip does. A chip the tab
    /// doesn't show sends the tab to the event's day first, in the view the tab was in.
    private func openCalendarEvent(_ event: CalendarEvent) {
        guard let id = tabHoverCards.shownID, let tab = tabs.first(where: { $0.id == id }),
              let account = CalendarAccount(url: tab.url) else { return }
        tabPressed()
        if selectedID != id { select(id) }
        let web = tab.page, script = "return " + CalendarPageReader.open(event.id)
        func open(_ web: WebPage) async -> Bool {
            guard !web.isLoading else { return false }
            return (try? await web.evaluate(script, arguments: [:], in: nil, world: .named(CalendarPageReader.world))) as? Bool == true
        }
        Task { [weak tab, weak web] in
            guard let web, await !open(web), let tab else { return }
            let day = Calendar.current.dateComponents([.year, .month, .day], from: event.start)
            tab.load(account.url(view: CalendarAccount.view(of: web.url) ?? "week", day: day))
            // Up to 12 s for Calendar to load and draw the day's events.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(200))
                if await open(tab.page) { return }
            }
        }
    }
    /// While a Calendar tab is open its events load in the background, for the card and the
    /// tab's countdown. The selected Calendar tab's account wins, then the one already loaded.
    func preloadCalendarAgenda() {
        let calendars = tabs.filter { CalendarAccount(url: $0.url) != nil }
        guard let tab = calendars.first(where: { $0.id == selectedID })
                ?? calendars.first(where: { CalendarAccount(url: $0.url) == calendarAgenda.account }) ?? calendars.first,
              let account = CalendarAccount(url: tab.url) else {
            if calendarAgenda.account != nil, tabHoverCards.shownID == nil { calendarAgenda.tearDown() }
            refreshCalendarBadges()
            return
        }
        refreshCalendarBadges()
        guard tabHoverCards.shownID == nil, root.window != nil else { return }
        calendarAgenda.prepare(account: account, source: tab.page, host: root, refreshAfter: TabHoverCards.calendarRefresh)
    }
}

/// Takes the moves a tracking area asks for and does nothing with them: the window's `sendEvent`
/// has already seen them.
final class PointerMovesSink: NSResponder {
    static let shared = PointerMovesSink()
    override func mouseMoved(with event: NSEvent) {}
}
