import Foundation

/// How long Rise has really been away. A tab's time unused leaves out any stretch of `awayAfter` or
/// more with no use of Rise at all, so a holiday doesn't count against every tab, while a night does.
public struct TabUseClock: Codable, Equatable, Sendable {
    public static let awayAfter: TimeInterval = 12*3600
    static let maximumPeriods = 100
    public private(set) var lastActive: Date?
    public private(set) var away: [DateInterval] = []
    public init() {}
    /// Notes Rise being used now, which ends any time away.
    public mutating func noteActive(at date: Date) {
        if let lastActive, date.timeIntervalSince(lastActive) >= Self.awayAfter {
            away.append(DateInterval(start: lastActive, end: date))
            away.removeFirst(max(0, away.count-Self.maximumPeriods))
        }
        if lastActive.map({ date > $0 }) ?? true { lastActive = date }
    }
    /// The time from `date` to `now` that counts: all of it but what's been spent away.
    public func unused(since date: Date, at now: Date) -> TimeInterval {
        guard now > date else { return 0 }
        let spentAway = away.reduce(0.0) { total, period in
            total + max(0, min(period.end, now).timeIntervalSince(max(period.start, date)))
        }
        return max(0, now.timeIntervalSince(date)-spentAway)
    }
}

/// Which tabs have gone unused for long enough to archive. A tab's time limit starts from the chosen
/// one and moves with what it says about the tab: longer for tabs returned to, shorter for those
/// made to be left behind. Only tabs that say nothing either way get the limit as it is.
public struct TabArchiveRules: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var id: UUID
        public var use: TabUse
        public var url: URL?
        /// Times its address has been visited, on every device.
        public var visits: Int
        public var isDeveloper: Bool
        /// Never archived, though it counts as open.
        public var isProtected: Bool
        public init(id: UUID, use: TabUse, url: URL?, visits: Int = 0, isDeveloper: Bool = false, isProtected: Bool = false) {
            self.id = id; self.use = use; self.url = url; self.visits = visits; self.isDeveloper = isDeveloper; self.isProtected = isProtected
        }
    }
    public static let defaultHours = 48
    /// So many tabs always stay open, the most recently used of them.
    public static let alwaysOpen = 10
    /// A blank tab holds nothing to go back to, whatever the limit.
    static let blankLimit: TimeInterval = 3600
    /// Script: whether anything on the page has been typed into, chosen or picked and not sent, or
    /// the page's focus is in something being written.
    public static let editingScript = """
        for (const field of document.querySelectorAll('input, textarea, select')) {
          if (field instanceof HTMLSelectElement) {
            if ([...field.options].some(option => option.selected !== option.defaultSelected)) return true;
          } else if (field.type === 'checkbox' || field.type === 'radio') {
            if (field.checked !== field.defaultChecked) return true;
          } else if (field.type === 'file') {
            if (field.files?.length) return true;
          } else if (!['hidden', 'submit', 'button', 'reset', 'image'].includes(field.type)) {
            if (field.value !== field.defaultValue) return true;
          }
        }
        const focus = document.activeElement;
        return !!focus && (focus.isContentEditable || (/^(INPUT|TEXTAREA)$/.test(focus.tagName) && focus.value !== ''));
        """
    public var limit: TimeInterval
    public init(limit: TimeInterval = Double(defaultHours)*3600) { self.limit = limit }

    public func limit(for tab: Tab, isDuplicate: Bool = false, at now: Date) -> TimeInterval {
        guard let url = tab.url, url.absoluteString != "about:blank" else { return min(limit, Self.blankLimit) }
        let isSearch = Self.isSearchResults(url)
        var scale = 1.0
        switch tab.use.daysUsed(before: now) {
        case 5...: scale = 7
        case 3...4: scale = 3.5
        case 2: scale = 2
        default: break
        }
        // Each search is its own address, so visits say nothing about one worth keeping.
        if !isSearch {
            if tab.visits >= 20 { scale = max(scale, 3.5) } else if tab.visits >= 8 { scale = max(scale, 2) }
        }
        if tab.isDeveloper { scale = max(scale, 3.5) }
        if scale == 1, isSearch || isDuplicate { scale = 0.5 }
        return limit*scale
    }

    /// The tabs to archive, longest unused first.
    public func due(_ tabs: [Tab], clock: TabUseClock, at now: Date) -> [UUID] {
        // Of tabs at one address, only the most recently used isn't a duplicate.
        var latest: [String: UUID] = [:]
        for tab in tabs.sorted(by: { $0.use.lastUsed < $1.use.lastUsed }) {
            if let address = Self.address(of: tab.url) { latest[address] = tab.id }
        }
        let due = tabs.compactMap { tab -> (id: UUID, unused: TimeInterval)? in
            guard !tab.isProtected else { return nil }
            let isDuplicate = Self.address(of: tab.url).map { latest[$0] != tab.id } ?? false
            let unused = clock.unused(since: tab.use.lastUsed, at: now)
            return unused >= limit(for: tab, isDuplicate: isDuplicate, at: now) ? (tab.id, unused) : nil
        }
        return due.sorted { $0.unused > $1.unused }.prefix(max(0, tabs.count-Self.alwaysOpen)).map(\.id)
    }

    private static func address(of url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    /// A page of results from a search engine, which the same search brings back.
    public static func isSearchResults(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path.lowercased()
        let isGoogle = host.hasPrefix("google.") || host.contains(".google.")
        if isGoogle { return path == "/search" }
        switch host {
        case "bing.com", "kagi.com", "search.brave.com", "ecosia.org", "startpage.com": return path.hasPrefix("/search") || path == "/do/search" || path == "/sp/search"
        case "duckduckgo.com", "html.duckduckgo.com": return url.query?.contains("q=") == true
        case "search.yahoo.com": return path.hasPrefix("/search")
        case "youtube.com": return path == "/results"
        default: return false
        }
    }
}

/// A tab archived for going unused, kept with all it needs to come back as it was.
public struct ArchivedTab: Codable, Equatable {
    public var tab: SavedTab
    public var archivedAt: Date
    public init(tab: SavedTab, archivedAt: Date) { self.tab = tab; self.archivedAt = archivedAt }
    public var id: UUID { tab.id }
    public init(_ shared: SharedArchivedTab) {
        self.init(tab: SavedTab(id: shared.id, url: shared.url, title: shared.title, navigationHistory: shared.navigationHistory, use: shared.use),
                  archivedAt: shared.archivedAt)
    }
}

/// The archived tabs on this Mac, newest first, saved as they change, each with what only this Mac
/// can bring back, such as the engine's session and icon. Those shared with other devices follow
/// the list in `SharedTabsSync`, by `reconcile`. It's a list to come back to, so it holds a lot but
/// not for ever: the oldest go past `maximumCount`, or after `keptFor`.
public final class ArchivedTabs {
    public static let maximumCount = SharedArchivedTab.maximumCount
    public static let keptFor = SharedArchivedTab.keptFor
    public private(set) var entries: [ArchivedTab] = []
    public let storageURL: URL
    private let writer = DispatchQueue(label: "Rise.ArchivedTabs", qos: .utility)

    public init(storageURL: URL, now: Date = Date()) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), let saved = try? JSONDecoder().decode([ArchivedTab].self, from: data) {
            entries = Self.kept(saved, at: now)
        }
    }
    private static func kept(_ entries: [ArchivedTab], at now: Date) -> [ArchivedTab] {
        Array(entries.filter { now.timeIntervalSince($0.archivedAt) < keptFor }.sorted { $0.archivedAt > $1.archivedAt }.prefix(maximumCount))
    }
    public func add(_ tabs: [SavedTab], at now: Date = Date()) {
        let ids = Set(tabs.map(\.id))
        entries = Self.kept(tabs.map { ArchivedTab(tab: $0, archivedAt: now) } + entries.filter { !ids.contains($0.id) }, at: now)
        save()
    }
    /// Follows other devices: what they've archived joins the list, unless it's still `open` here,
    /// and what they've reopened or deleted leaves it.
    public func reconcile(with shared: [ArchivedTab], removed: (UUID) -> Bool, open: Set<UUID>, at now: Date = Date()) {
        var next = entries.filter { !removed($0.id) }
        let known = Set(next.map(\.id))
        next += shared.filter { !known.contains($0.id) && !open.contains($0.id) && !removed($0.id) }
        next = Self.kept(next, at: now)
        guard next != entries else { return }
        entries = next
        save()
    }
    /// Takes one out of the list, to reopen or to be rid of it.
    @discardableResult public func remove(_ id: UUID) -> SavedTab? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = entries.remove(at: index).tab
        save()
        return tab
    }
    /// Those with every word of `query` in their title or address.
    public func matching(_ query: String) -> [ArchivedTab] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = (entry.tab.title+" "+entry.tab.url).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
    public func flush() { writer.sync {} }
    /// Encoded in the background too: with each tab's engine session, the list runs to megabytes.
    private func save() {
        nonisolated(unsafe) let entries = entries
        let file = storageURL
        writer.async {
            guard let data = try? JSONEncoder().encode(entries) else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch { NSLog("Rise archived tabs couldn't be saved: %@", error.localizedDescription) }
        }
    }
}
