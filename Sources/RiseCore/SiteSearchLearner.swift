import Foundation
#if os(iOS)
import WebKit

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
#endif

/// Learns how a site searches: when a search typed into a page leads to an address holding
/// those words, that address becomes the site's search, which Tab then offers in the address bar.
@MainActor public final class SiteSearchLearner {
    public static let worldName = "Rise.SiteSearch"
    #if os(iOS)
    public static let world = WKContentWorld.world(name: worldName)
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    #endif
    /// How long after a search the page has to get to its results.
    public static let window: TimeInterval = 15
    public let searches: LearnedSearches
    /// A search made in a page, waiting for the page to get to its results.
    private struct Pending { weak var page: AnyObject?; let terms: [String], name: String?, until: Date }
    private var pending: [ObjectIdentifier: Pending] = [:]
    public var onLearn: (() -> Void)?

    public init(storageURL: URL) { searches = LearnedSearches(storageURL: storageURL) }
    #if os(iOS)
    public func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        // window.open can supply a configuration sharing the opener's controller.
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(SiteSearchBridge(self), contentWorld: Self.world, name: "riseSiteSearch")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
    }
    public func searched(_ terms: [String], name: String?, in webView: WKWebView) {
        searched(terms, name: name, in: webView, url: webView.url)
    }
    public func addressChanged(_ webView: WKWebView) { addressChanged(webView, url: webView.url) }
    #endif
    /// A search in any engine's page, which is at `url` now.
    public func searched(_ terms: [String], name: String?, in page: AnyObject, url: URL?) {
        pending = pending.filter { $0.value.page != nil && $0.value.until > Date() }
        pending[ObjectIdentifier(page)] = Pending(page: page, terms: terms, name: name, until: Date().addingTimeInterval(Self.window))
        addressChanged(page, url: url)
    }
    /// The page's address changed, by loading or by script: does it hold what was just searched for?
    public func addressChanged(_ page: AnyObject, url: URL?) {
        let id = ObjectIdentifier(page)
        guard let search = pending[id] else { return }
        guard search.page === page, search.until > Date() else { pending[id] = nil; return }
        guard let url, searches.learn(from: url, terms: search.terms, name: search.name) else { return }
        pending[id] = nil; onLearn?()
    }

    /// Posts the words in a page's search field when it's searched with Enter, a form or a button.
    /// Fields for sign-ins and personal details are left alone.
    public static let script = #"""
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
