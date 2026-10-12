import AppKit

@MainActor extension BrowserController {
    func discoverPageFavicon(_ web: WebPage) {
        guard let pageURL = web.url else { return }
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
              return Number(themed(b))-Number(themed(a)) || (dark ? Number(svg(b))-Number(svg(a)) : Number(svg(a))-Number(svg(b)));
            });
            return eligible.length ? eligible[0].href : null;
          }
          return { light: choose(false), dark: choose(true) };
        })()
        """
        web.evaluate(script, arguments: [:], in: nil, world: .page) { [weak self, weak web] result in
            guard let self, let web, web.url == pageURL, self.tabs.contains(where: { $0.page === web }),
                  let icons = (try? result.get()) as? [String: Any] else { return }
            let light = FaviconDiscovery.lightIcon(for: pageURL) ?? (icons["light"] as? String).flatMap(URL.init(string:))
            let dark = FaviconDiscovery.darkIcon(for: pageURL) ?? (icons["dark"] as? String).flatMap(URL.init(string:))
            if let light { self.suggestionFavicons.loadPageIcon(light, for: pageURL) }
            if let dark, dark != light { self.suggestionFavicons.loadPageIcon(dark, for: pageURL, dark: true) }
        }
    }
}
