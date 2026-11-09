import WebKit

/// Public WebKit APIs restore a native archive locally. A portable history from Chromium
/// needs native Back/Forward entries too: private, single-origin placeholders redirect with
/// location.replace, so no historical website is loaded just to recreate its entry.
@MainActor enum MobileTabHistory {
    static let scheme = "rise-history"
    nonisolated static let maximumStateBytes = 2_000_000

    static func configure(_ configuration: WKWebViewConfiguration) {
        // WebKit supplies an inherited handler when creating a popup window.
        if configuration.urlSchemeHandler(forURLScheme: scheme) == nil {
            configuration.setURLSchemeHandler(HistorySchemeHandler(), forURLScheme: scheme)
        }
        configuration.userContentController.addUserScript(WKUserScript(source: #"""
        (() => {
          const changed = () => setTimeout(() => window.webkit.messageHandlers.riseTabHistoryChanged.postMessage(null), 0);
          for (const name of ['pushState', 'replaceState']) {
            const original = History.prototype[name];
            History.prototype[name] = function(...args) { const result = Reflect.apply(original, this, args); changed(); return result; };
          }
          addEventListener('popstate', changed); addEventListener('hashchange', changed);
        })();
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    static func observe(_ page: WKWebView, changed: @escaping () -> Void) {
        let controller = page.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "riseTabHistoryChanged")
        controller.add(HistoryChangeHandler(changed), name: "riseTabHistoryChanged")
    }

    static func entry(for url: URL) -> TabNavigationHistory.Entry? {
        guard url.scheme == scheme, let fragment = url.fragment,
              fragment.utf8.count < 16_384, let data = Data(base64Encoded: fragment),
              let entry = try? JSONDecoder().decode(TabNavigationHistory.Entry.self, from: data),
              TabNavigationHistory.allows(entry.url) else { return nil }
        return entry
    }

    static func snapshot(of page: WKWebView) -> TabNavigationHistory? {
        let list = page.backForwardList
        guard let current = list.currentItem else { return nil }
        let items = list.backList + [current] + list.forwardList
        let entries = items.map { item in
            entry(for: item.url) ?? .init(url: item.url.absoluteString, title: item.title)
        }
        return TabNavigationHistory(entries: entries, index: list.backList.count).validated()
    }

    static func restore(_ history: TabNavigationHistory, in page: WKWebView) -> WKNavigation? {
        guard let handler = page.configuration.urlSchemeHandler(forURLScheme: scheme) as? HistorySchemeHandler,
              let history = history.validated() else { return nil }
        handler.bootstrap = history
        return page.load(URLRequest(url: handler.baseURL))
    }

    static func cancelRestore(in page: WKWebView) {
        (page.configuration.urlSchemeHandler(forURLScheme: scheme) as? HistorySchemeHandler)?.bootstrap = nil
    }

    static func permits(_ url: URL, in page: WKWebView) -> Bool {
        (page.configuration.urlSchemeHandler(forURLScheme: scheme) as? HistorySchemeHandler)?.permits(url) == true
    }

    /// Called only for internal documents; all history mutations run as native-injected
    /// user-initiated script so WebKit does not skip them as unsolicited pushState entries.
    static func finishInternalDocument(in page: WKWebView) {
        guard let handler = page.configuration.urlSchemeHandler(forURLScheme: scheme) as? HistorySchemeHandler,
              let history = handler.bootstrap else { return }
        handler.bootstrap = nil
        let urls = history.entries.compactMap { item -> String? in
            guard let data = try? JSONEncoder().encode(item) else { return nil }
            return handler.baseURL.absoluteString + "#" + data.base64EncodedString()
        }
        guard urls.count == history.entries.count, let data = try? JSONEncoder().encode(urls),
              let json = String(data: data, encoding: .utf8) else { return }
        page.evaluateJavaScript("""
        (() => {
          const urls = \(json);
          history.replaceState({}, '', urls[0]);
          for (let i = 1; i < urls.length; i++) history.pushState({}, '', urls[i]);
          const offset = \(history.index) - (urls.length - 1);
          if (offset) history.go(offset); else window.riseRestoreHistoryEntry();
        })();
        """, completionHandler: nil)
    }
}

@MainActor private final class HistoryChangeHandler: NSObject, WKScriptMessageHandler {
    let changed: () -> Void
    init(_ changed: @escaping () -> Void) { self.changed = changed }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame { changed() }
    }
}

@MainActor private final class HistorySchemeHandler: NSObject, WKURLSchemeHandler {
    let baseURL = URL(string: "rise-history://\(UUID().uuidString.lowercased())/restore")!
    var bootstrap: TabNavigationHistory?
    func permits(_ url: URL) -> Bool { url.scheme == MobileTabHistory.scheme && url.host == baseURL.host && url.path == baseURL.path }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, permits(url) else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let html = #"""
        <!doctype html><meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <script>
        window.riseRestoreHistoryEntry = () => {
          if (!location.hash) return;
          try {
            const bytes = Uint8Array.from(atob(location.hash.slice(1)), c => c.charCodeAt(0));
            const entry = JSON.parse(new TextDecoder().decode(bytes));
            const url = new URL(entry.url);
            if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password) location.replace(url.href);
          } catch (_) {}
        };
        addEventListener('pageshow', window.riseRestoreHistoryEntry);
        addEventListener('popstate', window.riseRestoreHistoryEntry);
        </script>
        """#
        let data = Data(html.utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
