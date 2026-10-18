import AppKit

/// Resting on a link to a pull request or merge request on a page shows the tab's card for it,
/// as wide as the link and just above it (below when there's no room above). It springs in and
/// fades out. The pointer can cross the gap into it to select text or follow its links.
@MainActor final class LinkPullRequestCards {
    static let delay = 0.75, grace = 0.35, gap: CGFloat = 6
    static let minimumWidth: CGFloat = 300, maximumWidth: CGFloat = 640
    /// Below this much room above the link, the card goes under it.
    static let roomAbove: CGFloat = 200
    let card = PullRequestTooltip()
    fileprivate var timer: Timer?
    /// The pull request of the link under the pointer, and its page.
    fileprivate var hovered: PullRequest?
    fileprivate weak var hoveredWeb: NSView?
    fileprivate var shown: PullRequest?
    /// The link's own words, the card's title until the details arrive.
    fileprivate var title = ""
    fileprivate weak var shownWeb: NSView?
    /// The link's box in the root view, as the card was placed.
    fileprivate var linkFrame = NSRect.zero
    fileprivate var insideCard = false
    fileprivate var hiddenAt = -Double.infinity
    fileprivate var lookups = 0, checks = 0

    /// The link's text, unless it's only a reference or an address, for a title before the details arrive.
    nonisolated static func title(fromLink text: String, _ pr: PullRequest) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.contains(" ") ? line : "\(pr.project) \(pr.reference)"
    }
}

@MainActor extension BrowserController {
    /// The page's hovered link changed, on a page that's showing and not covered.
    func linkHoverChanged(_ url: URL?, in web: NSView) {
        let links = linkPullRequests
        links.timer?.invalidate(); links.timer = nil
        let pr = PullRequest(url: url)
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
            // Off the link: the card stays while the pointer crosses the gap into it.
            if links.shown != nil { links.checks = 0; checkLinkCardSoon() }
            return
        }
        if links.shown == pr, links.shownWeb === web { return }
        // Going from one card's link to the next shows the next at once.
        let warm = links.shown != nil || CACurrentMediaTime()-links.hiddenAt < LinkPullRequestCards.grace
        links.timer = Timer.scheduledTimer(withTimeInterval: warm ? 0 : LinkPullRequestCards.delay, repeats: false) { [weak self, weak web] _ in
            MainActor.assumeIsolated { if let web { self?.showLinkCard(pr, in: web) } }
        }
    }
    private func showLinkCard(_ pr: PullRequest, in web: NSView) {
        let links = linkPullRequests
        guard links.hovered == pr, links.hoveredWeb === web, let page = page(showing: web), !page.isCovered else { return }
        links.lookups += 1
        let lookup = links.lookups
        Task {
            guard let found = await hoveredLink(in: page), links.lookups == lookup, links.hovered == pr, links.hoveredWeb === web,
                  PullRequest(url: found.url) == pr, web.window === window, !page.isCovered else { return }
            presentLinkCard(pr, title: LinkPullRequestCards.title(fromLink: found.text, pr), link: web.convert(found.rect, to: root), in: web, page: page)
        }
    }
    func presentLinkCard(_ pr: PullRequest, title: String, link: NSRect, in web: NSView, page: WebPage) {
        let links = linkPullRequests, card = links.card
        let bounds = web.convert(web.bounds, to: root).insetBy(dx: 8, dy: 8)
        let width = min(bounds.width, max(LinkPullRequestCards.minimumWidth, min(LinkPullRequestCards.maximumWidth, round(link.width))))
        // Lined up with the link, or centred over one narrower than the card.
        let left = max(bounds.minX, min(link.width >= width ? link.minX : link.midX-width/2, bounds.maxX-width))
        let placement: PullRequestTooltip.Placement = link.minY-bounds.minY >= LinkPullRequestCards.roomAbove
            ? .above(bottom: link.minY-LinkPullRequestCards.gap, minTop: bounds.minY)
            : .beside(top: link.maxY+LinkPullRequestCards.gap, maxBottom: bounds.maxY)
        tabHoverCards.summaries.load(pr, title: title) { [weak page] in
            guard let page, PullRequest(url: page.url) == pr else { return nil }
            return try? await PageAssistant.snapshot(of: page).text
        }
        tabHoverCards.summaries.refreshStatus(pr)
        if card.superview !== root {
            card.onPointer = { [weak self] inside in self?.linkCardPointerChanged(inside) }
            card.onOpenFiles = { [weak self] in self?.openFromLinkCard(.files) }
            card.onOpenPipeline = { [weak self] pipeline in self?.openFromLinkCard(.pipeline(pipeline)) }
            card.onOpenMergeChecks = { [weak self] in self?.openFromLinkCard(.mergeChecks) }
            card.onRegenerate = { [weak self] in
                guard let self, let pr = self.linkPullRequests.shown else { return }
                self.regenerateSummary(pr, title: self.linkPullRequests.title, page: self.page(showing: self.linkPullRequests.shownWeb))
            }
        }
        raiseHoverCard(card)
        // Another link's card makes way rather than gliding across the page.
        if links.shown != nil { card.dismiss() }
        links.shown = pr; links.shownWeb = web; links.linkFrame = link; links.insideCard = false; links.title = title
        card.present(key: pr.key, content: tooltipContent(pr, title: title), left: left, placement: placement,
                     theme: theme, width: width, pops: true)
    }
    /// The page went away, changed or lost its hover: no card, and none on the way.
    func hideLinkCard(fades: Bool = true) {
        let links = linkPullRequests
        links.timer?.invalidate(); links.timer = nil; links.lookups += 1
        links.hovered = nil; links.hoveredWeb = nil
        dismissLinkCard(fades: fades)
    }
    private func dismissLinkCard(fades: Bool = true) {
        let links = linkPullRequests
        guard links.shown != nil else { return }
        links.shown = nil; links.shownWeb = nil; links.hiddenAt = CACurrentMediaTime()
        if links.insideCard { links.insideCard = false; updatePeekCovers() }
        links.card.dismiss(fades: fades)
    }
    func linkCardSummaryChanged(_ key: String) {
        let links = linkPullRequests
        guard let pr = links.shown, pr.key == key, links.card.key == key else { return }
        links.card.update(tooltipContent(pr, title: links.title))
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
        guard let pr = links.shown, let web = links.shownWeb,
              let tab = (tabs+allPeekTabs).first(where: { $0.page.view === web }) else { return }
        hideLinkCard(fades: false)
        open(link, of: pr, in: tab)
    }

    /// The link under the pointer: its box in the page's view, its address and its text.
    static let hoveredLinkScript = """
    let node = document.elementFromPoint(x, y);
    while (node?.shadowRoot) {
      const inner = node.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === node) break;
      node = inner;
    }
    while (node && !node.matches?.('a[href], area[href]')) node = node.parentElement ?? node.getRootNode?.()?.host ?? null;
    if (!node) return null;
    const r = node.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return null;
    return [r.left, r.top, r.width, r.height, node.href, (node.innerText || node.textContent || '').trim().slice(0, 300)];
    """
    private func hoveredLink(in page: WebPage) async -> (rect: NSRect, url: URL?, text: String)? {
        let web = page.view
        guard let window = web.window, !page.isMagnified, !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 0 else { return nil }
        let zoom = max(0.01, page.zoom)
        var point = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !web.isFlipped { point.y = web.bounds.height-point.y }
        guard web.bounds.contains(point) else { return nil }
        let result = await page.evaluate(Self.hoveredLinkScript, arguments: ["x": point.x/zoom, "y": point.y/zoom], world: nil) as? [Any]
        guard let result, result.count == 6, let x = result[0] as? NSNumber, let y = result[1] as? NSNumber,
              let w = result[2] as? NSNumber, let h = result[3] as? NSNumber else { return nil }
        var rect = NSRect(x: x.doubleValue*zoom, y: y.doubleValue*zoom, width: w.doubleValue*zoom, height: h.doubleValue*zoom)
        if !web.isFlipped { rect.origin.y = web.bounds.height-rect.maxY }
        return (rect, (result[4] as? String).flatMap(URL.init(string:)), result[5] as? String ?? "")
    }
}
