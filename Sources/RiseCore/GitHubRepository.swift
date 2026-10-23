import Foundation

/// A repository on github.com, from a link to it or to any of its pages.
public struct GitHubRepository: Equatable, Sendable {
    public let owner: String, name: String
    public var path: String { "\(owner)/\(name)" }
    /// GitHub's own pages where a repository's owner would be, which aren't repositories.
    static let reserved: Set<String> = [
        "about", "account", "apps", "blog", "codespaces", "collections", "contact", "customer-stories", "dashboard",
        "enterprise", "events", "explore", "features", "issues", "join", "login", "logout", "marketplace", "new",
        "notifications", "orgs", "organizations", "pricing", "pulls", "readme", "search", "security", "sessions",
        "settings", "site", "sponsors", "stars", "team", "topics", "trending", "users", "watching", "signup"]
    public init?(url: URL?) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              url.port == nil || (url.scheme?.lowercased() == "https" ? url.port == 443 : url.port == 80),
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? "" }
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        // GitHub's names: letters, digits, hyphens; repositories also take dots and underscores.
        let owner = parts[0]
        guard !Self.reserved.contains(owner.lowercased()), !parts.contains("."), !parts.contains(".."), name != ".", name != "..",
              owner.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil,
              name.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        self.owner = owner; self.name = name
    }
}

/// Shared DOM actions for GitHub’s own authenticated Star control.
public enum GitHubStarScripts {
    /// On the repository's own page, what both button scripts share: GitHub's Star button, and
    /// whether the page shows the repository starred.
    private static let buttonHelpers = """
          const sleep = ms => new Promise(done => setTimeout(done, ms));
          const shown = el => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
          const label = el => `${el.getAttribute('aria-label') || ''} ${el.textContent || ''}`.replace(/\\s+/g, ' ').trim();
          const controls = () => [...document.querySelectorAll('button, input[type=submit], a[role=button], summary')].filter(shown);
          const repository = '/' + location.pathname.split('/').filter(Boolean).slice(0, 2).join('/').toLowerCase();
          const action = el => {
            const form = el.closest('form'); if (!form) return null;
            try { const url = new URL(form.getAttribute('action') || '', location.href);
              return url.origin === location.origin ? url.pathname.toLowerCase() : ''; } catch { return ''; }
          };
          const inHeader = el => !!el.closest('.pagehead-actions, #repository-details-container, [data-testid="repository-header"]');
          const namesRepository = (el, verb) => {
            const text = (el.getAttribute('aria-label') || '').trim().toLowerCase();
            const prefix = verb + ' ' + repository.slice(1);
            return text === prefix || text.startsWith(prefix + ' ');
          };
          const isStar = el => action(el) !== null ? action(el) === repository + '/star'
            : namesRepository(el, 'star') || /^star this repository\\b/i.test(label(el)) || (inHeader(el) && /^star\\b/i.test(label(el)));
          const isUnstar = el => action(el) !== null ? action(el) === repository + '/unstar'
            : namesRepository(el, 'unstar') || namesRepository(el, 'starred') || /^unstar this repository\\b/i.test(label(el)) || (inHeader(el) && /^(unstar|starred)\\b/i.test(label(el)));
          const state = () => {
            const container = [...document.querySelectorAll('.starring-container, .js-toggler-container')].find(c => [...c.querySelectorAll('button,input[type=submit]')].some(isStar));
            if (container) return container.classList.contains('on') ? 'on' : 'off';
            if (controls().some(isUnstar)) return 'on';
            return controls().some(isStar) ? 'off' : null;
          };
        """
    /// Default star scripts remain source compatible with the desktop browser.
    public static let find = find(starred: true)
    public static let press = press(starred: true)

    /// Read-only status detection also marks the requested control for a later explicit action.
    public static func find(starred desired: Bool) -> String {
        let target = desired ? "on" : "off", already = desired ? "already" : "alreadyUnstarred"
        let predicate = desired ? "isStar" : "isUnstar"
        return """
        return (async () => { try {
        \(buttonHelpers)
          if (/^page not found/i.test(document.title)) return { status: 'notFound' };
          if (!document.querySelector('meta[name="user-login"]')?.content) return { status: 'signedOut' };
          const until = Date.now() + 8000;
          while (!state() && Date.now() < until) await sleep(200);
          if (state() === '\(target)') return { status: '\(already)' };
          const button = controls().find(\(predicate));
          if (!button || button.disabled) return { status: 'failed', detail: 'repository control unavailable' };
          document.querySelectorAll('[data-rise-star]').forEach(el => el.removeAttribute('data-rise-star'));
          button.setAttribute('data-rise-star', '');
          return { status: 'ready', form: !!button.closest('form') };
        } catch (error) { return { status: 'failed', detail: `script: ${error}` }; } })();
        """
    }
    /// In the page's own world, where React keeps its props on the elements it drew.
    public static let wired = """
        const button = document.querySelector('[data-rise-star]');
        return !!button && [button, button.parentElement].some(el => el && Object.keys(el).some(key => key.startsWith('__reactProps')));
        """
    /// Performs exactly the requested action, never toggles an already satisfied state.
    public static func press(starred desired: Bool) -> String {
        let target = desired ? "on" : "off", already = desired ? "already" : "alreadyUnstarred"
        let success = desired ? "starred" : "unstarred", predicate = desired ? "isStar" : "isUnstar"
        return """
        return (async () => { try {
        \(buttonHelpers)
          if (state() === '\(target)') return { status: '\(already)' };
          const button = document.querySelector('[data-rise-star]');
          if (!button || button.disabled || !\(predicate)(button)) return { status: 'failed', detail: 'the requested control changed' };
          button.click();
          const until = Date.now() + 10000;
          while (state() !== '\(target)' && Date.now() < until) await sleep(200);
          return state() === '\(target)' ? { status: '\(success)' } : { status: 'failed', detail: 'the requested state was not reached' };
        } catch (error) { return { status: 'failed', detail: `script: ${error}` }; } })();
        """
    }
}
