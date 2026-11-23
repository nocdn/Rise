import Foundation

/// The portable part of a tab's travel history. Engine archives, form values, cookies and
/// POST bodies never enter this representation. Repeated URLs are distinct visits.
public struct TabNavigationHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var url: String
        public var title: String?
        public init(url: String, title: String? = nil) { self.url = url; self.title = title }
    }
    public var entries: [Entry]
    public var index: Int
    public static let maximumEntries = 100
    public static let maximumEncodedBytes = 750_000
    public init(entries: [Entry], index: Int) { self.entries = entries; self.index = index }
    public var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }

    /// Each history is checked several times a save, address by address; an answer doesn't change.
    nonisolated(unsafe) private static var allowed: [String: Bool] = [:]
    private static let allowedLock = NSLock()
    public static func allows(_ address: String) -> Bool {
        if let known = allowedLock.withLock({ allowed[address] }) { return known }
        let answer = parsesAsWebPage(address)
        allowedLock.withLock {
            if allowed.count >= 4096 { allowed.removeAll(keepingCapacity: true) }
            allowed[address] = answer
        }
        return answer
    }
    private static func parsesAsWebPage(_ address: String) -> Bool {
        guard address.utf8.count <= 8192, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    /// Reject an invalid cursor/current item, remove non-web entries, then retain a bounded
    /// window around the cursor rather than discarding Forward or the page being read.
    public func validated(for address: String? = nil) -> Self? {
        guard let current, Self.allows(current.url), address == nil || current.url == address else { return nil }
        var result: [Entry] = [], cursor = 0
        for (offset, entry) in entries.enumerated() where Self.allows(entry.url) {
            if offset == index { cursor = result.count }
            result.append(Entry(url: entry.url, title: entry.title.map { String($0.prefix(512)) }))
        }
        let start = max(0, min(cursor - Self.maximumEntries/2, result.count - Self.maximumEntries))
        let end = min(result.count, start + Self.maximumEntries)
        var bounded = Self(entries: Array(result[start..<end]), index: cursor-start)
        // A CloudKit record has a size ceiling too. Long escaped URLs/titles can
        // reach it before the entry limit; remove the farthest visits first.
        // Encoding it to measure, each time a history is checked, cost a few milliseconds a save;
        // most can't come near the ceiling, as `mostEncodedBytes` shows without encoding.
        while bounded.entries.count > 1, bounded.mostEncodedBytes > Self.maximumEncodedBytes,
              ((try? JSONEncoder().encode(bounded).count) ?? Int.max) > Self.maximumEncodedBytes {
            if bounded.index > bounded.entries.count-1-bounded.index {
                bounded.entries.removeFirst(); bounded.index -= 1
            } else { bounded.entries.removeLast() }
        }
        return bounded
    }

    /// The most its JSON can take: each byte escaped as six at worst, as a control character's
    /// \u0000 is, and room for each entry's keys and punctuation and the index.
    var mostEncodedBytes: Int {
        entries.reduce(64) { $0 + 64 + 6*$1.url.utf8.count + 6*($1.title?.utf8.count ?? 0) }
    }
    /// Title-only updates do not require replacing an already loaded page.
    public func hasSameRoute(as other: Self) -> Bool {
        index == other.index && entries.map(\.url) == other.entries.map(\.url)
    }

    public static func combining(back: [Self], current: Self, forward: [Self] = []) -> Self? {
        guard let current = current.validated() else { return nil }
        let before = back.compactMap { $0.validated() }.flatMap { Array($0.entries.prefix($0.index+1)) }
        let after = forward.compactMap { $0.validated() }.flatMap { Array($0.entries.dropFirst($0.index)) }
        return Self(entries: before + current.entries + after, index: before.count+current.index).validated()
    }
}
