import AppKit

/// Go to Open Tabs: clicking a link that's already open in another tab switches to that tab
/// rather than opening it again. Only a plain click: ⌘-click still opens a new tab, as do Shift and
/// Option for Peek. A pull or merge request counts as open from any of its pages, so a link to one
/// open on its changes or pipelines goes to that tab as it is. Each page's script knows the links
/// open elsewhere, kept in its own world where the page can't see them, so it can stop the click
/// before the page acts on it.
@MainActor final class OpenTabLinks {
    static let preferenceKey = "Rise.GoToOpenTabs"
    static let externalPreferenceKey = "Rise.ReuseExternalLinks"
    static let worldName = "Rise.OpenTabLinks"
    private let preferences: UserDefaults
    /// What's open in tabs other than a page's: their addresses, and the requests among them by
    /// their overview's address, which a link to any of their pages matches.
    struct Open: Equatable {
        var links: [String] = [], requests: [String] = []
        var message: [String: [String]] { ["links": links, "requests": requests] }
    }
    /// What each page was last given, so only a change is sent.
    private let sent = NSMapTable<AnyObject, NSDictionary>.weakToStrongObjects()
    var openLinks: ((WebPage) -> Open)?
    var goTo: ((_ url: URL, _ from: WebPage) -> Void)?

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    /// On unless turned off in rise://settings.
    var enabled: Bool { preferences.object(forKey: Self.preferenceKey) as? Bool ?? true }
    func setEnabled(_ on: Bool) { preferences.set(on, forKey: Self.preferenceKey) }
    /// Separate from in-page clicks: links received from Mail, Messages and other apps.
    var reusesExternalLinks: Bool { preferences.object(forKey: Self.externalPreferenceKey) as? Bool ?? true }
    func setReusesExternalLinks(_ on: Bool) { preferences.set(on, forKey: Self.externalPreferenceKey) }

    /// Preserve the page, query and fragment. Only normalize equivalent HTTP origins and an
    /// empty root path, since an app may send `https://example.com` for an open `…com/` tab.
    static func externalAddress(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return url.absoluteString }
        parts.scheme = scheme; parts.host = parts.host?.lowercased()
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.string ?? url.absoluteString
    }

    func install(on page: WebPage) {
        // A new document asks for the list as it starts; changes are sent to it after.
        page.addMessageHandler("riseOpenTabs", world: .named(Self.worldName), replying: { [weak self] message, reply in
            guard let self, message.frame.isMain, let page = message.page else { reply([String](), nil); return }
            let open = self.open(for: page)
            self.remember(open, for: page)
            reply(open.message, nil)
        })
        page.addMessageHandler("riseOpenTabLink", world: .named(Self.worldName)) { [weak self] message in
            guard let self, self.enabled, message.frame.isMain, let page = message.page,
                  let url = (message.body as? String).flatMap(URL.init(string:)) else { return }
            self.goTo?(url, page)
        }
        page.addUserScript(Self.script, world: .named(Self.worldName), mainFrameOnly: true, handlers: ["riseOpenTabs", "riseOpenTabLink"])
    }
    /// While the chat's model clicks in `page`, its links go where they lead, in the page, rather
    /// than to the tab that has the page open: the model is using this one.
    func hold(_ held: Bool, on page: WebPage) {
        page.evaluate("globalThis.riseOpenTabsHeld = held", arguments: ["held": held], in: nil, world: .named(Self.worldName)) { _ in }
    }
    private func open(for page: WebPage) -> Open { enabled ? openLinks?(page) ?? Open() : Open() }
    private func remember(_ open: Open, for page: WebPage) { sent.setObject(open.message as NSDictionary, forKey: page) }
    /// Brings the lists of `pages`, those on screen, up to date.
    func refresh(_ pages: [WebPage]) {
        for page in pages {
            let open = open(for: page)
            if sent.object(forKey: page) == open.message as NSDictionary { continue }
            remember(open, for: page)
            page.evaluate("globalThis.riseOpenTabs?.(open)", arguments: ["open": open.message], in: nil, world: .named(Self.worldName)) { _ in }
        }
    }

    static let script = #"""
    (() => {
      let open = new Set(), requests = [];
      globalThis.riseOpenTabs = given => { open = new Set(given?.links || []); requests = given?.requests || [] };
      // A request's overview, or any page under it: its changes, commits, pipelines.
      const isOpen = href => open.has(href) || requests.some(request => href === request || ['/', '?', '#'].some(next => href.startsWith(request + next)));
      riseHandlers.riseOpenTabs.postMessage(null).then(links => globalThis.riseOpenTabs(links), () => {});
      // Capturing on the window, before the page's own handlers, so a site that routes its links
      // itself doesn't act on the click first.
      addEventListener('click', event => {
        if (globalThis.riseOpenTabsHeld || !event.isTrusted || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || !open.size && !requests.length) return;
        const link = event.composedPath().find(node => (node instanceof HTMLAnchorElement || node instanceof HTMLAreaElement) && node.href);
        if (!link || link.hasAttribute('download') || !isOpen(link.href)) return;
        event.preventDefault(); event.stopImmediatePropagation();
        riseHandlers.riseOpenTabLink.postMessage(link.href);
      }, true);
    })();
    """#
}

@MainActor extension BrowserController {
    /// An external link reuses its exact page, without reloading it or losing scroll and forms.
    /// Unlike in-page request links, a request's Files and Overview remain distinct here.
    @discardableResult func openExternalURL(_ url: URL) -> BrowserTab {
        guard openTabLinks.reusesExternalLinks else { return addTab(url: url) }
        let address = OpenTabLinks.externalAddress(url)
        func matches(_ tab: BrowserTab) -> Bool { tab.url.map(OpenTabLinks.externalAddress) == address }
        if let peekTab, matches(peekTab) {
            hidePalette(); window?.makeFirstResponder(peekTab.page.view)
            return peekTab
        }
        guard let tab = selectedTab.flatMap({ matches($0) ? $0 : nil }) ?? tabs.first(where: matches) else { return addTab(url: url) }
        select(tab.id)
        // A restored Peek mustn't obscure the page the other app asked to show. Keep it with
        // its owner so its forms and navigation are still there when reopened.
        if peekTab != nil { suspendPeek(); update() }
        window?.makeFirstResponder(tab.page.view)
        return tab
    }

    /// What's open in tabs other than `page`'s, leaving out the address it's on and, on a request,
    /// the request's other pages: a link to the page itself, or between its request's own pages,
    /// behaves as usual.
    func linksOpenElsewhere(than page: WebPage) -> OpenTabLinks.Open {
        let own = page.url?.absoluteString, ownRequest = PullRequest(url: page.url)
        var open = OpenTabLinks.Open()
        var links = Set<String>(), requests = Set<String>()
        for tab in tabs where tab.page !== page {
            guard let url = tab.url, url.absoluteString != own else { continue }
            let request = tab.pullRequest
            if let request, request == ownRequest { continue }
            if links.insert(url.absoluteString).inserted { open.links.append(url.absoluteString) }
            if let overview = request?.overviewURL?.absoluteString, requests.insert(overview).inserted { open.requests.append(overview) }
        }
        return open
    }
    /// The tab a clicked link is already open in, other than the one it was clicked in: one on that
    /// address, or else one on any page of the same request, left on that page.
    func goToOpenTab(_ url: URL, from page: WebPage) {
        let others = tabs.filter { $0.page !== page }
        let request = PullRequest(url: url)
        guard let tab = others.first(where: { $0.url?.absoluteString == url.absoluteString })
                ?? request.flatMap({ request in others.first { PullRequest(url: $0.url) == request } }) else { return }
        select(tab.id)
    }
    /// Pages on screen: the selected tab's, the other half of a split, and a Peek's.
    var shownPages: [WebPage] { tabs.filter { visibleTabIDs.contains($0.id) }.map(\.page) + [peekTab?.page].compactMap { $0 } }
}
