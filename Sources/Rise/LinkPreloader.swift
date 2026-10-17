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
        return target?.url != origin?.url && !looksLikeAnAction(url)
    }

    // MARK: Smart filter

    /// Words naming something a link does rather than a page it shows: loading one ahead could sign
    /// out, delete, vote, buy, or spend a one-time link. Missing out on a preload costs little, so
    /// the list leans wide. Matched against whole words, and pairs and triples run together, so
    /// "sign-out", "signOut" and "add_to_cart" are caught as well as "logout".
    nonisolated static let actionWords: Set<String> = [
        // Signing out, in English and the languages Rise is most used in.
        "logout", "logoff", "signout", "signoff", "loggaut", "abmelden", "ausloggen", "deconnexion", "deconnecter",
        "cerrarsesion", "wyloguj", "wylogowanie", "wylogujsie", "uitloggen", "esci", "disconnetti",
        // Removing things, and taking back access.
        "delete", "remove", "destroy", "erase", "purge", "trash", "discard", "revoke", "deactivate", "disable",
        "disconnect", "unlink", "unpair", "deauthorize", "usun", "loschen", "entfernen", "supprimer", "eliminar", "borrar",
        "rimuovi", "elimina", "verwijderen", "kasuj", "wypisz",
        // Leaving, cancelling and unsubscribing.
        "unsubscribe", "unsub", "optout", "cancel", "leave", "abbestellen", "desabonner", "desinscribir", "anuluj", "rezygnuj",
        // Votes, follows and other marks on someone else's page. Words as common in addresses of pages
        // ("star", "report", "block") are left to the one-time keys such links carry.
        "vote", "upvote", "downvote", "unvote", "unlike", "dislike", "unfollow", "subscribe", "fave", "unfave",
        "favorite", "favourite", "unfavorite", "unfavourite", "unstar", "unbookmark", "unblock", "mute", "unmute", "unhide", "unflag",
        // Answering requests and changing state.
        "approve", "reject", "accept", "decline", "confirm", "verify", "verification", "activate", "activation", "reset",
        "restore", "undo", "clear", "empty", "dismiss", "snooze", "toggle", "markread", "markasread", "markallread",
        "markunread", "markallasread", "markseen", "submit", "publish", "unpublish", "impersonate", "sudo",
        // Paying.
        "checkout", "purchase", "buynow", "pay", "paynow", "addtocart", "addtobasket", "addtobag", "placeorder",
        "oneclick",
        // Signing in elsewhere, which a preload could complete or spend.
        "oauth", "oauth2", "authorize", "authorise", "callback", "sso", "saml", "openid", "magiclink",
        // Files, which download rather than open.
        "download",
    ]
    /// Query keys holding a one-time or secret value, which says the link acts for the user.
    nonisolated static let secretKeys: Set<String> = [
        "auth", "token", "csrf", "xsrf", "nonce", "wpnonce", "sig", "signature", "otp", "hmac", "ticket", "magic", "key",
        "accesstoken", "idtoken", "authtoken", "authenticitytoken", "csrftoken", "xsrftoken", "requestverificationtoken",
        "confirmationtoken", "resettoken", "invitetoken", "unsubscribetoken", "sessionid",
    ]
    /// Files that download rather than show a page.
    nonisolated static let fileExtensions: Set<String> = [
        "zip", "dmg", "pkg", "exe", "msi", "iso", "img", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "deb",
        "rpm", "appimage", "mp4", "mov", "mkv", "avi", "webm", "mp3", "wav", "flac", "m4a", "pdf", "psd", "torrent", "ics", "vcf",
    ]
    /// A word's lowercase parts, split at punctuation and camel case, without accents.
    nonisolated static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var words: [String] = [], current = ""
        var previous: Character?
        for character in folded {
            if character.isLetter || character.isNumber {
                // camelCase starts a new word.
                if let previous, (previous.isLowercase && character.isUppercase) { words.append(current); current = "" }
                current.append(character)
            } else if !current.isEmpty { words.append(current); current = "" }
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }
    /// Whether `words` hold an action word, alone or run together with the next one or two.
    nonisolated static func namesAnAction(_ words: [String]) -> Bool {
        for index in words.indices {
            if actionWords.contains(words[index]) { return true }
            if index+1 < words.count, actionWords.contains(words[index]+words[index+1]) { return true }
            if index+2 < words.count, actionWords.contains(words[index]+words[index+1]+words[index+2]) { return true }
        }
        // "mark all as read", "mark-spam" and the like.
        return words.contains("mark") && !Set(words).isDisjoint(with: ["read", "unread", "seen", "unseen", "spam", "done", "complete"])
    }
    /// A link that does something rather than shows a page: signing out, deleting, voting,
    /// confirming, paying, a one-time or signed link, an OAuth step, or a file to download.
    nonisolated static func looksLikeAnAction(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        let path = parts.percentEncodedPath.removingPercentEncoding ?? parts.percentEncodedPath
        let segments = path.split(separator: "/").map(String.init)
        if let last = segments.last, let dot = last.lastIndex(of: "."),
           fileExtensions.contains(last[last.index(after: dot)...].lowercased()) { return true }
        if namesAnAction(segments.flatMap(words)) { return true }
        let items = parts.queryItems ?? []
        let keys = items.map { $0.name.lowercased().filter { $0.isLetter || $0.isNumber } }
        if keys.contains(where: { key in secretKeys.contains(key) || key.hasSuffix("token") || key.hasSuffix("nonce") || key.hasPrefix("csrf") }) { return true }
        // An OAuth or sign-in redirect hands over a code with its state.
        if keys.contains("code") && keys.contains("state") { return true }
        // The keys, and values naming the action, as in ?action=delete or ?logout.
        if namesAnAction(items.flatMap { words($0.name) }) { return true }
        let actionKeys: Set<String> = ["action", "do", "cmd", "command", "op", "operation", "method", "task", "mode", "act", "how", "type"]
        if items.contains(where: { actionKeys.contains($0.name.lowercased()) && namesAnAction(words($0.value ?? "")) }) { return true }
        // A method other than GET, spelled out in the address.
        return items.contains { ["method", "_method"].contains($0.name.lowercased()) && $0.value?.lowercased() != "get" }
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

    static let hoverScript = hoverScriptSource.replacingOccurrences(of: "ACTION_WORDS",
        with: "[" + actionWords.sorted().map { "'\($0)'" }.joined(separator: ",") + "]")
    private static let hoverScriptSource = #"""
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
        // The smart filter's element half: links that say they act, by their words or by asking
        // for another method or a confirmation, as Rails and Turbo links do. Rise checks the address.
        const actionWords = new Set(ACTION_WORDS);
        const words = text => (text || '').slice(0, 200).normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
            .replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
        const namesAnAction = list => list.some((word, i) => actionWords.has(word) ||
            (i+1 < list.length && actionWords.has(word+list[i+1])) ||
            (i+2 < list.length && actionWords.has(word+list[i+1]+list[i+2])));
        const acts = link => {
            const method = (link.dataset.method || link.dataset.turboMethod || link.dataset.httpMethod || 'get').toLowerCase();
            if (method !== 'get') return true;
            if (link.hasAttribute('data-confirm') || link.hasAttribute('data-turbo-confirm')) return true;
            const said = [link.innerText, link.getAttribute('aria-label'), link.title, link.id,
                typeof link.className === 'string' ? link.className : ''].join(' ');
            return namesAnAction(words(said));
        };
        const eligible = link => {
            if (!link || link.hasAttribute('download') || acts(link)) return null;
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
