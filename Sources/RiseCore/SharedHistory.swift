import CryptoKit
import Foundation

/// A page's visits are a grow-only counter per installation. A reset starts a new
/// generation, so removal/clear wins over visits made offline against an older one.
struct SharedHistoryRecord: Codable, Equatable, Sendable {
    var url: String
    var title: String
    var titleVersion: TabSyncVersion
    var generation: TabSyncVersion
    var counts: [UUID: Int]
    var lastVisited: Date

    var id: String { Self.id(for: url) }
    static func id(for url: String) -> String {
        // Hex by hand: `String(format:)` for each byte made hashing a full history take tens of ms.
        let digits = Array("0123456789abcdef".utf8)
        var hex = Array("history-".utf8)
        hex.reserveCapacity(8+64)
        for byte in SHA256.hash(data: Data(url.utf8)) { hex.append(digits[Int(byte >> 4)]); hex.append(digits[Int(byte & 15)]) }
        return String(decoding: hex, as: UTF8.self)
    }
    var visits: Int { min(1_000_000, counts.values.reduce(0, +)) }
    var isValid: Bool {
        url.utf8.count <= 16_384 && BrowsingHistory.key(URL(string: url)) == url && title.count <= 512 &&
        Self.valid(titleVersion) && Self.valid(generation) && counts.count <= 256 &&
        counts.values.allSatisfy { (1...1_000_000).contains($0) } && lastVisited.timeIntervalSince1970.isFinite
    }
    static func valid(_ version: TabSyncVersion) -> Bool { (0...9_000_000_000_000_000).contains(version.clock) }
    func merging(_ other: Self) -> Self {
        if generation != other.generation { return generation > other.generation ? self : other }
        var merged = self
        merged.counts.merge(other.counts, uniquingKeysWith: max)
        if merged.counts.count > 256 {
            merged.counts = Dictionary(uniqueKeysWithValues: merged.counts.sorted { $0.key.uuidString < $1.key.uuidString }.prefix(256).map { ($0.key, $0.value) })
        }
        merged.lastVisited = max(lastVisited, other.lastVisited)
        if titleVersion < other.titleVersion || (titleVersion == other.titleVersion && title < other.title) {
            merged.title = other.title; merged.titleVersion = other.titleVersion
        }
        return merged
    }
}

struct SharedHistorySnapshot: Codable, Equatable, Sendable {
    static let initial = TabSyncVersion(clock: 0, device: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    var records: [String: SharedHistoryRecord] = [:]
    var clearedAt = initial
    var maximumClock: Int64 { records.values.reduce(clearedAt.clock) { max($0, $1.generation.clock, $1.titleVersion.clock) } }
    var entries: [HistoryEntry] {
        records.values.filter { $0.visits > 0 }.sorted {
            $0.lastVisited == $1.lastVisited ? $0.url < $1.url : $0.lastVisited > $1.lastVisited
        }.prefix(BrowsingHistory.maximumEntries).map {
            HistoryEntry(url: $0.url, title: $0.title, visits: $0.visits, lastVisited: $0.lastVisited)
        }
    }
    func merging(_ other: Self) -> Self {
        var result = self
        if SharedHistoryRecord.valid(other.clearedAt) { result.clearedAt = max(clearedAt, other.clearedAt) }
        for (id, record) in other.records where id == record.id && record.isValid {
            result.records[id] = result.records[id].map { $0.merging(record) } ?? record
        }
        result.records = result.records.filter { $0.value.generation >= result.clearedAt }
        // Keep deletion markers until a clear supersedes them. Ordinary retention is
        // deterministic across devices and bounds the pages used for suggestions.
        if result.records.count > BrowsingHistory.maximumEntries {
            let keep = Set(result.entries.map { SharedHistoryRecord.id(for: $0.url) })
            result.records = result.records.filter { $0.value.counts.isEmpty || keep.contains($0.key) }
        }
        return result
    }
}
