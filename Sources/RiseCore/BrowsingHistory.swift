import Foundation

public struct HistoryEntry: Codable, Equatable {
    public var url: String
    public var title: String
    public var visits: Int
    public var lastVisited: Date
}

/// Bounded frecency ranking: literal URL prefixes outrank text matches;
/// within a match tier, frequently and recently visited pages rise to the top.
public final class BrowsingHistory {
    public static let maximumEntries = 2000
    public let storageURL: URL
    public private(set) var entries: [HistoryEntry] = []
    /// Local mutations only. Receiving a remote snapshot never counts as a visit.
    public var onChange: (() -> Void)?
    private struct Storage: Codable {
        var deviceID = UUID()
        var clock: Int64 = 0
        var snapshot = SharedHistorySnapshot()
        /// Addresses typed or picked in the address field, by history key: kept on this device only.
        var typed: [String: Typed]?
    }
    struct Typed: Codable, Equatable { var count: Int; var last: Date }
    /// A typed visit is a stronger wish to go somewhere than following a link: it counts as this many.
    static let typedWeight = 4
    private var storage = Storage()
    var snapshot: SharedHistorySnapshot { storage.snapshot }
    private var dirty = false

    public init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), data.count <= 64_000_000 {
            if let saved = try? JSONDecoder().decode(Storage.self, from: data) {
                storage = saved; storage.snapshot = .init().merging(saved.snapshot)
                storage.clock = max(storage.clock, storage.snapshot.maximumClock)
            } else if let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
                var seen = Set<String>()
                for entry in saved.sorted(by: { $0.lastVisited > $1.lastVisited }).prefix(Self.maximumEntries)
                where Self.key(URL(string: entry.url)) == entry.url && entry.visits > 0 && seen.insert(entry.url).inserted {
                    let record = SharedHistoryRecord(url: entry.url, title: String(entry.title.prefix(512)), titleVersion: nextVersion(),
                        generation: SharedHistorySnapshot.initial,
                        counts: [storage.deviceID: min(1_000_000, entry.visits)], lastVisited: entry.lastVisited)
                    if record.isValid { storage.snapshot.records[record.id] = record }
                }
                // Persist the installation ID with the migrated counters before they can sync.
                dirty = true; try? save()
            }
            entries = storage.snapshot.entries
        }
    }

    public static func key(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = scheme; parts.host = host; parts.user = nil; parts.password = nil; parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.url?.absoluteString
    }

    public func record(_ url: URL, title: String, at date: Date = Date()) {
        guard let key = Self.key(url), key.utf8.count <= 16_384, date.timeIntervalSince1970.isFinite else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = SharedHistoryRecord.id(for: key), version = nextVersion()
        var record = storage.snapshot.records[id] ?? SharedHistoryRecord(url: key, title: String((title.isEmpty ? url.host ?? key : title).prefix(512)),
            titleVersion: version, generation: storage.snapshot.clearedAt, counts: [:], lastVisited: date)
        record.lastVisited = record.counts.isEmpty ? date : max(date, record.lastVisited)
        record.counts[storage.deviceID] = min(1_000_000, (record.counts[storage.deviceID] ?? 0)+1)
        if !title.isEmpty { record.title = String(title.prefix(512)); record.titleVersion = version }
        storage.snapshot.records[id] = record
        entries = storage.snapshot.entries
        if storage.snapshot.records.count > Self.maximumEntries {
            let keep = Set(entries.map { SharedHistoryRecord.id(for: $0.url) })
            storage.snapshot.records = storage.snapshot.records.filter { $0.value.counts.isEmpty || keep.contains($0.key) }
        }
        dirty = true; onChange?()
    }

    public func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let key = Self.key(url) else { return }
        let id = SharedHistoryRecord.id(for: key), title = String(title.prefix(512))
        guard var record = storage.snapshot.records[id], record.visits > 0, record.title != title else { return }
        record.title = title; record.titleVersion = nextVersion(); storage.snapshot.records[id] = record
        entries = storage.snapshot.entries; dirty = true; onChange?()
    }

    /// Removes the visit record and its suggestion ranking on every synced device.
    @discardableResult public func remove(_ url: URL) -> Bool {
        guard let key = Self.key(url) else { return false }
        let id = SharedHistoryRecord.id(for: key)
        guard var record = storage.snapshot.records[id], record.visits > 0 else { return false }
        record.generation = nextVersion(); record.counts = [:]; storage.snapshot.records[id] = record
        entries = storage.snapshot.entries; dirty = true; onChange?()
        return true
    }

    private func nextVersion() -> TabSyncVersion {
        storage.clock = max(storage.clock+1, Int64(Date().timeIntervalSince1970*1000))
        return TabSyncVersion(clock: storage.clock, device: storage.deviceID)
    }
    @discardableResult func merge(_ incoming: SharedHistorySnapshot) -> Bool {
        let merged = snapshot.merging(incoming)
        guard merged != snapshot else { return false }
        storage.snapshot = merged; storage.clock = max(storage.clock, merged.maximumClock)
        entries = merged.entries; dirty = true
        return true
    }

    public func ranked(for query: String, limit: Int = 5, at date: Date = Date()) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let scored = entries.compactMap { entry -> (HistoryEntry, Double)? in
            let title = entry.title.lowercased(), address = entry.url.lowercased()
            let searchable = title + " " + address
            guard words.allSatisfy({ searchable.contains($0) }) else { return nil }
            let prefix = !query.isEmpty && !query.contains(where: { $0.isWhitespace }) && Self.forms(address, for: query).contains { $0.hasPrefix(query) && $0 != query }
            let match: Double = prefix ? 1000 : !query.isEmpty && title.hasPrefix(query) ? 500 : 0
            return (entry, match+Self.frecency(visits: entry.visits, lastVisited: entry.lastVisited, at: date))
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.lastVisited != $1.0.lastVisited { return $0.0.lastVisited > $1.0.lastVisited }
            return $0.0.url < $1.0.url
        }.prefix(max(0, limit)).map(\.0)
    }

    /// How often and how lately: more visits count for less each, and a visit's weight halves over about a week.
    static func frecency(visits: Int, lastVisited: Date, at date: Date) -> Double {
        let age = max(0, date.timeIntervalSince(lastVisited)/86400)
        return 12*log2(Double(visits)+1) + 30/(1+age/7)
    }

    /// Where typing `query` leads: of the sites whose address it starts, the one visited most across
    /// all its pages, so many pages of one site outweigh one page of another; and one of its pages
    /// only as the site's usual destination (more than one visit, at least half the site's, and no
    /// query), or once the address typed reaches past the site.
    public func destination(for query: String, at date: Date = Date()) -> (site: URL, page: HistoryEntry?)? {
        // Each page's weight: its visits, and each time its address was typed counting for more. An
        // address typed but never kept, as one that sent the browser elsewhere, still counts.
        var weighed: [String: (entry: HistoryEntry, weight: Int)] = [:]
        for entry in entries { weighed[entry.url] = (entry, entry.visits) }
        for (key, typed) in storage.typed ?? [:] {
            let extra = Self.typedWeight*typed.count
            if var page = weighed[key] {
                page.weight += extra; page.entry.lastVisited = max(page.entry.lastVisited, typed.last); weighed[key] = page
            } else {
                weighed[key] = (HistoryEntry(url: key, title: URL(string: key)?.host ?? key, visits: 0, lastVisited: typed.last), extra)
            }
        }
        var sites: [String: (site: URL, pages: [(entry: HistoryEntry, weight: Int)])] = [:]
        for page in weighed.values {
            guard let url = URL(string: page.entry.url), Self.completion(for: query, url: url, includePath: true) != nil,
                  let site = Self.site(of: url) else { continue }
            sites[site.absoluteString, default: (site, [])].pages.append(page)
        }
        func score(_ page: (entry: HistoryEntry, weight: Int)) -> Double { Self.frecency(visits: page.weight, lastVisited: page.entry.lastVisited, at: date) }
        func score(_ pages: [(entry: HistoryEntry, weight: Int)]) -> Double {
            Self.frecency(visits: pages.reduce(0) { $0+$1.weight }, lastVisited: pages.map(\.entry.lastVisited).max() ?? .distantPast, at: date)
        }
        guard let best = sites.values.max(by: { a, b in
            let (x, y) = (score(a.pages), score(b.pages))
            return x != y ? x < y : a.site.absoluteString > b.site.absoluteString
        }) else { return nil }
        let pages = best.pages.sorted { score($0) != score($1) ? score($0) > score($1) : $0.entry.url < $1.entry.url }
        guard let top = pages.first, let url = URL(string: top.entry.url) else { return (best.site, nil) }
        if Self.completion(for: query, url: best.site) == nil { return (best.site, top.entry) }
        let weight = pages.reduce(0) { $0+$1.weight }
        let usual = top.weight > 1 && top.weight*2 >= weight && url.query == nil && Self.site(of: url) != url
        return (best.site, usual ? top.entry : nil)
    }

    /// Only complete a literal URL prefix, never a title/search substring.
    /// A single character can complete an address already learned from history.
    /// Keep the user's prefix/casing and select only the appended suffix in UI.
    /// A one-off page fills only its site until a path is typed. The ranking engine
    /// can include a repeatedly visited page's path when it is the preferred destination.
    public static func completion(for query: String, url: URL, includePath: Bool = false) -> String? {
        guard !query.isEmpty, !query.contains(where: { $0.isWhitespace }),
              let key = key(url) else { return nil }
        for var candidate in forms(key, for: query) where candidate.lowercased().hasPrefix(query.lowercased()) {
            let site = siteEnd(candidate)
            if !includePath && query.utf16.count <= site { candidate = (candidate as NSString).substring(to: site) }
            guard candidate.utf16.count > query.utf16.count else { return nil }
            let suffix = (candidate as NSString).substring(from: query.utf16.count)
            return query + suffix
        }
        return nil
    }
    /// The site a page is on: its address with only "/" for a path.
    public static func site(of url: URL) -> URL? {
        guard let key = key(url), var parts = URLComponents(string: key) else { return nil }
        parts.percentEncodedPath = "/"; parts.percentEncodedQuery = nil
        return parts.url
    }
    /// Where an address's site ends: the first "/" after its scheme, or its end.
    private static func siteEnd(_ address: String) -> Int {
        let text = address as NSString
        let scheme = text.range(of: "://"), start = scheme.location == NSNotFound ? 0 : NSMaxRange(scheme)
        let slash = text.range(of: "/", range: NSRange(location: start, length: text.length-start))
        return slash.location == NSNotFound ? text.length : slash.location
    }
    private static func forms(_ address: String, for query: String) -> [String] {
        guard let separator = address.range(of: "://") else { return [address] }
        var withoutScheme = String(address[separator.upperBound...]), full = address
        if withoutScheme.hasSuffix("/"), !withoutScheme.dropLast().contains("/"), !withoutScheme.contains("?") {
            withoutScheme.removeLast(); full.removeLast()
        }
        let withoutWWW = withoutScheme.hasPrefix("www.") ? String(withoutScheme.dropFirst(4)) : withoutScheme
        // One letter matches the site's name, not the "h" in HTTPS or "w" in www.
        if query.count == 1 { return [withoutWWW] }
        return [full, withoutScheme, withoutWWW]
    }

    /// `url` was typed or picked in the address field, to go to.
    public func recordTyped(_ url: URL, at date: Date = Date()) {
        guard let key = Self.key(url), key.utf8.count <= 16_384 else { return }
        var typed = storage.typed ?? [:]
        let old = typed[key]
        typed[key] = Typed(count: min(1_000_000, (old?.count ?? 0)+1), last: max(date, old?.last ?? date))
        if typed.count > Self.maximumEntries, let oldest = typed.min(by: { $0.value.last < $1.value.last })?.key { typed[oldest] = nil }
        storage.typed = typed; dirty = true
    }

    public func clear() throws {
        let previous = storage
        storage.snapshot = SharedHistorySnapshot(clearedAt: nextVersion()); storage.typed = nil
        entries = []; dirty = true
        do { try save() }
        catch { storage = previous; entries = previous.snapshot.entries; dirty = true; throw error }
        onChange?()
    }
    public func save() throws {
        guard dirty else { return }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(storage).write(to: storageURL, options: .atomic)
        dirty = false
    }
}
