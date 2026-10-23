import AppKit

/// The account in the tab's URL: Proton numbers each signed-in account in the path, as /u/1/.
struct ProtonMailAccount: Equatable {
    let baseURL: URL
    init?(url: URL?) {
        guard let url, url.scheme == "https", url.host == "mail.proton.me" else { return nil }
        let path = url.path.split(separator: "/")
        guard path.count >= 2, path[0] == "u", Int(path[1]) != nil,
              let base = URL(string: "https://mail.proton.me/u/\(path[1])/") else { return nil }
        baseURL = base
    }
    var inboxURL: URL { baseURL.appendingPathComponent("inbox") }
    /// The conversation open beside the inbox, as Proton's own list opens it, with the list at its page.
    func messageURL(id: String, page: Int = 1) -> URL? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=".contains($0)) }) else { return nil }
        var parts = URLComponents(url: inboxURL, resolvingAgainstBaseURL: false)!
        parts.path += "/" + id
        if page > 1 { parts.fragment = "page=\(page)" }
        return parts.url
    }
}

typealias ProtonMailInbox = MailInbox<ProtonMailPageReader>

/// A companion Proton Mail page shares the tab's session. It reads the inbox's list, which has
/// senders and subjects but no previews: bodies are end-to-end encrypted and only decrypted
/// for an open message, so it never opens one or changes its read state.
@MainActor final class ProtonMailPageReader: MailPageReader {
    struct Request: Equatable { let account: ProtonMailAccount }
    enum Failure: MailReaderFailure {
        case signedOut, unavailable
        var message: String {
            switch self {
            case .signedOut: "Sign in to Proton Mail in this tab to see your emails."
            case .unavailable: "Couldn’t load emails. Try again."
            }
        }
    }
    private(set) var companion: WebPage?
    private var request: Request?
    /// The list page the companion shows, or 0 while it's on its way to another.
    private var page = 0
    private var firstID: String?
    init() {}
    func prepare(source: WebPage, host: NSView) {
        if companion == nil { companion = Self.makeCompanion(in: host) }
    }
    private func run(_ script: String, in web: WebPage) async throws -> Any? {
        try await web.evaluate("return " + script, arguments: [:], in: nil, world: .named(Self.world))
    }
    static let world = "Rise.ProtonMail"
    func load(_ request: Request, _ page: Int) async throws -> GmailPage {
        guard let web = companion else { throw Failure.unavailable }
        let previous = firstID
        if self.request == request, self.page == page-1, page > 1 {
            self.page = 0
            guard try await run(Self.nextPage, in: web) as? Bool == true else { throw Failure.unavailable }
        } else if !(self.request == request && self.page == 1 && page == 1) {
            // The first page, already open, stays current with Proton's own updates; anything
            // else starts the app again, which takes a few seconds as it decrypts the session.
            self.request = request; self.page = 0; firstID = nil
            web.load(request.account.inboxURL)
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try Task.checkCancellation()
            if let host = web.url?.host, host == "account.proton.me" { throw Failure.signedOut }
            if !web.isLoading, ProtonMailAccount(url: web.url) == request.account,
               let value = try? await run(Self.snapshot, in: web),
               let raw = value as? [String: Any], raw["ready"] as? Bool == true, raw["page"] as? Int == page,
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
    func cancel() { companion?.stopLoading() }
    func tearDown() { cancel(); Self.close(companion); companion = nil; request = nil; page = 0; firstID = nil }

    /// Opens a conversation in the tab's own Proton, as its list does: a change of route, with
    /// no reload. False until the app is showing its mailbox. Proton's policy forbids scripts in
    /// its own world, so this runs in Rise's; the page shares its history and hears the event.
    static let open = """
    if (!document.querySelector('[data-shortcut-target="item-container"], [data-testid="conversation-header"], [data-testid="empty-view-placeholder--empty-title"]')) return false;
    history.pushState({}, '', route);
    dispatchEvent(new PopStateEvent('popstate', {state: {}}));
    return true;
    """
    static let nextPage = """
    (() => {
      const button = document.querySelector('[data-testid="toolbar:next-page"], [data-testid="pagination-row:go-to-next-page"]');
      if (!button || button.disabled || button.getAttribute('aria-disabled') === 'true') return false;
      button.click(); return true;
    })();
    """
    static let snapshot = #"""
    (() => {
      const clean = text => (text || '').replace(/[͏​-‏⁠﻿]/g, '').replace(/\s+/g, ' ').trim();
      const rows = [...document.querySelectorAll('[data-shortcut-target="item-container"][data-element-id]')].filter(row => row.getClientRects().length);
      const emails = rows.map(row => {
        const senders = [...row.querySelectorAll('[data-testid="message-column:sender-address"][title]')].map(e => clean(e.textContent)).filter(Boolean);
        const subject = row.querySelector('[data-testid="message-column:subject"]');
        return {id: row.dataset.elementId || '', sender: senders.join(', ') || clean(row.querySelector('.item-senders')?.textContent),
                subject: clean(subject?.getAttribute('title') || subject?.textContent) || '(No subject)', preview: '',
                unread: row.classList.contains('unread')};
      }).filter(email => /^[A-Za-z0-9_=-]+$/.test(email.id));
      const next = document.querySelector('[data-testid="toolbar:next-page"], [data-testid="pagination-row:go-to-next-page"]');
      const hasMore = !!next && !next.disabled && next.getAttribute('aria-disabled') !== 'true';
      const empty = [...document.querySelectorAll('[data-testid="empty-view-placeholder--empty-title"]')].some(e => e.getClientRects().length);
      const loading = !!document.querySelector('.item-is-loading');
      const inbox = /^\/u\/\d+\/inbox\/?$/.test(location.pathname);
      const page = Number(new URLSearchParams(location.hash.slice(1)).get('page') || 1);
      return {emails, hasMore, page, ready: inbox && !loading && (emails.length > 0 || empty)};
    })();
    """#
}
