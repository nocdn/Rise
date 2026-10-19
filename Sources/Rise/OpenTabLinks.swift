import AppKit

/// Go to Open Tabs: clicking a link that's already open in another tab switches to that tab
/// rather than opening it again. Only a plain click: ⌘-click still opens a new tab, as do Shift and
/// Option for Peek. Each page's script knows the links open elsewhere, kept in its own world where
/// the page can't see them, so it can stop the click before the page acts on it.
@MainActor final class OpenTabLinks {
    static let preferenceKey = "Rise.GoToOpenTabs"
    static let worldName = "Rise.OpenTabLinks"
    private let preferences: UserDefaults
    /// The list each page was last given, so only a change is sent.
    private let sent = NSMapTable<AnyObject, NSArray>.weakToStrongObjects()
    /// The links open in tabs other than the page's.
    var openLinks: ((WebPage) -> [String])?
    var goTo: ((_ url: URL, _ from: WebPage) -> Void)?

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    /// On unless turned off in rise://settings.
    var enabled: Bool { preferences.object(forKey: Self.preferenceKey) as? Bool ?? true }
    func setEnabled(_ on: Bool) { preferences.set(on, forKey: Self.preferenceKey) }

    func install(on page: WebPage) {
        // A new document asks for the list as it starts; changes are sent to it after.
        page.addMessageHandler("riseOpenTabs", world: .named(Self.worldName), replying: { [weak self] message, reply in
            guard let self, message.frame.isMain, let page = message.page else { reply([String](), nil); return }
            let links = self.links(for: page)
            self.sent.setObject(links as NSArray, forKey: page)
            reply(links, nil)
        })
        page.addMessageHandler("riseOpenTabLink", world: .named(Self.worldName)) { [weak self] message in
            guard let self, self.enabled, message.frame.isMain, let page = message.page,
                  let url = (message.body as? String).flatMap(URL.init(string:)) else { return }
            self.goTo?(url, page)
        }
        page.addUserScript(Self.script, world: .named(Self.worldName), mainFrameOnly: true, handlers: ["riseOpenTabs", "riseOpenTabLink"])
    }
    private func links(for page: WebPage) -> [String] { enabled ? openLinks?(page) ?? [] : [] }
    /// Brings the lists of `pages`, those on screen, up to date.
    func refresh(_ pages: [WebPage]) {
        for page in pages {
            let links = links(for: page)
            if let last = sent.object(forKey: page) as? [String], last == links { continue }
            sent.setObject(links as NSArray, forKey: page)
            page.evaluate("globalThis.riseOpenTabs?.(links)", arguments: ["links": links], in: nil, world: .named(Self.worldName)) { _ in }
        }
    }

    static let script = #"""
    (() => {
      let open = new Set();
      globalThis.riseOpenTabs = links => { open = new Set(links || []) };
      riseHandlers.riseOpenTabs.postMessage(null).then(links => globalThis.riseOpenTabs(links), () => {});
      // Capturing on the window, before the page's own handlers, so a site that routes its links
      // itself doesn't act on the click first.
      addEventListener('click', event => {
        if (!event.isTrusted || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || !open.size) return;
        const link = event.composedPath().find(node => (node instanceof HTMLAnchorElement || node instanceof HTMLAreaElement) && node.href);
        if (!link || link.hasAttribute('download') || !open.has(link.href)) return;
        event.preventDefault(); event.stopImmediatePropagation();
        riseHandlers.riseOpenTabLink.postMessage(link.href);
      }, true);
    })();
    """#
}

@MainActor extension BrowserController {
    /// Links open in tabs other than `page`'s, leaving out the address it's on: a link to the page
    /// itself behaves as usual.
    func linksOpenElsewhere(than page: WebPage) -> [String] {
        let own = page.url?.absoluteString
        var links: [String] = []
        for tab in tabs where tab.page !== page {
            guard let link = tab.url?.absoluteString, link != own, !links.contains(link) else { continue }
            links.append(link)
        }
        return links
    }
    /// The tab a clicked link is already open in, other than the one it was clicked in.
    func goToOpenTab(_ url: URL, from page: WebPage) {
        guard let tab = tabs.first(where: { $0.page !== page && $0.url?.absoluteString == url.absoluteString }) else { return }
        select(tab.id)
    }
    /// Pages on screen: the selected tab's, the other half of a split, and a Peek's.
    var shownPages: [WebPage] { tabs.filter { visibleTabIDs.contains($0.id) }.map(\.page) + [peekTab?.page].compactMap { $0 } }
}
