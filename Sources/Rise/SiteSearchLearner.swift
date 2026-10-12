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
        learner?.searched(terms, name: body["name"] as? String, in: webView, url: { [weak webView] in webView?.url })
    }
}

/// Learns how a site searches: when a search typed into a page leads to an address holding
/// those words, that address becomes the site's search, which Tab then offers in the address bar.
@MainActor final class SiteSearchLearner {
    static let worldName = "Rise.SiteSearch"
    static let world = WKContentWorld.world(name: worldName)
    /// How long after a search the page has to get to its results.
    static let window: TimeInterval = 15
    let searches: LearnedSearches
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    /// A search made in a page, as its view, waiting for the page to get to its results.
    private struct Pending { weak var view: NSView?; let terms: [String], name: String?, until: Date }
    /// Pages of engines other than WebKit, which get the script through the page.
    private let pages = NSHashTable<AnyObject>.weakObjects()
    private var pending: [ObjectIdentifier: Pending] = [:]
    var onLearn: (() -> Void)?

    init(storageURL: URL) { searches = LearnedSearches(storageURL: storageURL) }
    func install(on page: WebPage) {
        if let webView = (page as? WebKitPage)?.webView { install(on: webView); return }
        guard !pages.contains(page) else { return }
        pages.add(page)
        page.addMessageHandler("riseSiteSearch", world: .named(Self.worldName)) { [weak self] message in
            guard message.frame.isMain, let page = message.page, let body = message.body as? [String: Any],
                  let terms = body["terms"] as? [String] else { return }
            self?.searched(terms, name: body["name"] as? String, in: page.view, url: { [weak page] in page?.url })
        }
        page.addUserScript(Self.script, world: .named(Self.worldName), mainFrameOnly: true, handlers: ["riseSiteSearch"])
    }
    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        // window.open can supply a configuration sharing the opener's controller.
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(SiteSearchBridge(self), contentWorld: Self.world, name: "riseSiteSearch")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
    }
    func searched(_ terms: [String], name: String?, in view: NSView, url: () -> URL?) {
        let terms = terms.prefix(6).map { String($0.prefix(200)) }
        pending[ObjectIdentifier(view)] = Pending(view: view, terms: terms, name: name, until: Date().addingTimeInterval(Self.window))
        addressChanged(view, url: url())
    }
    /// The page's address changed, by loading or by script: does it hold what was just searched for?
    func addressChanged(_ view: NSView, url: URL?) {
        let id = ObjectIdentifier(view)
        guard let search = pending[id] else { return }
        guard search.view === view, search.until > Date() else { pending[id] = nil; return }
        guard let url, searches.learn(from: url, terms: search.terms, name: search.name) else { return }
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
        // WebKit's handlers, or the ones Rise's script wrapper gives a Chromium page.
        const handlers = typeof riseHandlers !== 'undefined' ? riseHandlers : webkit.messageHandlers;
        if (terms.length) handlers.riseSiteSearch.postMessage({ terms, name: siteName() });
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
