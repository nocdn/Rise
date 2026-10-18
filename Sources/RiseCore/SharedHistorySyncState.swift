import Foundation

/// One small CloudKit record per normalized URL, plus a clear marker. Keeping payloads
/// separate avoids CloudKit's record-size limit and rewriting the entire history per visit.
struct SharedHistorySyncState: Codable {
    static let clearID = "history-cleared"
    static func recognizes(_ name: String) -> Bool { name == clearID || (name.hasPrefix("history-") && name.count == 72) }
    var snapshot = SharedHistorySnapshot()
    var systemFields: [String: Data] = [:]
    var dirtyIDs: Set<String> = []

    /// Local stores already contain every applied remote counter. Compare directly, without
    /// revalidating every URL on every page update, and drop pending saves pruned by retention.
    mutating func capture(_ current: SharedHistorySnapshot) -> Set<String> {
        let discarded = Set(snapshot.records.keys).subtracting(current.records.keys)
        for (id, record) in current.records where record != snapshot.records[id] { dirtyIDs.insert(id) }
        if snapshot.clearedAt != current.clearedAt { dirtyIDs.insert(Self.clearID) }
        snapshot = current
        dirtyIDs.subtract(discarded)
        for id in discarded { systemFields[id] = nil }
        return discarded
    }
    func payload(for id: String) -> Data? {
        if id == Self.clearID, snapshot.clearedAt.clock > 0 { return try? JSONEncoder().encode(snapshot.clearedAt) }
        return snapshot.records[id].flatMap { try? JSONEncoder().encode($0) }
    }
    func matches(_ data: Data, id: String) -> Bool {
        if id == Self.clearID { return (try? JSONDecoder().decode(TabSyncVersion.self, from: data)) == snapshot.clearedAt }
        return (try? JSONDecoder().decode(SharedHistoryRecord.self, from: data)) == snapshot.records[id]
    }
    @discardableResult mutating func receive(_ data: Data, id: String, fields: Data) -> Bool {
        guard data.count <= 200_000 else { return false }
        var incoming = SharedHistorySnapshot()
        if id == Self.clearID {
            guard let version = try? JSONDecoder().decode(TabSyncVersion.self, from: data), SharedHistoryRecord.valid(version) else { return false }
            incoming.clearedAt = version
        } else {
            guard let record = try? JSONDecoder().decode(SharedHistoryRecord.self, from: data), record.isValid, record.id == id else { return false }
            incoming.records[id] = record
        }
        let old = snapshot
        _ = capture(snapshot.merging(incoming))
        systemFields[id] = fields
        if matches(data, id: id) || payload(for: id) == nil { dirtyIDs.remove(id) }
        else { dirtyIDs.insert(id) }
        return old != snapshot
    }
}
