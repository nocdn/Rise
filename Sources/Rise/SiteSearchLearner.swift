import AppKit
import WebKit
import RiseCore

// A separate content world keeps the search bridge out of the site's JavaScript.
@MainActor private final class SiteSearchBridge: NSObject, WKScriptMessageHandler {
    weak var learner: SiteSearchLearner?
    init(_ learner: SiteSearchLearner) { self.learner = learner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView, let body = message.body as? [String: Any],
              let terms = body["terms"] as? [String] else { return }
        learner?.searched(terms.prefix(6).map { String($0.prefix(200)) }, name: body["name"] as? String, in: webView)
    }
}

/// Learns how a site searches: when a search typed into a page leads to an address holding
/// those words, that address becomes the site's search, which Tab then offers in the address bar.
@MainActor final class SiteSearchLearner {
    static let world = WKContentWorld.world(name: "Rise.SiteSearch")
    /// How long after a search the page has to get to its results.
    static let window: TimeInterval = 15
    let searches: LearnedSearches
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private struct Pending { weak var webView: WKWebView?; let terms: [String], name: String?, until: Date }
    private var pending: [ObjectIdentifier: Pending] = [:]
    var onLearn: (() -> Void)?

    init(storageURL: URL) { searches = LearnedSearches(storageURL: storageURL) }
    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        // window.open can supply a configuration sharing the opener's controller.
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(SiteSearchBridge(self), contentWorld: Self.world, name: "riseSiteSearch")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
    }
    func searched(_ terms: [String], name: String?, in webView: WKWebView) {
        pending[ObjectIdentifier(webView)] = Pending(webView: webView, terms: terms, name: name, until: Date().addingTimeInterval(Self.window))
        addressChanged(webView)
    }
    /// The page's address changed, by loading or by script: does it hold what was just searched for?
    func addressChanged(_ webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        guard let search = pending[id] else { return }
        guard search.webView === webView, search.until > Date() else { pending[id] = nil; return }
        guard let url = webView.url, searches.learn(from: url, terms: search.terms, name: search.name) else { return }
        pending[id] = nil; onLearn?()
    }

    /// Posts the words in a page's search field when it's searched with Enter, a form or a button.
    /// Fields for sign-ins and personal details are left alone.
    static let script = #"""
    (() => {
      if (window.riseSiteSearch) return;
      window.riseSiteSearch = true;
      const personal = /user|login|mail|pass|card|phone|otp|zip|postal/i;
      const searchable = el => (el instanceof HTMLTextAreaElement ||
          (el instanceof HTMLInputElement && (el.type === 'text' || el.type === 'search'))) &&
        !personal.test([el.autocomplete, el.name, el.id].join(' '));
      const words = fields => [...new Set(fields.filter(searchable).map(el => el.value.trim())
        .filter(value => value && value.length <= 200))].slice(0, 6);
      const siteName = () => document.querySelector('meta[property="og:site_name"]')?.content ||
        document.querySelector('meta[name="application-name"]')?.content || '';
      const post = terms => {
        if (terms.length) webkit.messageHandlers.riseSiteSearch.postMessage({ terms, name: siteName() });
      };
      const fields = root => [...root.querySelectorAll('input, textarea')];
      addEventListener('keydown', event => {
        if (event.key === 'Enter' && !event.isComposing) post(words([event.composedPath()[0]]));
      }, true);
      addEventListener('submit', event => post(words(fields(event.target))), true);
      addEventListener('click', event => {
        const button = event.composedPath().find(node => node instanceof Element &&
          node.matches('button, [role=button], input[type=submit], input[type=image]'));
        if (!button) return;
        const form = button.closest('form');
        post(words(form ? fields(form) : fields(document).filter(el =>
          el.type === 'search' || /^(searchbox|combobox)$/.test(el.getAttribute('role') || ''))));
      }, true);
    })();
    """#
}
