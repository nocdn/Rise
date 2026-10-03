import AppKit
import WebKit

// A separate content world keeps the hover bridge out of the site's JavaScript.
@MainActor private final class LinkHoverBridge: NSObject, WKScriptMessageHandler {
    weak var preloader: LinkPreloader?
    init(_ preloader: LinkPreloader) { self.preloader = preloader }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let value = message.body as? [String: String] else { return }
        let url = value["url"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if value["kind"] == "hover" { preloader?.onHover?(url, webView) }
        else if value["kind"] == "preload", let url { preloader?.preload(url, from: webView) }
    }
}

@MainActor private final class HoverLoad {
    let url: URL
    let timeout: DispatchWorkItem
    var cacheLifetime: TimeInterval = 0
    init(url: URL, timeout: DispatchWorkItem) { self.url = url; self.timeout = timeout }
}

@MainActor final class LinkPreloader: NSObject, WKNavigationDelegate {
    static let preferenceKey = "Rise.PreloadLinks"
    static let world = WKContentWorld.world(name: "Rise.LinkPreloading")
    private let preferences: UserDefaults
    private let sources = NSHashTable<WKWebView>.weakObjects()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var loads: [WKWebView: HoverLoad] = [:]
    private var recent: [URL: Date] = [:]
    private var readyUntil: [URL: Date] = [:]
    private var completedUntil: [URL: Date] = [:]
    var prepareWebView: ((WKWebView) -> Void)?
    var onHover: ((URL?, WKWebView) -> Void)?
    var onReady: ((URL) -> Void)?
    var onComplete: ((URL) -> Void)?
    private(set) var enabled: Bool
    var activeLoadCount: Int { loads.count }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.bool(forKey: Self.preferenceKey)
        super.init()
    }
    func install(on webView: WKWebView) {
        guard !sources.contains(webView) else { return }
        sources.add(webView)
        let controller = webView.configuration.userContentController
        // window.open can supply a configuration sharing the opener's controller.
        if !controllers.contains(controller) {
            controllers.add(controller)
            controller.add(LinkHoverBridge(self), contentWorld: Self.world, name: "risePreload")
            controller.addUserScript(WKUserScript(source: Self.hoverScript, injectionTime: .atDocumentStart,
                                                 forMainFrameOnly: false, in: Self.world))
        }
        webView.evaluateJavaScript(Self.hoverScript, in: nil, in: Self.world) { _ in }
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        preferences.set(value, forKey: Self.preferenceKey)
        if !value { cancelAll() }
        // The native gate applies immediately to every frame, including frames
        // already loaded before this preference changed.
        for source in sources.allObjects {
            source.evaluateJavaScript("globalThis.riseLinkPreload?.cancel()", in: nil, in: Self.world) { _ in }
        }
    }
    func cancelAll() {
        for (webView, load) in loads { load.timeout.cancel(); webView.stopLoading() }
        loads.removeAll(); recent.removeAll(); readyUntil.removeAll(); completedUntil.removeAll()
    }
    func preload(_ url: URL, from source: WKWebView) {
        guard enabled, source.window != nil, Self.isEligible(url, from: source.url) else { return }
        let url = Self.cacheKey(url)
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        guard recent[url] == nil, loads.count < 2, recent.count < 32 else { return }
        recent[url] = now
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = source.configuration.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: source.bounds, configuration: configuration)
        prepareWebView?(webView)
        webView.navigationDelegate = self
        let timeout = DispatchWorkItem { [weak self, weak webView] in
            if let webView { self?.finish(webView) }
        }
        loads[webView] = HoverLoad(url: url, timeout: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.setValue("prefetch", forHTTPHeaderField: "Purpose")
        request.setValue("prefetch", forHTTPHeaderField: "Sec-Purpose")
        webView.load(request)
    }
    nonisolated static func isEligible(_ url: URL, from source: URL?) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        // Same-document anchors should never start a background navigation.
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var origin = source.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        target?.fragment = nil; origin?.fragment = nil
        return target?.url != origin?.url
    }
    nonisolated static func cacheKey(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil; return parts?.url ?? url
    }
    func isReady(_ url: URL) -> Bool { enabled && (readyUntil[Self.cacheKey(url)] ?? .distantPast) > Date() }
    func isComplete(_ url: URL) -> Bool { enabled && (completedUntil[Self.cacheKey(url)] ?? .distantPast) > Date() }
    private func finish(_ webView: WKWebView, success: Bool = false) {
        guard let load = loads.removeValue(forKey: webView) else { return }
        load.timeout.cancel()
        webView.stopLoading(); webView.navigationDelegate = nil
        if success, enabled {
            completedUntil = completedUntil.filter { $0.value > Date() }
            completedUntil[load.url] = Date().addingTimeInterval(60)
            onComplete?(load.url)
        }
        if success, enabled, load.cacheLifetime > 0 {
            readyUntil = readyUntil.filter { $0.value > Date() }
            readyUntil[load.url] = Date().addingTimeInterval(min(60, load.cacheLifetime))
            onReady?(load.url)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(!action.shouldPerformDownload && ["http", "https"].contains(scheme) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let allowed = response.canShowMIMEType && (response.response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } == true
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
            loads[webView]?.cacheLifetime = Self.cacheLifetime(http)
        }
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { finish(webView) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(webView, success: true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(webView) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(webView) }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Let WebKit validate TLS normally; never prompt for credentials during a hover.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    nonisolated private static func cacheLifetime(_ response: HTTPURLResponse) -> TimeInterval {
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !directives.contains("no-store"), !directives.contains(where: { $0.hasPrefix("no-cache") }),
              let maxAge = directives.first(where: { $0.hasPrefix("max-age=") }),
              let age = Double(maxAge.dropFirst(8).replacingOccurrences(of: "\"", with: "")) else { return 0 }
        return max(0, age - (Double(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0))
    }

    static let hoverScript = #"""
    (() => {
        globalThis.riseLinkPreload?.dispose();
        let timer = null, hovered = null;
        const notify = (kind, url = '') => webkit.messageHandlers.risePreload.postMessage({kind, url});
        const cancel = () => {
            clearTimeout(timer); timer = null;
            if (hovered) notify('hover');
            hovered = null;
        };
        const linkAt = event => event.composedPath().find(node =>
            node instanceof Element && node.matches('a[href], area[href]'));
        const eligible = link => {
            if (!link || link.hasAttribute('download')) return null;
            try {
                const url = new URL(link.href, document.baseURI);
                if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
                const current = new URL(location.href), target = new URL(url);
                current.hash = ''; target.hash = '';
                return current.href === target.href ? null : url.href;
            } catch { return null; }
        };
        const over = event => {
            if (event.pointerType === 'touch') return;
            const link = linkAt(event);
            if (link === hovered) return;
            cancel();
            if (!link) return;
            hovered = link;
            notify('hover', link.href);
            const url = eligible(link);
            if (!url) return;
            timer = setTimeout(() => {
                timer = null;
                if (hovered === link && link.isConnected && eligible(link) === url)
                    notify('preload', url);
            }, 150);
        };
        const out = event => {
            if (hovered && (!event.relatedTarget || !hovered.contains(event.relatedTarget))) cancel();
        };
        const events = [['pointerover', over], ['pointerout', out], ['pointerdown', cancel], ['pagehide', cancel], ['blur', cancel]];
        events.forEach(([name, handler]) => window.addEventListener(name, handler, true));
        globalThis.riseLinkPreload = {
            cancel,
            dispose() { cancel(); events.forEach(([name, handler]) => window.removeEventListener(name, handler, true)); }
        };
    })();
    """#
}
