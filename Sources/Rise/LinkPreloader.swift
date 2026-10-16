import AppKit

/// Preload Links: a link the pointer rests on loads out of sight, without its scripts, into the
/// engine's cache, so opening it is quick.
@MainActor final class LinkPreloader: NSObject {
    static let preferenceKey = "Rise.PreloadLinks"
    static let worldName = "Rise.LinkPreloading"
    private let preferences: UserDefaults
    private var recent: [URL: Date] = [:]
    private var completedUntil: [URL: Date] = [:]
    var onComplete: ((URL) -> Void)?
    private(set) var enabled: Bool
    var activeLoadCount: Int { loads.count }
    private let pages = NSHashTable<AnyObject>.weakObjects()
    /// Loads under way, each with its timeout and how to stop it.
    private var loads: [Int: (timeout: DispatchWorkItem, cancel: () -> Void)] = [:]
    private var nextLoad = 0
    /// Loads `url` out of sight, without its scripts, into the engine's cache, like `page`; nil where
    /// it can't. Calls back with whether the page loaded.
    var loadPage: ((_ url: URL, _ like: WebPage, _ done: @escaping (Bool) -> Void) -> (() -> Void)?)?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.bool(forKey: Self.preferenceKey)
        super.init()
    }
    func install(on page: WebPage) {
        guard !pages.contains(page) else { return }
        pages.add(page)
        page.addMessageHandler("risePreload", world: .named(Self.worldName)) { [weak self] message in
            // The engine itself reports hovers for the link pill; only the dwell matters here.
            guard let self, let page = message.page, let body = message.body as? [String: Any], body["kind"] as? String == "preload",
                  let url = (body["url"] as? String).flatMap(URL.init(string:)) else { return }
            self.preload(url, from: page)
        }
        page.addUserScript(Self.hoverScript, world: .named(Self.worldName), mainFrameOnly: false, handlers: ["risePreload"])
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        preferences.set(value, forKey: Self.preferenceKey)
        if !value { cancelAll() }
        // The setting applies at once to every frame, including frames already loaded.
        for case let page as WebPage in pages.allObjects {
            page.evaluate("globalThis.riseLinkPreload?.cancel()", arguments: [:], in: nil, world: .named(Self.worldName)) { _ in }
        }
    }
    func cancelAll() {
        for (_, load) in loads { load.timeout.cancel(); load.cancel() }
        loads.removeAll(); recent.removeAll(); completedUntil.removeAll()
    }
    func preload(_ url: URL, from source: WebPage) {
        guard enabled, source.view.window != nil, Self.isEligible(url, from: source.url), let loadPage else { return }
        let url = Self.cacheKey(url)
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        guard recent[url] == nil, activeLoadCount < 2, recent.count < 32 else { return }
        recent[url] = now
        nextLoad += 1; let key = nextLoad
        let finish = { [weak self] (success: Bool) in
            guard let self, let load = self.loads.removeValue(forKey: key) else { return }
            load.timeout.cancel(); load.cancel()
            self.complete(url, success: success)
        }
        let timeout = DispatchWorkItem { finish(false) }
        guard let cancel = loadPage(url, source, { finish($0) }) else { recent[url] = nil; return }
        loads[key] = (timeout, cancel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
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
    func isComplete(_ url: URL) -> Bool { enabled && (completedUntil[Self.cacheKey(url)] ?? .distantPast) > Date() }
    /// A finished preload counts for a minute.
    private func complete(_ url: URL, success: Bool) {
        guard success, enabled else { return }
        completedUntil = completedUntil.filter { $0.value > Date() }
        completedUntil[url] = Date().addingTimeInterval(60)
        onComplete?(url)
    }

    static let hoverScript = #"""
    (() => {
        globalThis.riseLinkPreload?.dispose();
        let timer = null, hovered = null;
        const notify = (kind, url = '') => riseHandlers.risePreload.postMessage({kind, url});
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
