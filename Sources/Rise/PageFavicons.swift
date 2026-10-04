import WebKit

@MainActor extension BrowserController {
    func discoverPageFavicon(_ web: WKWebView) {
        guard let pageURL = web.url else { return }
        // Read the real page's declared icon, including icons hosted on a CDN.
        // Prefer raster icons that AppKit can decode, with /favicon.ico as fallback.
        let script = """
        (() => {
          const icons = Array.from(document.querySelectorAll('link[rel]')).filter(link =>
            link.rel.toLowerCase().split(/\\s+/).includes('icon') || link.rel.toLowerCase() === 'apple-touch-icon');
          icons.sort((a, b) => Number(/svg/i.test(a.type + a.href)) - Number(/svg/i.test(b.type + b.href)));
          return icons.length ? icons[0].href : null;
        })()
        """
        web.evaluateJavaScript(script) { [weak self, weak web] result, _ in
            guard let self, let web, web.url == pageURL, self.tabs.contains(where: { $0.webView === web }),
                  let address = result as? String, let iconURL = URL(string: address) else { return }
            self.suggestionFavicons.loadPageIcon(iconURL, for: pageURL)
        }
    }
}
