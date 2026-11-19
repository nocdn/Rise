import CloudKit
import OSLog
import Foundation

/// One private CloudKit zone shared by Rise on Mac and iOS. No app authentication flow.
@MainActor public final class SharedTabsSync: CKSyncEngineDelegate {
    private static let log = Logger(subsystem: "dev.bartosz.Rise", category: "TabSync")
    public static let containerIdentifier = "iCloud.dev.bartosz.Rise"
    public static let preferenceKey = "Rise.SyncTabsWithiCloud"
    #if os(iOS)
    public static let isEnabledByDefault = false
    #else
    public static let isEnabledByDefault = true
    #endif
    private let zoneID: CKRecordZone.ID
    public enum Status: Equatable, Sendable {
        case ready, syncing, offline, noAccount, unavailable, disabled, accountChanged, storageFull
        public var message: String {
            switch self {
            case .ready: "Tabs sync automatically through your iCloud account."
            case .syncing: "Syncing tabs with iCloud…"
            case .offline: "Your changes will sync when iCloud is available again."
            case .noAccount: "Sign in to iCloud in Settings to sync tabs."
            case .unavailable: "iCloud sync is currently unavailable. Your tabs are saved on this device."
            case .disabled: "Tabs are saved on this device. Turn on iCloud sync to share them."
            case .accountChanged: "Your iCloud account changed. Turn sync on to use the new account."
            case .storageFull: "Your iCloud storage is full. Your tabs are saved on this device."
            }
        }
    }
    private struct Cache: Codable {
        var ledger = SharedTabsLedger()
        var accountID: String?
        var engineState: CKSyncEngine.State.Serialization?
        var systemFields: [UUID: Data] = [:]
        var dirtyIDs: Set<UUID> = []
        var learnedSearches: LearnedSearches.Snapshot?
        var searchSystemFields: Data?
        var searchesDirty: Bool?
        var history: SharedHistorySyncState?
        var lastStatus: String?
        var lastError: String?
    }
    nonisolated private static let searchesRecordName = "learned-site-searches"
    private var searchStore: LearnedSearches?
    private var historyStore: BrowsingHistory?
    public var onHistoryChange: (() -> Void)?
    public var onSearchesChange: (() -> Void)?
    public var onTabsChange: (([SharedBrowserTab]) -> Void)?
    /// Archived Tabs changed on another device. Follows `onTabsChange` for the same changes.
    public var onArchiveChange: (() -> Void)?
    public var onStatusChange: ((Status) -> Void)?
    public private(set) var status: Status = .ready {
        didSet {
            if oldValue != status { Self.log.notice("iCloud tab status: \(String(describing: self.status), privacy: .public)") }
            cache.lastStatus = String(describing: status)
            persist()
            onStatusChange?(status)
        }
    }
    public var isEnabled: Bool { preferences.object(forKey: Self.preferenceKey) as? Bool ?? Self.isEnabledByDefault }
    public var tabs: [SharedBrowserTab] { cache.ledger.tabs }
    public func isClosed(_ id: UUID) -> Bool { cache.ledger.records[id]?.closedAt != nil }
    private let preferences: UserDefaults
    private let cacheURL: URL
    private let cloudAvailable: Bool
    private let automaticallySync: Bool
    private let writer = DispatchQueue(label: "Rise.SharedTabs.Cache", qos: .utility)
    /// Decoded on another core while the browser is built, as it's several megabytes of JSON
    /// that nothing at launch needs before search has its keyboard. The first use waits for it.
    private var cache: Cache {
        _read { loadCache(); yield loadedCache! }
        _modify { loadCache(); yield &loadedCache! }
    }
    private var loadedCache: Cache?
    private let cacheLoad: CacheLoad
    private func loadCache() {
        if loadedCache == nil { loadedCache = cacheLoad.wait() ?? Cache() }
    }
    private final class CacheLoad: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var result: Cache?
        init(_ url: URL) {
            // The main thread may wait on this, so it runs at the main thread's priority.
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                result = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
                done.signal()
            }
        }
        func wait() -> Cache? { done.wait(); return result }
    }
    private var engine: CKSyncEngine?
    private var connection: Task<Void, Never>?
    private var generation = 0
    private var accountObserver: NSObjectProtocol?
    private var started = false
    private var archiveChanged = false

    public init(cacheURL: URL, preferences: UserDefaults = .standard,
                cloudAvailable: Bool = Bundle.main.object(forInfoDictionaryKey: "RiseCloudKitEnabled") as? Bool ?? false,
                zoneName: String = "RiseSharedTabs", automaticallySync: Bool = true) {
        zoneID = CKRecordZone.ID(zoneName: zoneName)
        self.cacheURL = cacheURL; self.preferences = preferences; self.cloudAvailable = cloudAvailable
        self.automaticallySync = automaticallySync
        cacheLoad = CacheLoad(cacheURL)
        if !isEnabled { status = .disabled }
    }

    public func start(tabs: [SharedBrowserTab], learnedSearches: LearnedSearches? = nil, browsingHistory: BrowsingHistory? = nil) {
        guard !started else { return }
        started = true
        searchStore = learnedSearches
        historyStore = browsingHistory
        restoreHistoryLearning()
        browsingHistory?.onChange = { [weak self] in self?.captureHistory() }
        captureHistory()
        capture(tabs)
        if isEnabled, self.tabs != tabs { onTabsChange?(self.tabs) }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
        connect()
    }

    public func capture(_ tabs: [SharedBrowserTab]) {
        captureSearches()
        let changed = cache.ledger.capture(tabs)
        guard !changed.isEmpty else { return }
        cache.dirtyIDs.formUnion(changed)
        persist()
        if isEnabled { enqueue(changed) }
    }

    /// How far apart a tab's uses go to iCloud: much finer than any time limit needs.
    static let useInterval: TimeInterval = 15*60
    public func recordUse(of id: UUID, at date: Date = Date()) {
        guard cache.ledger.recordUse(of: id, at: date, every: Self.useInterval) else { return }
        cache.dirtyIDs.insert(id)
        persist()
        if isEnabled { enqueue([id]) }
    }
    public func use(of id: UUID) -> TabUse? { cache.ledger.records[id]?.use }
    private func noteChanged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        cache.dirtyIDs.formUnion(ids)
        persist()
        if isEnabled { enqueue(ids) }
    }
    /// Starts the time of any of these tabs that haven't got one.
    public func beginUse(of ids: [UUID], at date: Date = Date()) {
        noteChanged(Set(ids.filter { cache.ledger.beginUse(of: $0, at: date) }))
    }
    /// The tabs every device has archived. A tab closed anywhere stays closed, so any that this
    /// device still has open is left out by the adapters.
    public func archivedTabs(at now: Date = Date()) -> [SharedArchivedTab] { cache.ledger.archivedTabs(at: now) }
    public func isArchived(_ id: UUID) -> Bool { cache.ledger.records[id]?.archive?.isRemoved == false }
    public func isRemovedFromArchive(_ id: UUID) -> Bool { cache.ledger.records[id]?.archive?.isRemoved == true }
    public func archive(_ ids: [UUID], at date: Date = Date()) {
        noteChanged(Set(ids.filter { cache.ledger.markArchived($0, at: date) }))
    }
    public func removeFromArchive(_ id: UUID) {
        noteChanged(cache.ledger.removeFromArchive(id) ? [id] : [])
    }
    /// Asks other devices to leave a tab alone, for a reason only this one knows of.
    public func setKept(_ id: UUID, _ kept: Bool) {
        noteChanged(cache.ledger.setKept(id, kept) ? [id] : [])
    }
    public func isKept(_ id: UUID) -> Bool { cache.ledger.records[id]?.kept?.isKept == true }
    /// Catches up with other devices, so a use or closure on its way isn't missed. False while
    /// iCloud is out of reach, when it's best to wait. With no iCloud to wait for, there's nothing to miss.
    public func refreshBeforeArchiving() async -> Bool {
        guard isEnabled else { return true }
        if await refreshAndWait() { return true }
        switch status {
        case .noAccount, .unavailable, .disabled, .accountChanged: return true
        default: return false
        }
    }

    public func captureSearches() {
        guard let store = searchStore else { return }
        let merged = (cache.learnedSearches ?? .init()).merging(store.snapshot)
        if isEnabled, store.merge(merged) { saveSearches(); onSearchesChange?() }
        guard cache.learnedSearches != merged else { return }
        cache.learnedSearches = merged; cache.searchesDirty = true
        persist(); if isEnabled { enqueueSearches() }
    }
    private func saveSearches() {
        do { try searchStore?.save() } catch { NSLog("Rise learned searches couldn't be saved: %@", error.localizedDescription) }
    }
    private var searchesRecordID: CKRecord.ID { .init(recordName: Self.searchesRecordName, zoneID: zoneID) }
    private func enqueueSearches() {
        guard cache.searchesDirty == true else { return }
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(searchesRecordID)])
    }
    private func mergeSearches(_ record: CKRecord) {
        guard record.recordID == searchesRecordID, let data = record["payload"] as? Data, data.count <= 1_000_000,
              let incoming = try? JSONDecoder().decode(LearnedSearches.Snapshot.self, from: data) else { return }
        let merged = (cache.learnedSearches ?? .init()).merging(incoming)
        cache.learnedSearches = merged
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive); archive.finishEncoding(); cache.searchSystemFields = archive.encodedData
        if merged != incoming { cache.searchesDirty = true; enqueueSearches() }
        if searchStore?.merge(merged) == true { saveSearches(); onSearchesChange?() }
    }
    private func receivedSearchSave(_ record: CKRecord) {
        mergeSearches(record)
        if let data = record["payload"] as? Data,
           let saved = try? JSONDecoder().decode(LearnedSearches.Snapshot.self, from: data), saved == cache.learnedSearches {
            cache.searchesDirty = false
        } else { enqueueSearches() }
    }

    /// The history store owns installation counters; the cache owns CloudKit acknowledgements.
    public func captureHistory() {
        guard let store = historyStore else { return }
        var state = cache.history ?? SharedHistorySyncState()
        let current = isEnabled ? store.snapshot : state.snapshot.merging(store.snapshot)
        guard current != state.snapshot else { return }
        let discarded = state.capture(current)
        cache.history = state
        engine?.state.remove(pendingRecordZoneChanges: discarded.map { .saveRecord(historyRecordID($0)) })
        persist(); if isEnabled { enqueueHistory() }
    }
    private func restoreHistoryLearning() {
        guard isEnabled, let snapshot = cache.history?.snapshot, historyStore?.merge(snapshot) == true else { return }
        saveHistory(); onHistoryChange?()
    }
    private func saveHistory() {
        do { try historyStore?.save() } catch { NSLog("Rise visit learning couldn't be saved: %@", error.localizedDescription) }
    }
    private func historyRecordID(_ name: String) -> CKRecord.ID { .init(recordName: name, zoneID: zoneID) }
    private func enqueueHistory() {
        engine?.state.add(pendingRecordZoneChanges: (cache.history?.dirtyIDs ?? []).map { .saveRecord(historyRecordID($0)) })
    }
    private func mergeHistory(_ record: CKRecord) {
        guard historyStore != nil, record.recordID.zoneID == zoneID, let data = record["payload"] as? Data else { return }
        var state = cache.history ?? SharedHistorySyncState()
        let previous = state.dirtyIDs
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive); archive.finishEncoding()
        let changed = state.receive(data, id: record.recordID.recordName, fields: archive.encodedData)
        cache.history = state
        engine?.state.remove(pendingRecordZoneChanges: previous.subtracting(state.dirtyIDs).map { .saveRecord(historyRecordID($0)) })
        enqueueHistory()
        if changed, historyStore?.merge(state.snapshot) == true { saveHistory(); onHistoryChange?() }
    }

    /// Called only after an adapter has installed the remote list, including deferred UI updates.
    public func acknowledge(_ tabs: [SharedBrowserTab]) { cache.ledger.observedTabs = tabs; persist() }

    public func setEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: Self.preferenceKey)
        if enabled { restoreHistoryLearning(); captureHistory() }
        connect(allowAccountChange: enabled)
    }

    public var isStarted: Bool { started }
    /// Nothing until `start`, which iOS holds back until its launch has search ready.
    public func refresh() {
        guard started, isEnabled else { return }
        guard let engine else { connect(); return }
        Task { [weak self] in _ = await self?.fetchAndSend(using: engine) }
    }

    /// Starts over with a new engine from the saved state, as a launch does, in place of one that
    /// may have gone stale while the app was suspended.
    public func reconnect() {
        guard started, isEnabled else { return }
        connect()
    }

    /// Keep a silent notification's background completion pending until its work finishes.
    public func refreshAndWait() async -> Bool {
        guard isEnabled else { return false }
        if engine == nil { connect(); await connection?.value }
        guard let engine else { return false }
        return await fetchAndSend(using: engine)
    }

    private func fetchAndSend(using engine: CKSyncEngine) async -> Bool {
        // Delegate callbacks carry CloudKit task-local state. Detach the engine call itself;
        // inheriting that state can trigger CloudKit's callback reentrancy assertion.
        let result = await Task.detached {
            do { try await engine.fetchChanges(); try await engine.sendChanges(); return Result<Void, Error>.success(()) }
            catch { return .failure(error) }
        }.value
        guard self.engine === engine, isEnabled else { return false }
        switch result {
        case .success:
            if cache.dirtyIDs.isEmpty, cache.searchesDirty != true, cache.history?.dirtyIDs.isEmpty != false { cache.lastError = nil; status = .ready }
            return true
        case .failure(let error): syncFailed(error, from: engine); return false
        }
    }

    private func syncFailed(_ error: Error, from source: CKSyncEngine) {
        guard engine === source else { return }
        Self.log.error("iCloud tab sync failed: \(error.localizedDescription, privacy: .public)")
        cache.lastError = error.localizedDescription
        status = Self.status(for: error)
    }

    /// Writes what's waiting at once and waits for it, for a suspension or a quit.
    public func flush() { writeCache(); writer.sync {} }

    private func connect(allowAccountChange: Bool = false) {
        generation += 1; let request = generation
        connection?.cancel()
        if let old = engine { engine = nil; Task.detached { await old.cancelOperations() } }
        guard started, isEnabled else { status = .disabled; return }
        guard cloudAvailable else { status = .unavailable; return }
        status = .syncing
        connection = Task { [weak self] in
            guard let self else { return }
            do {
                let container = CKContainer(identifier: Self.containerIdentifier)
                let account = try await container.accountStatus()
                guard generation == request, !Task.isCancelled else { return }
                guard account == .available else { status = account == .noAccount ? .noAccount : .unavailable; return }
                let identity = try await container.userRecordID().recordName
                guard generation == request, !Task.isCancelled else { return }
                if let previous = cache.accountID, previous != identity {
                    guard allowAccountChange else {
                        preferences.set(false, forKey: Self.preferenceKey); status = .accountChanged; return
                    }
                    let current = cache.ledger.observedTabs
                    cache = Cache(); _ = cache.ledger.capture(current)
                    cache.dirtyIDs = Set(cache.ledger.records.keys)
                    captureSearches()
                    captureHistory()
                }
                cache.accountID = identity
                var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                    stateSerialization: cache.engineState, delegate: self)
                configuration.automaticallySync = automaticallySync
                let created = CKSyncEngine(configuration)
                engine = created
                created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                enqueue(cache.dirtyIDs); enqueueSearches(); enqueueHistory()
                persist()
                if automaticallySync { refresh() }
            } catch {
                if generation == request { cache.lastError = error.localizedDescription; status = Self.status(for: error) }
            }
        }
    }

    private func enqueue(_ ids: Set<UUID>) {
        engine?.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(recordID($0)) })
    }
    private func recordID(_ id: UUID) -> CKRecord.ID { .init(recordName: id.uuidString, zoneID: zoneID) }
    /// How long changes gather before one write. A launch's sync brings a burst of them (state
    /// updates, fetched batches, status changes), and the cache holds every tab's and history
    /// entry's CloudKit fields, megabytes once a device has synced for a while.
    static let persistDelay: TimeInterval = 0.5
    private var persistPending = false
    /// Notes a change to save. Changes within `persistDelay` share one write, encoded off the main
    /// thread, so neither the keyboard nor typing waits on it. `flush` writes at once.
    private func persist() {
        guard !persistPending else { return }
        persistPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDelay) { [weak self] in
            MainActor.assumeIsolated { self?.writeCache() }
        }
    }
    private func writeCache() {
        guard persistPending else { return }
        persistPending = false
        // A copy: the main thread carries on changing its own while this one is encoded.
        nonisolated(unsafe) let snapshot = cache
        let file = cacheURL
        writer.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                #if os(iOS)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: file, options: .atomic)
                #endif
            } catch { NSLog("Rise tab sync cache couldn't be saved: %@", error.localizedDescription) }
        }
    }
    private static func status(for error: Error) -> Status {
        guard let error = error as? CKError else { return .offline }
        switch error.code {
        case .notAuthenticated: return .noAccount
        case .quotaExceeded: return .storageFull
        case .permissionFailure, .missingEntitlement, .badContainer, .badDatabase: return .unavailable
        default: return .offline
        }
    }

    nonisolated public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await receive(event, from: syncEngine)
    }

    private func receive(_ event: CKSyncEngine.Event, from source: CKSyncEngine) {
        guard isEnabled, source === engine else { return }
        switch event {
        case .stateUpdate(let event): cache.engineState = event.stateSerialization; persist()
        case .accountChange(let event):
            // A new engine announces its current account once. Recreating it for that
            // announcement would repeatedly cancel the first fetch and upload.
            switch event.changeType {
            case .signIn(let user): if user.recordName != cache.accountID { connect() }
            case .signOut: connect()
            case .switchAccounts: connect()
            @unknown default: connect()
            }
        case .fetchedRecordZoneChanges(let event):
            var changed = false
            archiveChanged = false
            for modification in event.modifications {
                if SharedHistorySyncState.recognizes(modification.record.recordID.recordName) { mergeHistory(modification.record) }
                else if modification.record.recordID == searchesRecordID { mergeSearches(modification.record) }
                else { changed = merge(modification.record) || changed }
            }
            // Ordinary closes use durable tombstones. External record/zone deletion is also a close.
            for deletion in event.deletions {
                if deletion.recordID.zoneID == zoneID, SharedHistorySyncState.recognizes(deletion.recordID.recordName) {
                    let name = deletion.recordID.recordName
                    cache.history?.systemFields[name] = nil
                    if cache.history?.payload(for: name) != nil { cache.history?.dirtyIDs.insert(name); enqueueHistory() }
                    continue
                }
                if deletion.recordID == searchesRecordID {
                    cache.searchSystemFields = nil
                    if cache.learnedSearches != nil { cache.searchesDirty = true; enqueueSearches() }
                    continue
                }
                guard deletion.recordID.zoneID == zoneID, let id = UUID(uuidString: deletion.recordID.recordName),
                      var record = cache.ledger.records[id] else { continue }
                record.closedAt = cache.ledger.nextVersion(); cache.ledger.records[id] = record
                cache.systemFields[id] = nil; cache.dirtyIDs.insert(id); enqueue([id]); changed = true
            }
            persist(); if changed { onTabsChange?(tabs) }
            if archiveChanged { onArchiveChange?() }
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == zoneID }) {
                cache.systemFields = [:]; cache.engineState = nil
                cache.searchSystemFields = nil
                cache.history?.systemFields = [:]
                if let history = cache.history {
                    cache.history?.dirtyIDs.formUnion(history.snapshot.records.keys)
                    if history.snapshot.clearedAt.clock > 0 { cache.history?.dirtyIDs.insert(SharedHistorySyncState.clearID) }
                    enqueueHistory()
                }
                if cache.learnedSearches != nil { cache.searchesDirty = true; enqueueSearches() }
                for id in Array(cache.ledger.records.keys) {
                    let version = cache.ledger.nextVersion()
                    cache.ledger.records[id]?.closedAt = version
                }
                cache.dirtyIDs = Set(cache.ledger.records.keys)
                source.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                enqueue(cache.dirtyIDs); persist(); onTabsChange?(tabs)
            }
        case .sentRecordZoneChanges(let event):
            for saved in event.savedRecords {
                if SharedHistorySyncState.recognizes(saved.recordID.recordName) { mergeHistory(saved); continue }
                if saved.recordID == searchesRecordID { receivedSearchSave(saved); continue }
                guard saved.recordID.zoneID == zoneID, let id = UUID(uuidString: saved.recordID.recordName) else { continue }
                rememberFields(saved, id: id)
                if let payload = saved["payload"] as? Data, let record = try? JSONDecoder().decode(SharedTabRecord.self, from: payload),
                   record == cache.ledger.records[id] {
                    cache.dirtyIDs.remove(id)
                } else if cache.dirtyIDs.contains(id) {
                    // This acknowledgement belongs to an older version; keep the newer
                    // navigation/closure queued even if the engine finished the old batch.
                    enqueue([id])
                }
            }
            for failure in event.failedRecordSaves {
                if SharedHistorySyncState.recognizes(failure.record.recordID.recordName) {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        if let server = failure.error.serverRecord { mergeHistory(server) }
                        enqueueHistory()
                    case .zoneNotFound:
                        cache.history?.systemFields[failure.record.recordID.recordName] = nil
                        source.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]); enqueueHistory()
                    case .unknownItem:
                        cache.history?.systemFields[failure.record.recordID.recordName] = nil; enqueueHistory()
                    default: cache.lastError = failure.error.localizedDescription; status = Self.status(for: failure.error)
                    }
                    continue
                }
                if failure.record.recordID == searchesRecordID {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        if let server = failure.error.serverRecord { mergeSearches(server) }
                        enqueueSearches()
                    case .zoneNotFound:
                        cache.searchSystemFields = nil
                        source.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]); enqueueSearches()
                    case .unknownItem: cache.searchSystemFields = nil; enqueueSearches()
                    default: cache.lastError = failure.error.localizedDescription; status = Self.status(for: failure.error)
                    }
                    continue
                }
                guard failure.record.recordID.zoneID == zoneID, let id = UUID(uuidString: failure.record.recordID.recordName) else { continue }
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord {
                        rememberFields(server, id: id)
                        _ = merge(server); onTabsChange?(tabs)
                    }
                    enqueue([id])
                case .zoneNotFound:
                    cache.systemFields[id] = nil
                    source.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]); enqueue([id])
                case .unknownItem: cache.systemFields[id] = nil; enqueue([id])
                default: cache.lastError = failure.error.localizedDescription; status = Self.status(for: failure.error)
                }
            }
            persist()
        case .didFetchRecordZoneChanges(let event):
            if let error = event.error { cache.lastError = error.localizedDescription; status = Self.status(for: error) }
        case .sentDatabaseChanges(let event):
            if let failure = event.failedZoneSaves.first { cache.lastError = failure.error.localizedDescription; status = Self.status(for: failure.error) }
        case .willFetchChanges, .willSendChanges: status = .syncing
        case .didFetchChanges, .didSendChanges: if status == .syncing { status = .ready }
        default: break
        }
    }

    private func merge(_ record: CKRecord) -> Bool {
        guard record.recordID.zoneID == zoneID, let id = UUID(uuidString: record.recordID.recordName),
              let data = record["payload"] as? Data, let incoming = try? JSONDecoder().decode(SharedTabRecord.self, from: data),
              incoming.tab.id == id, incoming.isValid else { return false }
        let archive = cache.ledger.records[id]?.archive
        let changed = cache.ledger.merge(incoming)
        if cache.ledger.records[id]?.archive != archive { archiveChanged = true }
        rememberFields(record, id: id)
        if cache.ledger.records[id] != incoming { cache.dirtyIDs.insert(id); enqueue([id]) }
        return changed
    }
    private func rememberFields(_ record: CKRecord, id: UUID) {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive); archive.finishEncoding()
        cache.systemFields[id] = archive.encodedData
    }

    nonisolated public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                                     syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let snapshot = await batchSnapshot(for: syncEngine)
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { id in
            guard let payload = snapshot.0[id.recordName] else { return nil }
            var record: CKRecord?
            if let fields = snapshot.1[id.recordName], let decoder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
                decoder.requiresSecureCoding = true; record = CKRecord(coder: decoder); decoder.finishDecoding()
            }
            let learning = id.recordName == Self.searchesRecordName || SharedHistorySyncState.recognizes(id.recordName)
            let value = record ?? CKRecord(recordType: learning ? "RiseSearches" : "RiseTab", recordID: id)
            value["payload"] = payload as CKRecordValue
            return value
        }
    }
    private func batchSnapshot(for source: CKSyncEngine) -> ([String: Data], [String: Data]) {
        guard source === engine, isEnabled else { return ([:], [:]) }
        var payloads = Dictionary(uniqueKeysWithValues: cache.ledger.records.compactMap { id, record in
            (try? JSONEncoder().encode(record)).map { (id.uuidString, $0) }
        })
        var fields = Dictionary(uniqueKeysWithValues: cache.systemFields.map { ($0.key.uuidString, $0.value) })
        if let searches = cache.learnedSearches {
            payloads[Self.searchesRecordName] = try? JSONEncoder().encode(searches)
            fields[Self.searchesRecordName] = cache.searchSystemFields
        }
        if let history = cache.history {
            for id in history.snapshot.records.keys { payloads[id] = history.payload(for: id) }
            payloads[SharedHistorySyncState.clearID] = history.payload(for: SharedHistorySyncState.clearID)
            fields.merge(history.systemFields, uniquingKeysWith: { _, newest in newest })
        }
        return (payloads, fields)
    }
}
