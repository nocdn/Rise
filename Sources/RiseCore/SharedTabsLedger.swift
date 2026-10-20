import Foundation

/// Browser-independent tab data. Selection, cookies and engine-specific page state stay local.
public struct SharedBrowserTab: Codable, Equatable, Sendable {
    public let id: UUID
    public var url: String?
    public var title: String?
    public var navigationHistory: TabNavigationHistory?
    public init(id: UUID, url: String?, title: String?, navigationHistory: TabNavigationHistory? = nil) {
        self.id = id; self.url = url; self.title = title
        self.navigationHistory = url.flatMap { navigationHistory?.validated(for: $0) }
    }
    private enum CodingKeys: String, CodingKey { case id, url, title, navigationHistory }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), url: try values.decodeIfPresent(String.self, forKey: .url),
                  title: try values.decodeIfPresent(String.self, forKey: .title),
                  navigationHistory: try? values.decodeIfPresent(TabNavigationHistory.self, forKey: .navigationHistory))
    }
    public var isShareable: Bool {
        guard let url else { return true }
        return TabNavigationHistory.allows(url)
    }
    /// Older clients can still update a title without discarding history they cannot encode.
    func preservingHistory(from previous: Self) -> Self {
        var result = self
        if navigationHistory == nil, url == previous.url { result.navigationHistory = previous.navigationHistory }
        return result
    }
}

/// Remote closures update background tabs without taking away the page being read on this device.
/// The retained tab keeps its identity: the ledger's closure still wins, so retaining it locally
/// never reopens it on the other device. A later sync may remove it once it is in the background.
public enum SharedTabsReconciliation {
    public static func preservingActiveTab(in incoming: [SharedBrowserTab],
                                           displayed: [SharedBrowserTab], activeID: UUID?) -> [SharedBrowserTab] {
        guard let activeID, !incoming.contains(where: { $0.id == activeID }),
              let index = displayed.firstIndex(where: { $0.id == activeID }) else { return incoming }
        var result = incoming
        result.insert(displayed[index], at: min(index, result.count))
        return result
    }
}

struct TabSyncVersion: Codable, Equatable, Comparable, Sendable {
    let clock: Int64
    let device: UUID
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.clock == rhs.clock ? lhs.device.uuidString < rhs.device.uuidString : lhs.clock < rhs.clock
    }
}

/// Content and position have independent versions, so a move does not undo another device's
/// navigation. A closure always wins over stale edits; reopening creates a new tab identity.
struct SharedTabRecord: Codable, Equatable, Sendable {
    var tab: SharedBrowserTab
    var contentVersion: TabSyncVersion
    var position: Double
    var positionVersion: TabSyncVersion
    var closedAt: TabSyncVersion?
    var maximumClock: Int64 { max(contentVersion.clock, positionVersion.clock, closedAt?.clock ?? 0) }
    var isValid: Bool { tab.isShareable && position.isFinite }

    func merging(_ other: Self) -> Self {
        precondition(tab.id == other.tab.id)
        var result = self
        if contentVersion < other.contentVersion { result.tab = other.tab.preservingHistory(from: tab); result.contentVersion = other.contentVersion }
        else { result.tab = result.tab.preservingHistory(from: other.tab) }
        if positionVersion < other.positionVersion { result.position = other.position; result.positionVersion = other.positionVersion }
        if let closed = other.closedAt { result.closedAt = max(closedAt ?? closed, closed) }
        return result
    }
}

struct SharedTabsLedger: Codable, Equatable, Sendable {
    var deviceID = UUID()
    var clock: Int64 = 0
    var records: [UUID: SharedTabRecord] = [:]
    /// The last list actually displayed on this device, not an unapplied remote list.
    var observedTabs: [SharedBrowserTab] = []

    var tabs: [SharedBrowserTab] {
        records.values.filter { $0.closedAt == nil }.sorted {
            $0.position == $1.position ? $0.tab.id.uuidString < $1.tab.id.uuidString : $0.position < $1.position
        }.map(\.tab)
    }

    mutating func nextVersion() -> TabSyncVersion {
        clock = max(clock+1, Int64(Date().timeIntervalSince1970*1000))
        return TabSyncVersion(clock: clock, device: deviceID)
    }

    /// Compare against the prior local view, so remote tabs that haven't been displayed yet
    /// cannot be mistaken for locally closed tabs. Unchanged local fields never overwrite remote edits.
    mutating func capture(_ snapshot: [SharedBrowserTab]) -> Set<UUID> {
        let snapshot = snapshot.filter(\.isShareable).map { tab in
            let normalized = SharedBrowserTab(id: tab.id, url: tab.url, title: tab.title, navigationHistory: tab.navigationHistory)
            return records[tab.id].map { normalized.preservingHistory(from: $0.tab) } ?? normalized
        }
        let previous = Dictionary(observedTabs.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let oldIndices = Dictionary(observedTabs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, newest in newest })
        let currentIDs = Set(snapshot.map(\.id))
        var changed = Set<UUID>()
        for id in Set(previous.keys).subtracting(currentIDs) {
            guard var record = records[id], record.closedAt == nil else { continue }
            record.closedAt = nextVersion(); records[id] = record; changed.insert(id)
        }
        for (index, tab) in snapshot.enumerated() {
            if var record = records[tab.id] {
                guard record.closedAt == nil else { continue }
                if let old = previous[tab.id], old != tab {
                    record.tab = tab; record.contentVersion = nextVersion(); changed.insert(tab.id)
                }
                if oldIndices[tab.id] != index {
                    record.position = Double(index); record.positionVersion = nextVersion(); changed.insert(tab.id)
                }
                records[tab.id] = record
            } else {
                let version = nextVersion()
                records[tab.id] = SharedTabRecord(tab: tab, contentVersion: version, position: Double(index), positionVersion: version)
                changed.insert(tab.id)
            }
        }
        observedTabs = snapshot
        return changed
    }

    @discardableResult mutating func merge(_ incoming: SharedTabRecord) -> Bool {
        guard incoming.isValid else { return false }
        clock = max(clock, incoming.maximumClock)
        let merged = records[incoming.tab.id].map { $0.merging(incoming) } ?? incoming
        let changed = records[incoming.tab.id] != merged
        records[incoming.tab.id] = merged
        return changed
    }
}
