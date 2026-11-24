import AppKit

enum GmailCategory: String, CaseIterable {
    case primary, promotions, social, updates, forums, purchases, reservations, all
    var title: String { self == .all ? "All Categories" : rawValue.capitalized }
    var query: String { self == .all ? "in:inbox" : "in:inbox category:\(rawValue)" }
    /// Gmail's own view of the category: an inbox tab where it has one, else its search.
    var route: String {
        switch self {
        case .primary, .all: "inbox"
        case .social, .promotions, .updates, .forums: "category/\(rawValue)"
        case .purchases, .reservations: "search/\(query)"
        }
    }
}

/// Keep the account in the tab's URL, including accounts selected with `authuser`.
struct GmailAccount: Equatable {
    let baseURL: URL
    init?(url: URL?) {
        guard let url, url.scheme == "https", url.host == "mail.google.com",
              url.path == "/mail" || url.path.hasPrefix("/mail/") else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = url.path.split(separator: "/")
        if path.count >= 3, path[1] == "u", Int(path[2]) != nil { parts.path = "/mail/u/\(path[2])/" }
        else { parts.path = "/mail/" }
        parts.queryItems = parts.queryItems?.filter { $0.name == "authuser" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        parts.fragment = nil
        guard let base = parts.url else { return nil }; baseURL = base
    }
    func searchURL(category: GmailCategory, page: Int) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.fragment = "search/\(category.query)" + (page > 1 ? "/p\(page)" : "")
        return parts.url!
    }
    func listURL(category: GmailCategory, page: Int = 1) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.fragment = category.route + (page > 1 ? "/p\(page)" : ""); return parts.url!
    }
    /// Gmail's "Open in new window" conversation, which its opening page draws.
    static func isPopout(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host == "mail.google.com" else { return false }
        let path = url.path.split(separator: "/")
        return path.first == "mail" && path.last == "popout" && (path.count == 2 || (path.count == 4 && path[1] == "u"))
    }
    func messageURL(id: String) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        parts.fragment = "inbox/\(id)"; return parts.url
    }
}

/// An entry in a card's list: an email, or a Chat conversation.
protocol MailListItem: Equatable, Decodable { var id: String { get } }

struct GmailEmail: MailListItem {
    let id: String
    let sender: String
    let subject: String
    let preview: String
    var unread = false
}

struct MailPage<Item: Decodable>: Decodable {
    let emails: [Item]
    let hasMore: Bool
}
typealias GmailPage = MailPage<GmailEmail>

/// Reads a mailbox's list a page at a time, from a companion page of the mail site.
@MainActor protocol MailPageReader: AnyObject {
    associatedtype Request: Equatable
    associatedtype Item: MailListItem
    init()
    var companion: WebPage? { get }
    func prepare(source: WebPage, host: NSView)
    func load(_ request: Request, _ page: Int) async throws -> MailPage<Item>
    func cancel()
    func tearDown()
}

/// A reader's failure, with what the card says about it.
protocol MailReaderFailure: Error { var message: String { get } }

extension MailPageReader {
    /// A window keeps the mail site's list rendering normally; the companion stays offscreen,
    /// and its container keeps the page out of the window's accessibility tree.
    static func makeCompanion(in host: NSView) -> WebPage {
        let web = BrowserTab.makePage()
        let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 1100, height: 800))
        web.view.frame = container.bounds
        container.addSubview(web.view)
        host.addSubview(container, positioned: .below, relativeTo: host.subviews.first)
        container.restsBetweenReads()
        return web
    }
    static func close(_ companion: WebPage?) {
        companion?.view.superview?.removeFromSuperview()
        (companion as? ChromiumPage)?.browserView.close()
    }
}

typealias GmailInbox = MailInbox<GmailPageReader>

/// Only one account/category is held in memory. Nothing from the mailbox is saved to disk.
@MainActor final class MailInbox<Reader: MailPageReader> {
    typealias Request = Reader.Request
    typealias PageLoader = (Request, Int) async throws -> MailPage<Reader.Item>
    private(set) var request: Request?
    private(set) var emails: [Reader.Item] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var error: String?
    /// The list page each email was read from, to find its row in Gmail.
    private var pages: [String: Int] = [:]
    func page(of id: String) -> Int { pages[id] ?? 1 }
    private var nextPage = 1
    private var loadingPage = 0
    private var loadedAt = Date.distantPast
    private var task: Task<Void, Never>?
    private var generation = 0
    var onChange: (() -> Void)?
    private let reader = Reader()
    var loadPage: PageLoader?

    /// With `background`, as for a tab that's open but not hovered, a page let go for going
    /// unused (`releasePage`) stays let go: the next hover brings it back.
    func prepare(_ request: Request, source: WebPage, host: NSView, refreshAfter: TimeInterval = 60, background: Bool = false) {
        if background, request == self.request {
            if reader.companion == nil, attemptedAt != .distantPast { return }
            // Nothing to show, or a failure such as being signed out, isn't asked again at every
            // change of every tab, only once a minute; a hover always asks.
            if !isLoading, error != nil || emails.isEmpty, Date().timeIntervalSince(attemptedAt) < 60 { return }
        }
        if !background || reader.companion == nil { usedAt = Date() }
        reader.prepare(source: source, host: host)
        show(request, refreshAfter: refreshAfter)
    }
    /// When the card last showed it, or its page was made.
    private(set) var usedAt = Date.distantPast
    /// Lets the hidden page go, a whole web app, keeping what it read for the card to show at once
    /// next time while it reads again.
    func releasePage() {
        guard reader.companion != nil else { return }
        cancel(); reader.tearDown()
    }
    private var attemptedAt = Date.distantPast
    /// A new account or category starts empty. The same one keeps its emails on screen and,
    /// once they're older than `refreshAfter`, replaces them with a fresh first page.
    func show(_ request: Request, refreshAfter: TimeInterval = 60) {
        guard self.request == request else {
            cancel()
            self.request = request; emails = []; nextPage = 1; hasMore = true; error = nil; loadedAt = .distantPast
            onChange?(); load(page: 1); return
        }
        if isLoading || (error == nil && !emails.isEmpty && Date().timeIntervalSince(loadedAt) < refreshAfter) { return }
        cancel(); load(page: 1)
    }
    func loadMore() {
        guard request != nil, !isLoading, hasMore else { return }
        load(page: emails.isEmpty ? 1 : nextPage)
    }
    /// Only a first load or a next page shows its loading row; a refresh happens behind the list.
    var showsLoading: Bool { isLoading && (emails.isEmpty || loadingPage > 1) }
    private func load(page: Int) {
        guard let request else { return }
        if page == 1 { attemptedAt = Date() }
        isLoading = true; loadingPage = page
        if emails.isEmpty || page > 1 { error = nil }
        onChange?()
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await HiddenAccessibilityView.reading(reader.companion) { try await (self.loadPage ?? self.reader.load)(request, page) }
                guard !Task.isCancelled, token == generation, self.request == request else { return }
                if page == 1 {
                    var ids = Set<String>()
                    emails = result.emails.filter { ids.insert($0.id).inserted }; pages = [:]
                    hasMore = result.hasMore && !emails.isEmpty
                } else {
                    var ids = Set(emails.map(\.id))
                    let added = result.emails.filter { ids.insert($0.id).inserted }
                    emails.append(contentsOf: added)
                    hasMore = result.hasMore && !added.isEmpty
                }
                for email in result.emails where pages[email.id] == nil { pages[email.id] = page }
                nextPage = page+1; loadedAt = Date(); error = nil
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                // A failed refresh keeps the emails already shown.
                if page > 1 || emails.isEmpty {
                    self.error = (error as? any MailReaderFailure)?.message ?? "Couldn’t load emails. Try again."
                }
                reader.cancel()
            }
            isLoading = false; loadingPage = 0; task = nil; onChange?()
        }
    }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; isLoading = false; loadingPage = 0; reader.cancel()
    }
    func tearDown() { cancel(); reader.tearDown(); emails = []; pages = [:]; request = nil }
    deinit { task?.cancel() }
}

extension MailInbox where Reader == GmailPageReader {
    func prepare(account: GmailAccount, category: GmailCategory, source: WebPage, host: NSView, refreshAfter: TimeInterval = 60, background: Bool = false) {
        prepare(Request(account: account, category: category), source: source, host: host, refreshAfter: refreshAfter, background: background)
    }
}

/// A companion Gmail page, of the tab's own engine, shares the tab's session. It reads Gmail's
/// text-only list previews, never opening a message or changing its read state.
@MainActor final class GmailPageReader: MailPageReader {
    struct Request: Equatable { let account: GmailAccount; let category: GmailCategory }
    enum Failure: MailReaderFailure {
        case signedOut, unavailable
        var message: String {
            switch self {
            case .signedOut: "Sign in to Gmail in this tab to see your emails."
            case .unavailable: "Couldn’t load emails. Try again."
            }
        }
    }
    private(set) var companion: WebPage?
    private var request: Request?
    private var page = 0
    private var firstID: String?
    init() {}
    func prepare(source: WebPage, host: NSView) {
        if companion == nil { companion = Self.makeCompanion(in: host) }
    }
    /// Runs one of the scripts below, in Rise's own world.
    private func run(_ script: String, in web: WebPage) async throws -> Any? {
        try await web.evaluate("return " + script, arguments: [:], in: nil, world: .named(Self.world))
    }
    static let world = "Rise.Gmail"
    func load(_ request: Request, _ page: Int) async throws -> GmailPage {
        guard let web = companion else { throw Failure.unavailable }
        let previous = firstID
        if self.request == request, self.page == page-1, page > 1 {
            let advanced = try await run(Self.nextPage, in: web) as? Bool ?? false
            if !advanced { throw Failure.unavailable }
        } else {
            self.request = request; self.page = 0; firstID = nil
            let url = request.account.searchURL(category: request.category, page: page)
            // Gmail rewrites the address's encoding. The same route would only scroll to its
            // fragment, so refreshing it needs a real reload.
            if Self.route(web.url) == Self.route(url) { web.reload() } else { web.load(url) }
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try Task.checkCancellation()
            if let url = web.url, url.host == "accounts.google.com" { throw Failure.signedOut }
            if !web.isLoading, GmailAccount(url: web.url) == request.account,
               let value = try? await run(Self.snapshot, in: web),
               let raw = value as? [String: Any], raw["ready"] as? Bool == true,
               raw["query"] as? String == request.category.query, page > 1 || raw["page"] as? Int == 1,
               let data = try? JSONSerialization.data(withJSONObject: raw),
               let result = try? JSONDecoder().decode(GmailPage.self, from: data),
               page == 1 || result.emails.isEmpty || result.emails.first?.id != previous {
                self.page = page; firstID = result.emails.first?.id
                return result
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Failure.unavailable
    }
    func cancel() { companion?.stopLoading(); request = nil; page = 0; firstID = nil }
    nonisolated static func route(_ url: URL?) -> String? {
        guard let url, let fragment = url.fragment else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.fragment = nil
        return (parts?.string ?? "")+"#"+(fragment.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? fragment)
    }
    func tearDown() {
        cancel(); Self.close(companion); companion = nil
    }

    /// Shift-clicking a conversation's row is how Gmail opens it in a new window. Only the
    /// row's own page can draw that window, so the click has to come from the row.
    static func popOut(_ id: String) -> String {
        """
        (() => {
          const thread = [...document.querySelectorAll('tr.zA [data-legacy-thread-id="\(id.filter(\.isHexDigit))"]')].find(e => e.getClientRects().length);
          const target = thread?.closest('tr.zA')?.querySelector('.y6, .bog, td.xY');
          if (!target) return false;
          for (const type of ['mousedown', 'mouseup', 'click'])
            target.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, shiftKey: true, view: window, button: 0}));
          return true;
        })();
        """
    }
    // .amJ is Gmail's Older arrow, independent of the interface language.
    static let nextPage = """
    (() => {
      const button = document.querySelector('.amJ')?.closest('[role="button"]');
      if (!button || button.getAttribute('aria-disabled') === 'true' || button.classList.contains('T-I-JE')) return false;
      button.click(); return true;
    })();
    """
    static let snapshot = #"""
    (() => {
      const clean = text => (text || '').replace(/[\u034f\u200b-\u200f\u2060\ufeff]/g, '').replace(/\s+/g, ' ').trim();
      const plain = node => {
        if (!node) return '';
        const copy = node.cloneNode(true);
        copy.querySelectorAll('img, svg, script, style, .Zt, [aria-hidden="true"]').forEach(e => e.remove());
        return clean(copy.textContent);
      };
      const rows = [...document.querySelectorAll('tr.zA')].filter(row => row.getClientRects().length);
      const emails = rows.map(row => {
        const thread = row.querySelector('[data-legacy-thread-id]');
        const id = thread?.getAttribute('data-legacy-thread-id') || '';
        const senders = [...row.querySelectorAll('.yW [email]')];
        const sender = clean(senders.map(e => e.getAttribute('name') || e.textContent).join(', ')) || plain(row.querySelector('.yW'));
        return {id, sender, subject: plain(row.querySelector('.bog')) || '(No subject)', preview: plain(row.querySelector('.y2')),
                unread: row.classList.contains('zE')};
      }).filter(email => /^[0-9a-f]+$/i.test(email.id));
      const next = document.querySelector('.amJ')?.closest('[role="button"]');
      const hasMore = !!next && next.getAttribute('aria-disabled') !== 'true' && !next.classList.contains('T-I-JE');
      const empty = [...document.querySelectorAll('.ae4 .TC')].some(e => e.getClientRects().length && clean(e.textContent));
      const route = decodeURIComponent(location.hash.slice(1)).replace(/\+/g, ' ');
      const query = route.startsWith('search/') ? route.slice(7).replace(/\/p\d+$/, '') : '';
      const page = Number(route.match(/\/p(\d+)$/)?.[1] || 1);
      return {emails, hasMore, query, page, ready: emails.length > 0 || empty};
    })();
    """#
}

/// Holds offscreen web content that assistive apps should never reach.
final class HiddenAccessibilityView: NSView {
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }

    /// A page kept for a hover card is only read now and then. Offscreen in a window, Chromium
    /// takes it for one on screen and runs it at full speed; hidden between reads, it's treated
    /// as a background tab: timers slowed, nothing drawn, free to be frozen.
    private var rests = false, readers = 0
    func restsBetweenReads() { rests = true; isHidden = readers == 0 }
    /// Shown while `read` reads `page`, as some sites lay their lists out only for a page on screen.
    static func reading<T>(_ page: WebPage?, _ read: () async throws -> T) async rethrows -> T {
        guard let container = page?.view.superview as? HiddenAccessibilityView, container.rests else { return try await read() }
        container.readers += 1; container.isHidden = false
        defer { container.readers -= 1; if container.readers == 0 { container.isHidden = true } }
        return try await read()
    }
}
