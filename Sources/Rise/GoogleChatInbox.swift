import AppKit

/// The account in the tab's URL: Google numbers each signed-in account in the path, as /u/1/.
struct GoogleChatAccount: Equatable {
    let baseURL: URL
    init?(url: URL?) {
        guard let url, url.scheme == "https", url.host == "chat.google.com" else { return nil }
        let path = url.path.split(separator: "/")
        if path.count >= 2, path[0] == "u", let number = Int(path[1]) {
            baseURL = URL(string: "https://chat.google.com/u/\(number)/")!
        } else {
            baseURL = URL(string: "https://chat.google.com/")!
        }
    }
    var homeURL: URL { baseURL.appendingPathComponent("app/home") }
    static func isHome(_ url: URL?) -> Bool { url?.path.hasSuffix("/app/home") == true }
}

/// A direct message, or a group conversation without a name, with its last message.
struct ChatConversation: MailListItem {
    let id: String
    let name: String
    let message: String
    /// When its last message came, in milliseconds since 1970.
    let time: Double
    var unread = false
    var date: Date { Date(timeIntervalSince1970: time/1000) }
    /// As Chat's own list puts it, in the Mac's clock: today's time, Yesterday, a weekday within
    /// the week, then a date.
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

typealias GoogleChatInbox = MailInbox<GoogleChatPageReader>

/// A companion Chat page shares the tab's session. Chat's Home lists DMs among spaces, newest
/// first, with each one's last message, and adds older ones as it scrolls. It's only read,
/// never opening a conversation or changing what's read.
@MainActor final class GoogleChatPageReader: MailPageReader {
    /// `everything` lists spaces and apps too, not only people's messages.
    struct Request: Equatable { let account: GoogleChatAccount; var everything = false }
    enum Failure: MailReaderFailure {
        case signedOut, unavailable
        var message: String {
            switch self {
            case .signedOut: "Sign in to Google Chat in this tab to see your messages."
            case .unavailable: "Couldn’t load messages. Try again."
            }
        }
    }
    private struct Snapshot: Decodable { let ready: Bool; let emails: [ChatConversation]; let rows: Int }
    /// How many DMs the first page gathers, scrolling past spaces, and how far a page scrolls.
    static let firstPage = 10, maximumScrolls = 4
    private(set) var companion: WebPage?
    private var request: Request?
    init() {}
    func prepare(source: WebPage, host: NSView) {
        if companion == nil { companion = Self.makeCompanion(in: host) }
    }
    static let world = "Rise.GoogleChat"
    private func read(_ web: WebPage) async throws -> Snapshot? {
        let value = try await web.evaluate("return " + Self.snapshot, arguments: ["everything": request?.everything ?? false], in: nil, world: .named(Self.world))
        guard let raw = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    /// The first page is what Home shows, kept current by Chat itself; each later one scrolls
    /// until another DM appears.
    func load(_ request: Request, _ page: Int) async throws -> MailPage<ChatConversation> {
        guard let web = companion else { throw Failure.unavailable }
        if self.request != request || GoogleChatAccount(url: web.url) != request.account || !GoogleChatAccount.isHome(web.url) {
            self.request = request
            web.load(request.account.homeURL)
        }
        var snapshot: Snapshot?
        let deadline = Date().addingTimeInterval(25)
        while snapshot == nil {
            try Task.checkCancellation()
            if let host = web.url?.host, host == "accounts.google.com" || host == "workspace.google.com" { throw Failure.signedOut }
            if !web.isLoading, GoogleChatAccount(url: web.url) == request.account, let next = try? await read(web), next.ready { snapshot = next; break }
            guard Date() < deadline else { throw Failure.unavailable }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard var current = snapshot else { throw Failure.unavailable }
        let wanted = page == 1 ? Self.firstPage : current.emails.count+1
        for _ in 0..<Self.maximumScrolls where current.emails.count < wanted {
            guard try await web.evaluate("return " + Self.scroll, arguments: [:], in: nil, world: .named(Self.world)) as? Bool == true
            else { return MailPage(emails: current.emails, hasMore: false) }
            // Up to 6 s for Chat to add older rows; none means the list has ended.
            var grown: Snapshot?
            for _ in 0..<40 where grown == nil {
                try await Task.sleep(for: .milliseconds(150))
                if let next = try? await read(web), next.ready, next.rows > current.rows { grown = next }
            }
            guard let grown else { return MailPage(emails: current.emails, hasMore: false) }
            current = grown
        }
        return MailPage(emails: current.emails, hasMore: true)
    }
    /// Only a load in progress stops: a Chat already open stays, kept current by Chat.
    func cancel() {
        guard companion?.isLoading == true else { return }
        companion?.stopLoading(); request = nil
    }
    func tearDown() { Self.close(companion); companion = nil; request = nil }

    /// Home's list: the rows that say whether they're read, which the sidebar's don't.
    static let homeList = "document.querySelector('[role=list] > [role=listitem][data-is-unread]')?.parentElement"
    static let scroll = """
    (() => {
      let box = \(homeList);
      while (box && box.scrollHeight <= box.clientHeight+2) box = box.parentElement;
      if (!box) return false;
      box.scrollTop = box.scrollHeight; return true;
    })();
    """
    /// Opens a conversation in the tab's own Chat as a click on its Home row does: beside Home,
    /// with Home staying. 'away' until Home shows; 'more' while it scrolls for an older row.
    static let open = """
    const list = \(homeList);
    if (!list) return 'away';
    const row = [...list.querySelectorAll(':scope > [role=listitem]')].find(e => e.getAttribute('data-group-id') === id);
    if (!row) {
      let box = list;
      while (box && box.scrollHeight <= box.clientHeight+2) box = box.parentElement;
      if (!box || box.scrollTop+box.clientHeight >= box.scrollHeight-2) return 'missing';
      box.scrollTop = box.scrollHeight; return 'more';
    }
    row.scrollIntoView({block: 'nearest'});
    const target = row.querySelector('[jsname=LNl4xb]') || row.firstElementChild || row;
    for (const type of ['mousedown', 'mouseup', 'click'])
      target.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, view: window, button: 0}));
    return 'opened';
    """
    /// People's DMs, apps aside, and the unnamed group conversations the sidebar files with them;
    /// meetings' chats and spaces are left out, unless `everything`. Home repeats a space for each of its threads.
    static let snapshot = #"""
    (() => {
      const clean = text => (text || '').replace(/[\u034f\u200b-\u200f\u2060\ufeff]/g, '').replace(/\s+/g, ' ').trim();
      const plain = node => {
        if (!node) return '';
        const copy = node.cloneNode(true);
        copy.querySelectorAll('img').forEach(img => img.replaceWith(img.getAttribute('alt') || img.getAttribute('aria-label') || img.dataset.emoji || ''));
        return clean(copy.textContent);
      };
      const list = \#(homeList);
      if (!list) return {ready: false, emails: [], rows: 0};
      const rows = [...list.querySelectorAll(':scope > [role=listitem][data-group-id]')];
      const person = [...document.querySelectorAll('[role=listitem][data-group-id^="dm/"]')].find(e => !list.contains(e));
      const section = person?.closest('[role=list]') || person?.parentElement;
      const filed = new Set([...(section?.querySelectorAll('[data-group-id]') || [])].map(e => e.getAttribute('data-group-id')));
      const seen = new Set(), emails = [];
      for (const row of rows) {
        const id = row.getAttribute('data-group-id'), type = row.getAttribute('data-group-type');
        if (seen.has(id)) continue;
        seen.add(id);
        const time = Number(row.getAttribute('data-display-timestamp')) || 0;
        const dm = id.startsWith('dm/') && type !== '2';
        const group = id.startsWith('space/') && type === '4' && filed.has(id);
        if (!time || !(everything || dm || group)) continue;
        emails.push({id, name: plain(row.querySelector('[jsname=VYJYmb]')), message: plain(row.querySelector('[jsname=JzStRd]')),
                     time, unread: row.getAttribute('data-is-unread') === 'true'});
      }
      return {ready: rows.length > 0, emails: emails.filter(e => e.name), rows: rows.length};
    })();
    """#
}
