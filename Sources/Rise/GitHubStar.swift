import AppKit

@MainActor extension BrowserController {
    /// Stars `repository` as the person signed in to GitHub in Rise, saying so in the blue notice:
    /// a spinner while it's under way, then a star.
    func starGitHubRepository(_ repository: GitHubRepository) {
        let kind = "github-star"
        // It stays while it's under way; what came of it holds as long as other notices do.
        showInfo("Starring repository", image: InfoPlaque.spinnerIcon, hold: .seconds(90), kind: kind)
        Task { [weak self] in
            guard let self else { return }
            switch await self.githubStarrer.star(repository) {
            case .starred: self.showInfo("Starred repository", image: InfoPlaque.starIcon, hold: .seconds(2), kind: kind)
            case .alreadyStarred: self.showInfo("Already starred", image: InfoPlaque.starIcon, hold: .seconds(2), kind: kind)
            case .signedOut:
                self.showInfo("Sign in to GitHub to star repositories", image: InfoPlaque.warningIcon,
                              link: .init(text: "Sign In") { [weak self] in self?.addTab(url: URL(string: "https://github.com/login")!) },
                              hold: .seconds(4), kind: kind)
            case .notFound: self.showInfo("Couldn’t find that repository", image: InfoPlaque.warningIcon, hold: .seconds(3), kind: kind)
            case .failed: self.showInfo("Couldn’t star repository", image: InfoPlaque.warningIcon, hold: .seconds(3), kind: kind)
            }
        }
    }
}

/// A repository on github.com, from a link to it or to any of its pages.
struct GitHubRepository: Equatable {
    let owner: String, name: String
    var path: String { "\(owner)/\(name)" }
    /// GitHub's own pages where a repository's owner would be, which aren't repositories.
    static let reserved: Set<String> = [
        "about", "account", "apps", "blog", "codespaces", "collections", "contact", "customer-stories", "dashboard",
        "enterprise", "events", "explore", "features", "issues", "join", "login", "logout", "marketplace", "new",
        "notifications", "orgs", "organizations", "pricing", "pulls", "readme", "search", "security", "sessions",
        "settings", "site", "sponsors", "stars", "team", "topics", "trending", "users", "watching", "signup"]
    init?(url: URL?) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        // GitHub's names: letters, digits, hyphens; repositories also take dots and underscores.
        let owner = parts[0], allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !Self.reserved.contains(owner.lowercased()), owner.rangeOfCharacter(from: allowed.inverted) == nil,
              !name.isEmpty, name != ".", name != "..", name.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        self.owner = owner; self.name = name
    }
}

/// Stars repositories as the person signed in to GitHub in Rise, as github.com's own Star button
/// does: a github.com page, kept offscreen, reads the repository's page with their session, which
/// says whether they're signed in, whether it's starred, and carries the form's token, and posts
/// that form. One at a time, in order.
@MainActor final class GitHubStarrer {
    enum Outcome: Equatable { case starred, alreadyStarred, signedOut, notFound, failed }
    private var page: WebPage?
    private var queue: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    /// Where the offscreen page lives: a window keeps it running.
    weak var host: NSView?
    static let world = "Rise.GitHub"
    /// Each attempt and what came of it, for finding out why one didn't work.
    static let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rise/github-star.log")
    static func log(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kept short: the last few hundred lines.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 200_000 { try? FileManager.default.removeItem(at: logURL) }
        if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close() }
        else { try? Data(text.utf8).write(to: logURL) }
    }

    func star(_ repository: GitHubRepository) async -> Outcome {
        let previous = queue
        let work = Task { @MainActor [weak self] () -> Outcome in
            await previous?.value
            guard let self else { return .failed }
            return await self.run(repository)
        }
        queue = Task { _ = await work.value }
        return await work.value
    }

    private func run(_ repository: GitHubRepository) async -> Outcome {
        idle?.cancel()
        defer { scheduleTearDown() }
        Self.log("start \(repository.path)")
        guard let page = await githubPage() else { Self.log("\(repository.path): github.com didn't load"); return .failed }
        let arguments = ["owner": repository.owner, "name": repository.name]
        let posted = Self.outcome(await withTimeout(seconds: 20) {
            await page.evaluate(Self.starScript, arguments: arguments, world: Self.world)
        })
        Self.log("\(repository.path) form: \(posted.status)\(posted.detail.map { " (\($0))" } ?? "")")
        if posted.outcome != .failed { return posted.outcome }
        // Whatever the quick way tripped on, GitHub's own Star button, on the repository's page.
        let path = "/\(repository.owner)/\(repository.name)"
        guard let url = URL(string: "https://github.com" + path) else { return .failed }
        page.load(url)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            if page.url?.host == "github.com", !page.isLoading, page.url?.path != "/robots.txt" { break }
        }
        guard page.url?.host == "github.com", !page.isLoading else {
            Self.log("\(repository.path) button: the page didn't load (\(page.url?.absoluteString ?? "nothing"))"); tearDown(); return .failed
        }
        let found = await withTimeout(seconds: 15) { await page.evaluate(Self.findScript, arguments: [:], world: Self.world) }
        guard let ready = found as? [String: Any], ready["status"] as? String == "ready" else {
            let found = Self.outcome(found)
            Self.log("\(repository.path) button: \(found.status)\(found.detail.map { " (\($0))" } ?? "")")
            return found.outcome
        }
        // GitHub draws the button before its code takes it over: wait for that, or a press is lost.
        // A plain form's button works at once.
        if ready["form"] as? Bool != true {
            let start = Date()
            var wired = false
            while !wired, Date().timeIntervalSince(start) < 12 {
                wired = (try? await page.evaluate(Self.wiredScript, arguments: [:], in: nil, world: .page)) as? Bool == true
                if !wired { try? await Task.sleep(for: .milliseconds(200)) }
            }
            Self.log("\(repository.path) button: \(wired ? "wired" : "never seen wired") after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
        let pressed = Self.outcome(await withTimeout(seconds: 15) { await page.evaluate(Self.pressScript, arguments: [:], world: Self.world) })
        Self.log("\(repository.path) button: \(pressed.status)\(pressed.detail.map { " (\($0))" } ?? "")")
        return pressed.outcome
    }
    private static func outcome(_ value: Any?) -> (outcome: Outcome, status: String, detail: String?) {
        guard let result = value as? [String: Any], let status = result["status"] as? String else {
            return (.failed, value == nil ? "no answer (timed out or the script failed)" : "unexpected answer", value.map { String(describing: $0) })
        }
        let detail = result["detail"].map { String(describing: $0) }
        switch status {
        case "starred": return (.starred, status, detail)
        case "already": return (.alreadyStarred, status, detail)
        case "signedOut": return (.signedOut, status, detail)
        case "notFound": return (.notFound, status, detail)
        default: return (.failed, status, detail)
        }
    }

    /// A small github.com page to work from, its requests carrying the person's session.
    private func githubPage() async -> WebPage? {
        let page = self.page ?? {
            let web = BrowserTab.makePage()
            let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 1280, height: 900))
            web.view.frame = container.bounds; container.addSubview(web.view)
            host?.addSubview(container, positioned: .below, relativeTo: host?.subviews.first)
            self.page = web
            return web
        }()
        guard page is ChromiumPage else { return nil }
        if page.url?.host != "github.com" || page.isLoading {
            if page.url?.host != "github.com" { page.load(URL(string: "https://github.com/robots.txt")!) }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if page.url?.host == "github.com", !page.isLoading { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard page.url?.host == "github.com", !page.isLoading else { tearDown(); return nil }
        return page
    }

    private func withTimeout(seconds: Double, _ work: @escaping @MainActor () async -> Any?) async -> Any? {
        await withTaskGroup(of: Any?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    private func scheduleTearDown() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.tearDown()
        }
    }
    func tearDown() {
        idle?.cancel(); idle = nil
        page?.view.superview?.removeFromSuperview()
        (page as? ChromiumPage)?.browserView.close()
        page = nil
    }

    /// On the repository's own page, what both button scripts share: GitHub's Star button, and
    /// whether the page shows the repository starred.
    private static let buttonHelpers = """
          const sleep = ms => new Promise(done => setTimeout(done, ms));
          const shown = el => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
          const label = el => `${el.getAttribute('aria-label') || ''} ${el.textContent || ''}`.replace(/\\s+/g, ' ').trim();
          const controls = () => [...document.querySelectorAll('button, input[type=submit], a[role=button], summary')].filter(shown);
          const action = el => el.closest('form')?.getAttribute('action')?.toLowerCase() || '';
          const isStar = el => /\\/star$/.test(action(el)) || /^star( this repository)?\\b/i.test(label(el));
          const isUnstar = el => /\\/unstar$/.test(action(el)) || /^(unstar|starred)\\b/i.test(label(el));
          const state = () => {
            const container = [...document.querySelectorAll('.starring-container, .js-toggler-container')].find(c => c.querySelector('form[action$="/star"]'));
            if (container) return container.classList.contains('on') ? 'on' : 'off';
            if (controls().some(isUnstar)) return 'on';
            return controls().some(isStar) ? 'off' : null;
          };
        """
    /// Finds the Star button, once the page has drawn it, and marks it for the other two.
    static let findScript = """
        return (async () => { try {
        \(buttonHelpers)
          if (/^page not found/i.test(document.title)) return { status: 'notFound' };
          if (!document.querySelector('meta[name="user-login"]')?.content) return { status: 'signedOut' };
          const until = Date.now() + 8000;
          while (!state() && Date.now() < until) await sleep(200);
          if (state() === 'on') return { status: 'already' };
          const star = controls().find(isStar);
          if (!star) return { status: 'failed', detail: `no Star button on ${location.pathname}: ${controls().map(label).filter(Boolean).slice(0, 12).join(' | ').slice(0, 300)}` };
          document.querySelectorAll('[data-rise-star]').forEach(el => el.removeAttribute('data-rise-star'));
          star.setAttribute('data-rise-star', '');
          return { status: 'ready', form: !!star.closest('form') };
        } catch (error) { return { status: 'failed', detail: `script: ${error}` }; } })();
        """
    /// In the page's own world, where React keeps its props on the elements it drew: whether
    /// GitHub's code has taken over the marked button. A press before that does nothing.
    static let wiredScript = """
        const button = document.querySelector('[data-rise-star]');
        return !!button && [button, button.parentElement].some(el => el && Object.keys(el).some(key => key.startsWith('__reactProps')));
        """
    /// Presses the marked button and reads the page until it shows the repository starred.
    static let pressScript = """
        return (async () => { try {
        \(buttonHelpers)
          const star = document.querySelector('[data-rise-star]');
          if (!star) return { status: 'failed', detail: 'the Star button went away' };
          if (state() === 'on') return { status: 'already' };
          star.click();
          const until = Date.now() + 10000;
          while (state() !== 'on' && Date.now() < until) await sleep(200);
          return state() === 'on' ? { status: 'starred' } : { status: 'failed', detail: `still not starred after pressing "${label(star).slice(0, 60)}"` };
        } catch (error) { return { status: 'failed', detail: `script: ${error}` }; } })();
        """

    /// In a github.com page, given `owner` and `name`: the repository's page as the person sees
    /// it, then its Star form posted, then the page again to be sure.
    static let starScript = """
        return (async () => { try {
          const read = async () => {
            const response = await fetch(`/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`, { credentials: 'include', cache: 'no-store' });
            if (response.status === 404) return { status: 'notFound' };
            if (!response.ok) return { status: 'failed', detail: `page ${response.status}` };
            const doc = new DOMParser().parseFromString(await response.text(), 'text/html');
            // Followed to its new name, if it was renamed.
            const path = new URL(response.url).pathname.split('/').filter(Boolean).slice(0, 2).join('/').toLowerCase();
            const forms = [...doc.querySelectorAll('form[action]')].map(form => ({ form, action: new URL(form.getAttribute('action'), location.origin) }));
            const star = forms.find(f => f.action.pathname.toLowerCase() === `/${path}/star`) || forms.find(f => /\\/star$/.test(f.action.pathname));
            const container = star?.form.closest('.starring-container, .js-toggler-container');
            return {
              signedIn: !!doc.querySelector('meta[name="user-login"]')?.content,
              starred: !!container?.classList.contains('on'),
              star
            };
          };
          const before = await read();
          if (before.status) return before;
          if (!before.signedIn) return { status: 'signedOut' };
          if (before.starred) return { status: 'already' };
          if (!before.star) return { status: 'failed', detail: 'no star form' };
          const body = new FormData(before.star.form);
          if (!body.get('authenticity_token')) return { status: 'failed', detail: 'no token' };
          const posted = await fetch(before.star.action.href, {
            method: 'POST', body, credentials: 'include',
            headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
          });
          if (posted.status === 401) return { status: 'signedOut' };
          if (posted.status === 404) return { status: 'notFound' };
          if (!posted.ok) return { status: 'failed', detail: `star ${posted.status}` };
          const after = await read();
          if (after.status) return after;
          return after.starred ? { status: 'starred' } : { status: 'failed', detail: 'not starred afterwards' };
        } catch (error) { return { status: 'failed', detail: `script: ${error}` }; } })();
        """
}
