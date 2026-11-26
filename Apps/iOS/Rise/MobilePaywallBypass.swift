import Foundation
import WebKit

/// Reveals article content already present in the main document. Each tab applies the
/// preference for the final host, including when WebKit restores a cached document.
@MainActor final class MobilePaywallBypass {
    private static let preferenceKey = "Rise.iOS.PaywallBypass.EnabledSites"
    private static let world = WKContentWorld.world(name: "Rise.PaywallBypass")
    private static let previouslyEnabled = NSMapTable<WKWebView, NSMutableSet>.weakToStrongObjects()
    private let preferences: UserDefaults?
    private var privateSites = Set<String>()

    init(preferences: UserDefaults?) {
        self.preferences = preferences
    }

    private var enabledSites: Set<String> {
        preferences?.stringArray(forKey: Self.preferenceKey).map(Set.init) ?? privateSites
    }

    func isAvailable(for url: URL?) -> Bool { CookieConsentPolicy.site(url) != nil }

    func isEnabled(for url: URL?) -> Bool {
        guard let site = CookieConsentPolicy.site(url) else { return false }
        return isEnabled(on: site)
    }

    func setEnabled(_ enabled: Bool, for url: URL) {
        guard let site = CookieConsentPolicy.site(url) else { return }
        var sites = enabledSites
        if enabled { sites.insert(site) } else { sites.remove(site) }
        if let preferences { preferences.set(sites.sorted(), forKey: Self.preferenceKey) }
        else { privateSites = sites }
    }

    private func isEnabled(on site: String) -> Bool {
        preferences?.stringArray(forKey: Self.preferenceKey)?.contains(site) ?? privateSites.contains(site)
    }

    /// A nil update skips the WebKit call altogether. A previously enabled site can
    /// retain a stylesheet in the back-forward cache, where it may need to be removed.
    func stylesheetUpdate(for url: URL, in page: WKWebView) -> String? {
        guard let site = CookieConsentPolicy.site(url) else { return nil }
        if !isEnabled(on: site) {
            return Self.previouslyEnabled.object(forKey: page)?.contains(site) == true ? "" : nil
        }
        let sites = Self.previouslyEnabled.object(forKey: page) ?? NSMutableSet()
        sites.add(site)
        Self.previouslyEnabled.setObject(sites, forKey: page)
        return Self.stylesheet(for: site)
    }

    func apply(to page: WKWebView) {
        guard let url = page.url, let host = url.host, let css = stylesheetUpdate(for: url, in: page) else { return }
        page.callAsyncJavaScript(Self.applyStylesheet, arguments: ["host": host, "css": css],
                                 in: nil, in: Self.world, completionHandler: nil)
    }

    private static let applyStylesheet = #"""
    if (!/^https?:$/.test(location.protocol) || document.contentType !== "text/html") return;
    const normalize = host => host.toLowerCase().replace(/\.$/, "");
    if (normalize(location.hostname) !== normalize(host)) return;

    const previous = globalThis.risePaywallSheet;
    if (!css && !previous) return;
    if (previous && globalThis.risePaywallCSS === css && document.adoptedStyleSheets.includes(previous)) return;

    // Constructed sheets work with a site's restrictive inline-style CSP.
    const sheets = document.adoptedStyleSheets.filter(sheet => sheet !== previous);
    if (css) {
        const sheet = new CSSStyleSheet();
        sheet.replaceSync(css);
        sheets.push(sheet);
        globalThis.risePaywallSheet = sheet;
        globalThis.risePaywallCSS = css;
    } else {
        delete globalThis.risePaywallSheet;
        delete globalThis.risePaywallCSS;
    }
    document.adoptedStyleSheets = sheets;
    """#

    static func stylesheet(for hostname: String) -> String {
        let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let rules = siteRules.first { entry in
            entry.domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        return genericRules + (rules?.css ?? "")
    }

    // Require an explicitly marked overlay and existing article paragraphs before hiding
    // a generic gate. CSS also applies when a site inserts the wall after page load.
    private static let overlay = #":is([role="dialog"][data-paywall], [data-testid="paywall-overlay"]):not(dialog)"#
    private static let genericRules = """
    body:has(article p ~ p ~ p) \(overlay):not(:has(article, p ~ p ~ p)) {
        display: none !important;
    }
    :is(html, body):has(article p ~ p ~ p):has(\(overlay)) {
        overflow: auto !important;
    }
    """

    // Selectors adapted from Bypass Paywalls Clean's MIT-licensed filters and Firefox
    // content scripts. Keep rules tied to their publisher and to the affected elements.
    private static let siteRules: [(domains: [String], css: String)] = [
        (["abqjournal.com"], """
        .lab-paywall-locked { max-height: none !important; overflow: visible !important; }
        """),
        (["alternatives-economiques.fr"], """
        #temp-paywall { display: none !important; }
        div[data-ae-poool] { max-height: none !important; overflow: visible !important; }
        """),
        (["artnet.com"], """
        div[id^="issuem-leaky-paywall-"] { display: none !important; }
        div.article-body { display: block !important; }
        """),
        (["asia.nikkei.com"], """
        body.tp-modal-open:has(article p ~ p ~ p) :is(div.tp-modal, div.tp-backdrop) { display: none !important; }
        body.tp-modal-open:has(article p ~ p ~ p):has(div.tp-modal) { overflow: auto !important; }
        """),
        (["capital.fr"], """
        #articleWall-wrapper { display: none !important; }
        #articleWall, #articleWall-paid { display: block !important; max-height: none !important; overflow: visible !important; }
        """),
        (["citywire.com"], """
        body:has(.m-article__body--locked p) :is(registration-widget, div.alert--locked) { display: none !important; }
        .article-locked, .m-article--locked, .m-article__body--locked {
            max-height: none !important; overflow: visible !important; filter: none !important;
        }
        """),
        (["cnn.com"], """
        div[data-component-id="subwall"] { display: none !important; }
        html:has(div[data-component-id="subwall"]), body:has(div[data-component-id="subwall"]) { overflow: auto !important; }
        """),
        (["cronista.com"], """
        div.paywall-chain--show { display: none !important; }
        div.article-body--blurred { filter: none !important; max-height: none !important; overflow: visible !important; }
        """),
        (["diepresse.com"], """
        div.paywall-container { display: none !important; }
        div.premium-content[hidden]:has(p) { display: block !important; }
        """),
        (["elconfidencial.com"], """
        div.newsType__content--closed { max-height: none !important; overflow: visible !important; }
        div#news-body-cc[hidden]:has(p) { display: block !important; }
        """),
        (["elespanol.com"], """
        div.full-suscriptor-container { display: none !important; }
        div.content-not-granted-paywall { max-height: none !important; overflow: visible !important; filter: none !important; }
        """),
        (["foreignaffairs.com"], """
        body:has(.article-dropcap p ~ p ~ p) .paywall { display: none !important; }
        .article-dropcap:has(p) { height: auto !important; }
        """),
        (["foxnews.com"], """
        div.article-gating-wrapper { display: none !important; }
        div[class*="gated-overlay"] {
            filter: none !important; mask-image: none !important; max-height: none !important; overflow: visible !important;
        }
        """),
        (["hotnews.ro"], """
        div.article-single-content[hidden]:has(p) { display: block !important; }
        .hn-paywall { max-height: none !important; overflow: visible !important; }
        """),
        (["ilfattoquotidiano.it"], """
        #ifq-paywall-metered { display: none !important; }
        article[id].cropped { max-height: none !important; overflow: visible !important; mask-image: none !important; }
        """),
        (["telegraph.co.uk"], """
        body:has(article p ~ p ~ p) [class^="subwall"] { display: none !important; }
        """),
        (["tes.com"], """
        body:has(div.tg-paywall-body-overlay p) div.tg-paywall-message { display: none !important; }
        div.tg-paywall-body-overlay { max-height: none !important; overflow: visible !important; mask-image: none !important; }
        """),
        (["theatlantic.com"], """
        body:has(article p ~ p ~ p) aside#paywall { display: none !important; }
        """)
    ]
}
