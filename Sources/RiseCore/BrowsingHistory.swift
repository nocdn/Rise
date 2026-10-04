import Foundation

public struct HistoryEntry: Codable, Equatable {
    public var url: String
    public var title: String
    public var visits: Int
    public var lastVisited: Date
}

/// Local, bounded frecency ranking: literal URL prefixes outrank text matches;
/// within a match tier, frequently and recently visited pages rise to the top.
public final class BrowsingHistory {
    public static let maximumEntries = 2000
    public let storageURL: URL
    public private(set) var entries: [HistoryEntry] = []
    private var dirty = false

    public init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), data.count <= 8_000_000,
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            var seen = Set<String>()
            entries = saved.filter {
                Self.key(URL(string: $0.url)) == $0.url && $0.visits > 0 && seen.insert($0.url).inserted
            }.sorted { $0.lastVisited > $1.lastVisited }.prefix(Self.maximumEntries).map { $0 }
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
        guard let key = Self.key(url) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { $0.url == key }) {
            entries[index].visits = min(1_000_000, entries[index].visits + 1)
            entries[index].lastVisited = date
            if !title.isEmpty { entries[index].title = String(title.prefix(512)) }
        } else {
            entries.append(HistoryEntry(url: key, title: String((title.isEmpty ? url.host ?? key : title).prefix(512)), visits: 1, lastVisited: date))
        }
        if entries.count > Self.maximumEntries {
            entries.sort { $0.lastVisited > $1.lastVisited }; entries.removeLast(entries.count-Self.maximumEntries)
        }
        dirty = true
    }

    public func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let key = Self.key(url), let index = entries.firstIndex(where: { $0.url == key }),
              entries[index].title != title else { return }
        entries[index].title = String(title.prefix(512)); dirty = true
    }

    public func ranked(for query: String, limit: Int = 5, at date: Date = Date()) -> [HistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let scored = entries.compactMap { entry -> (HistoryEntry, Double)? in
            let title = entry.title.lowercased(), address = entry.url.lowercased()
            let searchable = title + " " + address
            guard words.allSatisfy({ searchable.contains($0) }) else { return nil }
            let prefix = query.count >= 2 && !query.contains(where: { $0.isWhitespace }) && Self.forms(address).contains { $0.hasPrefix(query) && $0 != query }
            let match: Double = prefix ? 1000 : !query.isEmpty && title.hasPrefix(query) ? 500 : 0
            let age = max(0, date.timeIntervalSince(entry.lastVisited)/86400)
            let frecency = 12*log2(Double(entry.visits)+1) + 30/(1+age/7)
            return (entry, match+frecency)
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.lastVisited != $1.0.lastVisited { return $0.0.lastVisited > $1.0.lastVisited }
            return $0.0.url < $1.0.url
        }.prefix(max(0, limit)).map(\.0)
    }

    /// Only complete a literal URL prefix, never a title/search substring.
    /// Keep the user's prefix/casing and select only the appended suffix in UI.
    public static func completion(for query: String, url: URL) -> String? {
        guard query.count >= 2, !query.contains(where: { $0.isWhitespace }),
              let key = key(url) else { return nil }
        for candidate in forms(key) where candidate.lowercased().hasPrefix(query.lowercased()) {
            guard candidate.utf16.count > query.utf16.count else { return nil }
            let suffix = (candidate as NSString).substring(from: query.utf16.count)
            return query + suffix
        }
        return nil
    }
    private static func forms(_ address: String) -> [String] {
        guard let separator = address.range(of: "://") else { return [address] }
        var withoutScheme = String(address[separator.upperBound...]), full = address
        if withoutScheme.hasSuffix("/"), !withoutScheme.dropLast().contains("/"), !withoutScheme.contains("?") {
            withoutScheme.removeLast(); full.removeLast()
        }
        let withoutWWW = withoutScheme.hasPrefix("www.") ? String(withoutScheme.dropFirst(4)) : withoutScheme
        return [full, withoutScheme, withoutWWW]
    }

    public func clear() throws {
        let previous = entries
        entries = []; dirty = true
        do { try save() }
        catch { entries = previous; dirty = true; throw error }
    }
    public func save() throws {
        guard dirty else { return }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: storageURL, options: .atomic)
        dirty = false
    }
}
