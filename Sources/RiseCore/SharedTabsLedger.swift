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

/// When a tab was last really used, on any device, and which days it was used on. Merging takes the
/// latest time and every day, so it needs no version and an older client dropping it does no harm.
public struct TabUse: Codable, Equatable, Sendable {
    public var lastUsed: Date
    /// Local day numbers, oldest first, at most `maximumDays` of them.
    public private(set) var days: [Int]
    static let maximumDays = 10
    public init(lastUsed: Date, days: [Int] = []) {
        self.lastUsed = lastUsed; self.days = Array(Set(days).sorted().suffix(Self.maximumDays))
    }
    public static func day(of date: Date, in zone: TimeZone = .current) -> Int {
        Int(floor((date.timeIntervalSince1970+Double(zone.secondsFromGMT(for: date)))/86400))
    }
    /// Notes a use, unless the last was within `interval` on the same day. Returns whether it changed.
    @discardableResult public mutating func record(at date: Date, every interval: TimeInterval = 0) -> Bool {
        let day = Self.day(of: date), newDay = !days.contains(day)
        guard newDay || date.timeIntervalSince(lastUsed) >= interval else { return false }
        self = TabUse(lastUsed: max(lastUsed, date), days: days + [day])
        return true
    }
    /// The days it was used on in the 30 days up to `date`.
    public func daysUsed(before date: Date, within span: Int = 30) -> Int {
        let today = Self.day(of: date)
        return days.filter { today-$0 < span }.count
    }
    public func merging(_ other: TabUse?) -> TabUse {
        guard let other else { return self }
        return TabUse(lastUsed: max(lastUsed, other.lastUsed), days: days + other.days)
    }
}

/// That a closed tab went to Archived Tabs rather than being closed for good. It stays with the
/// tab's record, so every device has the same list and needs nothing more to bring the tab back.
/// Being taken out of the list, by reopening or deleting it, is final, as the tab's identity is.
public struct TabArchiveMark: Codable, Equatable, Sendable {
    public var archivedAt: Date
    public var isRemoved = false
    func merging(_ other: Self?) -> Self {
        guard let other else { return self }
        return TabArchiveMark(archivedAt: min(archivedAt, other.archivedAt), isRemoved: isRemoved || other.isRemoved)
    }
}

/// A tab in Archived Tabs, as every device has it.
public struct SharedArchivedTab: Equatable, Sendable {
    public let id: UUID
    public let url: String
    public let title: String
    public let navigationHistory: TabNavigationHistory?
    public let use: TabUse?
    public let archivedAt: Date
    /// It's a list to come back to, so it holds a lot but not for ever.
    public static let maximumCount = 500
    public static let keptFor: TimeInterval = 90*86400
}

/// That a device wants a tab left alone for a reason others can't see, such as its being pinned there.
struct TabKeptMark: Codable, Equatable, Sendable {
    var isKept: Bool
    var version: TabSyncVersion
    func merging(_ other: Self?) -> Self {
        guard let other else { return self }
        return version < other.version ? other : self
    }
}

/// On Mac, remote closures update background tabs without taking away the page being read there;
/// on iOS, that page closes too and the first tab takes its place.
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
    var use: TabUse?
    var archive: TabArchiveMark?
    var kept: TabKeptMark?
    var maximumClock: Int64 { max(contentVersion.clock, positionVersion.clock, closedAt?.clock ?? 0) }
    var isValid: Bool { tab.isShareable && position.isFinite }

    func merging(_ other: Self) -> Self {
        precondition(tab.id == other.tab.id)
        var result = self
        if contentVersion < other.contentVersion { result.tab = other.tab.preservingHistory(from: tab); result.contentVersion = other.contentVersion }
        else { result.tab = result.tab.preservingHistory(from: other.tab) }
        if positionVersion < other.positionVersion { result.position = other.position; result.positionVersion = other.positionVersion }
        if let closed = other.closedAt { result.closedAt = max(closedAt ?? closed, closed) }
        result.use = use?.merging(other.use) ?? other.use
        result.archive = archive?.merging(other.archive) ?? other.archive
        result.kept = kept?.merging(other.kept) ?? other.kept
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
        // These change nothing in the list of tabs, so they aren't changes for the adapters to show.
        var previous = records[incoming.tab.id]
        previous?.use = merged.use; previous?.archive = merged.archive; previous?.kept = merged.kept
        records[incoming.tab.id] = merged
        return previous != merged
    }

    /// Starts an open tab's time, unless it has one already. Returns whether it changed.
    mutating func beginUse(of id: UUID, at date: Date) -> Bool {
        guard var record = records[id], record.closedAt == nil, record.use == nil else { return false }
        record.use = TabUse(lastUsed: date); records[id] = record
        return true
    }
    mutating func markArchived(_ id: UUID, at date: Date) -> Bool {
        guard var record = records[id], record.tab.url != nil, record.archive == nil else { return false }
        record.archive = TabArchiveMark(archivedAt: date); records[id] = record
        return true
    }
    mutating func removeFromArchive(_ id: UUID) -> Bool {
        guard var record = records[id], var mark = record.archive, !mark.isRemoved else { return false }
        mark.isRemoved = true
        record.archive = mark; records[id] = record
        return true
    }
    /// Turning it on is always heard. Only the device that turned it on can turn it off, as another
    /// has simply never had a reason for it.
    mutating func setKept(_ id: UUID, _ kept: Bool) -> Bool {
        guard var record = records[id], record.closedAt == nil else { return false }
        if kept { guard record.kept?.isKept != true else { return false } }
        else { guard let mark = record.kept, mark.isKept, mark.version.device == deviceID else { return false } }
        record.kept = TabKeptMark(isKept: kept, version: nextVersion()); records[id] = record
        return true
    }
    /// The tabs in Archived Tabs, newest first.
    func archivedTabs(at now: Date) -> [SharedArchivedTab] {
        let entries = records.values.compactMap { record -> SharedArchivedTab? in
            guard record.closedAt != nil, let mark = record.archive, !mark.isRemoved, let url = record.tab.url,
                  now.timeIntervalSince(mark.archivedAt) < SharedArchivedTab.keptFor else { return nil }
            return SharedArchivedTab(id: record.tab.id, url: url, title: record.tab.title ?? url, navigationHistory: record.tab.navigationHistory,
                                     use: record.use, archivedAt: mark.archivedAt)
        }
        return Array(entries.sorted { $0.archivedAt == $1.archivedAt ? $0.id.uuidString < $1.id.uuidString : $0.archivedAt > $1.archivedAt }
            .prefix(SharedArchivedTab.maximumCount))
    }

    /// Notes a use of an open tab, at most once in `interval`, as each one goes to iCloud.
    mutating func recordUse(of id: UUID, at date: Date, every interval: TimeInterval) -> Bool {
        guard var record = records[id], record.closedAt == nil else { return false }
        var use = record.use ?? TabUse(lastUsed: .distantPast)
        guard use.record(at: date, every: interval) else { return false }
        record.use = use; records[id] = record
        return true
    }
}
