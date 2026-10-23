import AppKit

/// Resting on a link to a pull request or merge request on a page shows the tab's card for it,
/// and holding Option on any other link shows a summary of the page it leads to, as wide as the
/// link and just above it (below when there's no room above). It springs in and fades out. The
/// pointer can cross the gap into it to select text or follow its links.
@MainActor final class LinkPullRequestCards {
    /// What a link's card is about.
    enum Subject: Equatable {
        case pullRequest(PullRequest), summary(URL)
        var key: String {
            switch self { case .pullRequest(let pr): pr.key; case .summary(let url): LinkSummaries.key(url) }
        }
        var pullRequest: PullRequest? { if case .pullRequest(let pr) = self { return pr }; return nil }
        static func == (a: Subject, b: Subject) -> Bool { a.key == b.key }
        /// A pull request's link, or with Option held any page's.
        init?(url: URL?, option: Bool) {
            if let pr = PullRequest(url: url) { self = .pullRequest(pr) }
            else if option, let url, LinkSummaries.summarizes(url) { self = .summary(url) }
            else { return nil }
        }
        /// The link's address, as the page reports it under the pointer, still points at it.
        func matches(_ url: URL?) -> Bool {
            switch self {
            case .pullRequest(let pr): PullRequest(url: url) == pr
            case .summary(let target): url.map { LinkSummaries.key($0) == LinkSummaries.key(target) } ?? false
            }
        }
    }
    static let delay = 0.75, grace = 0.35, gap: CGFloat = 6
    /// Option already asks for a summary, so it comes sooner than a pull request's card.
    static let summaryDelay = 0.2
    static let minimumWidth: CGFloat = 300, maximumWidth: CGFloat = 640
    /// Below this much room above the link, the card goes under it.
    static let roomAbove: CGFloat = 200
    let card = PullRequestTooltip()
    let summaries = LinkSummaries()
    fileprivate var timer: Timer?
    /// What the link under the pointer is about, and its page.
    fileprivate var hovered: Subject?
    fileprivate weak var hoveredWeb: NSView?
    fileprivate(set) var shown: Subject?
    /// The link's own words, the card's title until the details arrive.
    fileprivate var title = ""
    fileprivate weak var shownWeb: NSView?
    /// The link's box in the root view, as the card was placed.
    fileprivate var linkFrame = NSRect.zero
    fileprivate var insideCard = false
    fileprivate var hiddenAt = -Double.infinity
    fileprivate var lookups = 0, checks = 0
    /// The page whose link is lit (`LinkHighlight.swift`).
    var highlightedWeb: NSView?

    /// The link's text, unless it's only a reference or an address, for a title before the details arrive.
    nonisolated static func title(fromLink text: String, _ pr: PullRequest) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.contains(" ") ? line : "\(pr.project) \(pr.reference)"
    }
}

@MainActor extension BrowserController {
    /// The page's hovered link changed, on a page that's showing and not covered, or Option was
    /// pressed or let go over it.
    func linkHoverChanged(_ url: URL?, in web: NSView, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        let links = linkPullRequests
        // Letting Option go leaves a summary where it is.
        if !modifiers.contains(.option), case .summary = links.shown, links.shown?.matches(url) == true, links.shownWeb === web { return }
        links.timer?.invalidate(); links.timer = nil
        let pr = LinkPullRequestCards.Subject(url: url, option: modifiers.contains(.option))
        // Heading up from the link into its card crosses the page under the card, whose
        // links (on a list, other pull requests) report hovers of their own. They don't count.
        if let shown = links.shown, let point = pointerInRoot, linkCardZone.contains(point) {
            links.hovered = pr == shown && links.shownWeb === web ? pr : nil
            links.hoveredWeb = links.hovered == nil ? nil : web
            if links.hovered == nil { links.checks = 0; checkLinkCardSoon() }
            return
        }
        links.hovered = pr; links.hoveredWeb = pr == nil ? nil : web
        guard let pr else {
            // Off the link: the card stays while the pointer crosses the gap into it, its link lit.
            if links.shown != nil { links.checks = 0; checkLinkCardSoon() } else { setLinkHighlight(.off, in: links.highlightedWeb) }
            return
        }
        if links.shown == pr, links.shownWeb === web { return }
        // Lit while its card is on the way.
        lightLink(.pulsing, for: pr, in: web)
        // Going from one card's link to the next shows the next at once.
        let warm = links.shown != nil || CACurrentMediaTime()-links.hiddenAt < LinkPullRequestCards.grace
        let delay = if case .summary = pr { LinkPullRequestCards.summaryDelay } else { LinkPullRequestCards.delay }
        links.timer = Timer.scheduledTimer(withTimeInterval: warm ? 0 : delay, repeats: false) { [weak self, weak web] _ in
            MainActor.assumeIsolated { if let web { self?.showLinkCard(pr, in: web) } }
        }
    }
    private func showLinkCard(_ pr: LinkPullRequestCards.Subject, in web: NSView) {
        let links = linkPullRequests
        guard links.hovered == pr, links.hoveredWeb === web, let page = page(showing: web), !page.isCovered else { return }
        links.lookups += 1
        let lookup = links.lookups
        Task {
            guard let found = await hoveredLink(in: page), links.lookups == lookup, links.hovered == pr, links.hoveredWeb === web,
                  pr.matches(found.url), web.window === window, !page.isCovered else { return }
            let title = pr.pullRequest.map { LinkPullRequestCards.title(fromLink: found.text, $0) } ?? ""
            presentLinkCard(pr, title: title, link: web.convert(found.rect, to: root), in: web, page: page)
        }
    }
    func presentLinkCard(_ subject: LinkPullRequestCards.Subject, title: String, link: NSRect, in web: NSView, page: WebPage) {
        let links = linkPullRequests, card = links.card
        let bounds = web.convert(web.bounds, to: root).insetBy(dx: 8, dy: 8)
        let width = min(bounds.width, max(LinkPullRequestCards.minimumWidth, min(LinkPullRequestCards.maximumWidth, round(link.width))))
        // Lined up with the link, or centred over one narrower than the card.
        let left = max(bounds.minX, min(link.width >= width ? link.minX : link.midX-width/2, bounds.maxX-width))
        let placement: PullRequestTooltip.Placement = link.minY-bounds.minY >= LinkPullRequestCards.roomAbove
            ? .above(bottom: link.minY-LinkPullRequestCards.gap, minTop: bounds.minY)
            : .beside(top: link.maxY+LinkPullRequestCards.gap, maxBottom: bounds.maxY)
        switch subject {
        case .pullRequest(let pr):
            tabHoverCards.summaries.load(pr, title: title) { [weak page] in
                guard let page, PullRequest(url: page.url) == pr else { return nil }
                return try? await PageAssistant.snapshot(of: page).text
            }
            tabHoverCards.summaries.refreshStatus(pr)
        case .summary(let url):
            if links.summaries.onChange == nil {
                links.summaries.host = root
                links.summaries.provider = { [weak self] in self?.modelChoice ?? .openRouter }
                links.summaries.onChange = { [weak self] key in self?.linkCardSummaryChanged(key) }
            }
            links.summaries.load(url)
        }
        if card.superview !== root {
            card.onPointer = { [weak self] inside in self?.linkCardPointerChanged(inside) }
            card.onOpenFiles = { [weak self] in self?.openFromLinkCard(.files) }
            card.onWantsBreakdown = { [weak self] in if let self, let pr = self.linkPullRequests.shown?.pullRequest { self.tabHoverCards.summaries.loadBreakdown(pr) } }
            card.onOpenPipeline = { [weak self] pipeline in self?.openFromLinkCard(.pipeline(pipeline)) }
            card.onOpenMergeChecks = { [weak self] in self?.openFromLinkCard(.mergeChecks) }
            card.onEdit = { [weak self] key, title, summary in self?.tabHoverCards.summaries.setCustom(key, title: title, summary: summary) }
            card.onShowCustom = { [weak self] key, shown in self?.tabHoverCards.summaries.showCustom(key, shown) }
            card.onRegenerate = { [weak self] in
                guard let self, let shown = self.linkPullRequests.shown else { return }
                switch shown {
                case .pullRequest(let pr): self.regenerateSummary(pr, title: self.linkPullRequests.title, page: self.page(showing: self.linkPullRequests.shownWeb))
                case .summary(let url): self.linkPullRequests.summaries.regenerate(url)
                }
            }
        }
        raiseHoverCard(card)
        // Another link's card makes way rather than gliding across the page.
        if links.shown != nil { card.dismiss() }
        links.shown = subject; links.shownWeb = web; links.linkFrame = link; links.insideCard = false; links.title = title
        // Steady once there's something in the card; a summary pulses on until its words come.
        lightLink(linkCardIsWaiting(subject) ? .pulsing : .steady, for: subject, in: web)
        card.present(key: subject.key, content: linkCardContent(subject, title: title), left: left, placement: placement,
                     theme: theme, width: width, pops: true)
    }
    /// A summary that hasn't started showing yet.
    private func linkCardIsWaiting(_ subject: LinkPullRequestCards.Subject) -> Bool {
        if case .summary(let url) = subject { return linkPullRequests.summaries.entry(for: url).summary.isEmpty }
        return false
    }
    /// A pull request's card, or the summary alone, with the skeleton line while it's written.
    private func linkCardContent(_ subject: LinkPullRequestCards.Subject, title: String) -> PullRequestTooltip.Content {
        switch subject {
        case .pullRequest(let pr): return tooltipContent(pr, title: title)
        case .summary(let url):
            let entry = linkPullRequests.summaries.entry(for: url)
            return PullRequestTooltip.Content(title: "", reference: "", details: nil, summary: entry.summary, phase: entry.phase, inputTokens: entry.inputTokens)
        }
    }
    /// The page went away, changed or lost its hover: no card, and none on the way.
    func hideLinkCard(fades: Bool = true) {
        let links = linkPullRequests
        links.timer?.invalidate(); links.timer = nil; links.lookups += 1
        links.hovered = nil; links.hoveredWeb = nil
        dismissLinkCard(fades: fades)
        setLinkHighlight(.off, in: links.highlightedWeb)
    }
    private func dismissLinkCard(fades: Bool = true) {
        let links = linkPullRequests
        guard links.shown != nil else { return }
        links.shown = nil; links.shownWeb = nil; links.hiddenAt = CACurrentMediaTime()
        // Its link goes dark, unless the pointer's on to another link whose card is coming.
        if links.hovered == nil || links.hoveredWeb !== links.highlightedWeb { setLinkHighlight(.off, in: links.highlightedWeb) }
        if links.insideCard { links.insideCard = false; updatePeekCovers() }
        links.card.dismiss(fades: fades)
    }
    func linkCardSummaryChanged(_ key: String) {
        let links = linkPullRequests
        guard let shown = links.shown, shown.key == key, links.card.key == key else { return }
        links.card.update(linkCardContent(shown, title: links.title))
        if !linkCardIsWaiting(shown), links.highlightedWeb === links.shownWeb { setLinkHighlight(.steady, in: links.shownWeb) }
    }
    private func linkCardPointerChanged(_ inside: Bool) {
        let links = linkPullRequests
        guard links.shown != nil else { return }
        links.insideCard = inside
        // The page under the card would otherwise take its pointer and cursor for its own links.
        if inside { for tab in tabs { setCovered(true, tab) }; if let peekTab { setCovered(true, peekTab) }; return }
        updatePeekCovers()
        links.checks = 0; checkLinkCardSoon()
    }
    private func checkLinkCardSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { [weak self] in self?.closeLinkCardIfAbandoned() }
    }
    /// Over the card, its link, or the gap between them, the card stays; elsewhere it fades.
    /// Over the link with no hover reported (the page catches up after being uncovered, or
    /// scrolled the link away), it waits a few checks before giving up.
    private func closeLinkCardIfAbandoned() {
        let links = linkPullRequests
        guard let shown = links.shown, !links.insideCard, links.hovered != shown || links.hoveredWeb !== links.shownWeb else { return }
        let card = links.card.frame, link = links.linkFrame
        guard links.hovered == nil, let point = pointerInRoot else { dismissLinkCard(); return }
        if card.contains(point) { return }
        links.checks += 1
        if linkCardZone.contains(point), links.checks < 4 { checkLinkCardSoon(); return }
        dismissLinkCard()
    }
    /// The card, its link and the gap between them, across the width they share.
    private var linkCardZone: NSRect {
        let links = linkPullRequests, card = links.card.frame, link = links.linkFrame
        let left = max(link.minX, card.minX), right = min(link.maxX, card.maxX)
        let top = min(link.minY, card.minY), bottom = max(link.maxY, card.maxY)
        return NSRect(x: left, y: top, width: max(0, right-left), height: bottom-top).union(card)
    }
    private func openFromLinkCard(_ link: PullRequestCardLink) {
        let links = linkPullRequests
        guard let pr = links.shown?.pullRequest, let web = links.shownWeb,
              let tab = (tabs+allPeekTabs).first(where: { $0.page.view === web }) else { return }
        hideLinkCard(fades: false)
        open(link, of: pr, in: tab)
    }

    /// The link under the pointer: its box in the page's view, its address and its text. Lit
    /// (`LinkHighlight.swift`, whose world it runs in), it's the grey's box, ring and all, so the
    /// card lines up with that.
    static let hoveredLinkScript = """
    let node = document.elementFromPoint(x, y);
    while (node?.shadowRoot) {
      const inner = node.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === node) break;
      node = inner;
    }
    while (node && !node.matches?.('a[href], area[href]')) node = node.parentElement ?? node.getRootNode?.()?.host ?? null;
    if (!node) return null;
    let r = node.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return null;
    const lit = window.__riseLinkHighlight;
    if (lit?.el === node) r = new DOMRect(r.left - lit.side - ring, r.top - ring, r.width + (lit.side + ring) * 2, r.height + ring * 2);
    return [r.left, r.top, r.width, r.height, node.href, (node.innerText || node.textContent || '').trim().slice(0, 300)];
    """
    private func hoveredLink(in page: WebPage) async -> (rect: NSRect, url: URL?, text: String)? {
        let web = page.view
        guard let window = web.window, !page.isMagnified, !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 0 else { return nil }
        let zoom = max(0.01, page.zoom)
        var point = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !web.isFlipped { point.y = web.bounds.height-point.y }
        guard web.bounds.contains(point) else { return nil }
        let result = await page.evaluate(Self.hoveredLinkScript, arguments: ["x": point.x/zoom, "y": point.y/zoom, "ring": LinkPulse.steady.width],
                                         world: Self.linkHighlightWorld) as? [Any]
        guard let result, result.count == 6, let x = result[0] as? NSNumber, let y = result[1] as? NSNumber,
              let w = result[2] as? NSNumber, let h = result[3] as? NSNumber else { return nil }
        var rect = NSRect(x: x.doubleValue*zoom, y: y.doubleValue*zoom, width: w.doubleValue*zoom, height: h.doubleValue*zoom)
        if !web.isFlipped { rect.origin.y = web.bounds.height-rect.maxY }
        return (rect, (result[4] as? String).flatMap(URL.init(string:)), result[5] as? String ?? "")
    }
}
