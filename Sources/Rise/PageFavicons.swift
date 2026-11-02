import AppKit

@MainActor extension BrowserController {
    static func siteIcon(_ page: URL) -> URL? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false), ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        parts.user = nil; parts.password = nil; parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        return parts.url
    }
    /// An icon fetched by the page, with its sign-in and from its cache: nil for one on another
    /// site that doesn't allow it, or past a megabyte.
    static func pageIconBytes(_ icon: URL, in web: WebPage) async -> Data? {
        let encoded = await web.evaluate("""
            const response = await fetch(url, { credentials: 'include', cache: 'force-cache' });
            if (!response.ok) return null;
            const bytes = new Uint8Array(await response.arrayBuffer());
            if (bytes.length > 1000000) return null;
            let text = '';
            for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            return btoa(text);
            """, arguments: ["url": icon.absoluteString], world: nil) as? String
        return encoded.flatMap { Data(base64Encoded: $0) }
    }
    /// A tab arriving on a site whose icon is already known takes it at once: the icon is
    /// fetched only once per site and handed to the tabs there then, and a site's own
    /// /favicon.ico may be behind its sign-in, as Jira's is.
    func adoptKnownFavicon(for web: WebPage, at pageURL: URL) {
        guard let tab = (tabs + allPeekTabs).first(where: { $0.page === web }), let origin = SitePermissions.origin(pageURL) else { return }
        var changed = false
        if tab.favicon == nil || tab.iconOrigin != origin, let known = suggestionFavicons.image(for: pageURL, fetch: false) {
            tab.iconTask?.cancel(); tab.iconTask = nil; tab.iconOrigin = origin; tab.favicon = known; changed = true
        }
        if tab.darkFavicon == nil, let dark = suggestionFavicons.cachedDarkImage(for: pageURL) { tab.darkFavicon = dark; changed = true }
        if changed { update() }
    }
    /// `again` is the second look, a moment after loading, for an app that adds its icon in
    /// JavaScript once it has started.
    func discoverPageFavicon(_ web: WebPage, again: Bool = false) {
        guard let pageURL = web.url else { return }
        adoptKnownFavicon(for: web, at: pageURL)
        // Read the real page's declared icon, including icons hosted on a CDN.
        // Keep both appearances; an icon can use media links or SVG media rules.
        let script = """
        return (() => {
          const icons = Array.from(document.querySelectorAll('link[rel]')).filter(link =>
            link.rel.toLowerCase().split(/\\s+/).includes('icon') || link.rel.toLowerCase() === 'apple-touch-icon');
          function choose(dark) {
            const eligible = icons.filter(link => {
              const media = link.media.replace(/\\(\\s*prefers-color-scheme\\s*:\\s*(dark|light)\\s*\\)/gi,
                (_, mode) => (mode.toLowerCase() === 'dark') === dark ? '(min-width: 0px)' : '(max-width: -1px)');
              return !media || matchMedia(media).matches;
            });
            eligible.sort((a, b) => {
              const themed = link => /prefers-color-scheme/i.test(link.media);
              const svg = link => /svg/i.test(link.type + link.href);
              const pixels = link => Math.max(0, ...Array.from(link.sizes).map(size => {
                const match = /^(\\d+)x(\\d+)$/i.exec(size);
                return match ? Math.min(Number(match[1]), Number(match[2])) : 0;
              }));
              return Number(themed(b))-Number(themed(a)) || (dark ? Number(svg(b))-Number(svg(a)) : Number(svg(a))-Number(svg(b))) || pixels(b)-pixels(a);
            });
            return eligible.length ? eligible[0].href : null;
          }
          return { light: choose(false), dark: choose(true) };
        })()
        """
        web.evaluate(script, arguments: [:], in: nil, world: .page) { [weak self, weak web] result in
            guard let self, let web, web.url == pageURL, (self.tabs + self.allPeekTabs).contains(where: { $0.page === web }),
                  let icons = (try? result.get()) as? [String: Any] else { return }
            let declared = (icons["light"] as? String).flatMap(URL.init(string:)).map(FaviconDiscovery.preferred)
            if declared == nil, !again {
                DispatchQueue.main.asyncAfter(deadline: .now()+2) { [weak self, weak web] in
                    guard let self, let web, web.url == pageURL else { return }
                    self.discoverPageFavicon(web, again: true)
                }
            }
            // None declared: the site's /favicon.ico, as Chrome asks for it, with the page's sign-in.
            let light = FaviconDiscovery.lightIcon(for: pageURL) ?? declared ?? (again ? Self.siteIcon(pageURL) : nil)
            let dark = FaviconDiscovery.darkIcon(for: pageURL) ?? (icons["dark"] as? String).flatMap(URL.init(string:)).map(FaviconDiscovery.preferred)
            let throughPage: (URL) async -> Data? = { [weak web] icon in
                guard let web, web.url == pageURL else { return nil }
                return await Self.pageIconBytes(icon, in: web)
            }
            if let light { self.suggestionFavicons.loadPageIcon(light, for: pageURL, throughPage: throughPage) }
            if let dark, dark != light { self.suggestionFavicons.loadPageIcon(dark, for: pageURL, dark: true, throughPage: throughPage) }
        }
    }
}
