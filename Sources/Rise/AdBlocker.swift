import Foundation
import RiseChromium

/// Ads, blocked by uBlock Origin, which Rise carries (scripts/build.sh) and the engine loads as
/// one of Chrome's own extensions; turned off, the engine unloads it.
@MainActor final class AdBlocker {
    static let preferenceKey = "Rise.AdBlocking"
    private let preferences: UserDefaults
    static let allowedSitesKey = "Rise.AdBlockAllowedSites"
    private(set) var enabled: Bool
    /// Sites left unblocked with everywhere else blocked; uBlock Origin keeps them too.
    private(set) var allowedSites: Set<String>
    /// The last load or unload, which anything needing uBlock Origin waits for.
    private(set) var change: Task<Void, Error>?
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        allowedSites = Set(preferences.stringArray(forKey: Self.allowedSitesKey) ?? [])
        enabled = preferences.object(forKey: Self.preferenceKey) == nil || preferences.bool(forKey: Self.preferenceKey)
        RCAdBlock.enabled = enabled
    }
    /// Turns blocking on or off; the task ends once uBlock Origin is loaded or unloaded to match.
    func setEnabled(_ value: Bool) -> Task<Void, Error> {
        enabled = value; preferences.set(value, forKey: Self.preferenceKey)
        let change = Task<Void, Error> { await withCheckedContinuation { done in RCAdBlock.setEnabled(value) { done.resume() } } }
        self.change = change
        return change
    }
    /// A page's site, as uBlock Origin's list names one: its host without any `www.`, which covers
    /// the subdomains under it. Only web pages have one, as only they have ads to block.
    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    /// The entry leaving a page unblocked, its own site's or one above it.
    func allowedSite(for url: URL?) -> String? {
        guard var site = Self.site(of: url) else { return nil }
        while !allowedSites.contains(site) {
            guard let dot = site.firstIndex(of: ".") else { return nil }
            site = String(site[site.index(after: dot)...])
        }
        return site
    }
    func isBlocking(on url: URL?) -> Bool { enabled && allowedSite(for: url) == nil }
    func setAllowed(_ allowed: Bool, site: String) {
        if allowed { allowedSites.insert(site) } else { allowedSites.remove(site) }
        preferences.set(allowedSites.sorted(), forKey: Self.allowedSitesKey)
    }
    /// uBlock Origin's list of trusted sites, which its own pages alone can reach, with `site`
    /// added or taken out and every other entry left as it is.
    static let allowlistScript = """
        const work = (async () => {
          while (!window.vAPI?.messaging) await new Promise(ready => setTimeout(ready, 50));
          const { whitelist } = await vAPI.messaging.send('dashboard', { what: 'getWhitelist' });
          const lines = whitelist.filter(line => line !== site);
          if (allowed) lines.push(site);
          await vAPI.messaging.send('dashboard', { what: 'setWhitelist', whitelist: lines.join('\\n') });
          return true;
        })();
        return Promise.race([work, new Promise((_, fail) => setTimeout(() => fail(new Error('uBlock Origin didn’t answer')), 10000))]);
        """
    static let allowlistPage = URL(string: "chrome-extension://mehgmpfnbopgodfmhbkfhkghemcgpeci/whitelist.html")!
}
