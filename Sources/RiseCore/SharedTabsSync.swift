import CloudKit
import OSLog
import Foundation

/// One private CloudKit zone shared by Rise on Mac and iOS. No app authentication flow.
@MainActor public final class SharedTabsSync: CKSyncEngineDelegate {
    private static let log = Logger(subsystem: "dev.bartosz.Rise", category: "TabSync")
    public static let containerIdentifier = "iCloud.dev.bartosz.Rise"
    public static let preferenceKey = "Rise.SyncTabsWithiCloud"
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
        var lastStatus: String?
        var lastError: String?
    }
    public var onTabsChange: (([SharedBrowserTab]) -> Void)?
    public var onStatusChange: ((Status) -> Void)?
    public private(set) var status: Status = .ready {
        didSet {
            if oldValue != status { Self.log.notice("iCloud tab status: \(String(describing: self.status), privacy: .public)") }
            cache.lastStatus = String(describing: status)
            persist()
            onStatusChange?(status)
        }
    }
    public var isEnabled: Bool { preferences.object(forKey: Self.preferenceKey) as? Bool ?? true }
    public var tabs: [SharedBrowserTab] { cache.ledger.tabs }
    public func isClosed(_ id: UUID) -> Bool { cache.ledger.records[id]?.closedAt != nil }
    private let preferences: UserDefaults
    private let cacheURL: URL
    private let cloudAvailable: Bool
    private let automaticallySync: Bool
    private let writer = DispatchQueue(label: "Rise.SharedTabs.Cache", qos: .utility)
    private var cache: Cache
    private var engine: CKSyncEngine?
    private var connection: Task<Void, Never>?
    private var generation = 0
    private var accountObserver: NSObjectProtocol?
    private var started = false

    public init(cacheURL: URL, preferences: UserDefaults = .standard,
                cloudAvailable: Bool = Bundle.main.object(forInfoDictionaryKey: "RiseCloudKitEnabled") as? Bool ?? false,
                zoneName: String = "RiseSharedTabs", automaticallySync: Bool = true) {
        zoneID = CKRecordZone.ID(zoneName: zoneName)
        self.cacheURL = cacheURL; self.preferences = preferences; self.cloudAvailable = cloudAvailable
        self.automaticallySync = automaticallySync
        cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
    }

    public func start(tabs: [SharedBrowserTab]) {
        guard !started else { return }
        started = true
        capture(tabs)
        if isEnabled, self.tabs != tabs { onTabsChange?(self.tabs) }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
        connect()
    }

    public func capture(_ tabs: [SharedBrowserTab]) {
        let changed = cache.ledger.capture(tabs)
        guard !changed.isEmpty else { return }
        cache.dirtyIDs.formUnion(changed)
        persist()
        if isEnabled { enqueue(changed) }
    }

    /// Called only after an adapter has installed the remote list, including deferred UI updates.
    public func acknowledge(_ tabs: [SharedBrowserTab]) { cache.ledger.observedTabs = tabs; persist() }

    public func setEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: Self.preferenceKey)
        connect(allowAccountChange: enabled)
    }

    public func refresh() {
        guard isEnabled else { return }
        guard let engine else { connect(); return }
        Task { [weak self] in _ = await self?.fetchAndSend(using: engine) }
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
            if cache.dirtyIDs.isEmpty { cache.lastError = nil; status = .ready }
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

    public func flush() { writer.sync {} }

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
                }
                cache.accountID = identity
                var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                    stateSerialization: cache.engineState, delegate: self)
                configuration.automaticallySync = automaticallySync
                let created = CKSyncEngine(configuration)
                engine = created
                created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                enqueue(cache.dirtyIDs)
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
    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let file = cacheURL
        writer.async {
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
            for modification in event.modifications { changed = merge(modification.record) || changed }
            // Ordinary closes use durable tombstones. External record/zone deletion is also a close.
            for deletion in event.deletions {
                guard deletion.recordID.zoneID == zoneID, let id = UUID(uuidString: deletion.recordID.recordName),
                      var record = cache.ledger.records[id] else { continue }
                record.closedAt = cache.ledger.nextVersion(); cache.ledger.records[id] = record
                cache.systemFields[id] = nil; cache.dirtyIDs.insert(id); enqueue([id]); changed = true
            }
            persist(); if changed { onTabsChange?(tabs) }
        case .fetchedDatabaseChanges(let event):
            if event.deletions.contains(where: { $0.zoneID == zoneID }) {
                cache.systemFields = [:]; cache.engineState = nil
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
        let changed = cache.ledger.merge(incoming)
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
            guard let uuid = UUID(uuidString: id.recordName), let payload = snapshot.0[uuid] else { return nil }
            var record: CKRecord?
            if let fields = snapshot.1[uuid], let decoder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
                decoder.requiresSecureCoding = true; record = CKRecord(coder: decoder); decoder.finishDecoding()
            }
            let value = record ?? CKRecord(recordType: "RiseTab", recordID: id)
            value["payload"] = payload as CKRecordValue
            return value
        }
    }
    private func batchSnapshot(for source: CKSyncEngine) -> ([UUID: Data], [UUID: Data]) {
        guard source === engine, isEnabled else { return ([:], [:]) }
        return (cache.ledger.records.compactMapValues { try? JSONEncoder().encode($0) }, cache.systemFields)
    }
}
