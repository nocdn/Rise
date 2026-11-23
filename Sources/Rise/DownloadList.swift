import AppKit

/// Pauses, resumes and cancels one engine's download for the list.
@MainActor protocol DownloadControl: AnyObject {
    func togglePause()
    func cancel()
}

struct DownloadRecord: Codable, Equatable {
    var id = UUID()
    var path: String
    var date = Date()
    var url: URL { URL(fileURLWithPath: path) }
}

/// Finished records persist; live transfers keep their row, identity and byte counts
/// across pause/resume, even before their destination file exists.
@MainActor final class DownloadList {
    final class Item {
        enum State { case downloading, pausing, paused, resuming, cancelling, finished }
        let record: DownloadRecord
        fileprivate(set) var progress: Progress?
        fileprivate(set) var state: State
        fileprivate(set) var receivedBytes: Int64 = 0, totalBytes: Int64 = 0
        fileprivate(set) var bytesPerSecond: Double = 0
        private var previousBytes: Int64 = 0
        private var previousTime = ProcessInfo.processInfo.systemUptime
        fileprivate var resumeBase: Int64 = 0
        init(record: DownloadRecord, progress: Progress?) {
            self.record = record; self.progress = progress
            state = progress == nil ? .finished : .downloading
        }
        var isFinished: Bool { state == .finished }
        var showsResume: Bool { state == .paused || state == .pausing }
        var canTogglePause: Bool { state == .downloading || state == .paused }
        var fraction: Double? { totalBytes > 0 ? min(1, Double(receivedBytes)/Double(totalBytes)) : nil }
        fileprivate func readProgress() {
            guard let progress else { return }
            let total = max(0, progress.totalUnitCount)
            // Some resumed tasks report only the remaining response bytes.
            let offset = resumeBase > 0 && total > 0 && total <= totalBytes-resumeBase ? resumeBase : 0
            totalBytes = max(totalBytes, total+offset)
            receivedBytes = max(receivedBytes, max(0, progress.completedUnitCount)+offset)
        }
        fileprivate func sample(at now: TimeInterval) {
            readProgress()
            guard state == .downloading, now > previousTime else { return }
            let rate = Double(max(0, receivedBytes-previousBytes))/(now-previousTime)
            bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond*0.65 + rate*0.35
            previousBytes = receivedBytes; previousTime = now
        }
        fileprivate func resetRate() {
            bytesPerSecond = 0; previousBytes = receivedBytes; previousTime = ProcessInfo.processInfo.systemUptime
        }
    }
    private(set) var items: [Item] = []
    private let storeURL: URL
    private var transfers: [UUID: DownloadControl] = [:]
    private var timer: Timer?
    var onChange: (() -> Void)?
    var onFinish: ((Item) -> Void)?
    static let limit = 200

    init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL), let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            items = records.map { Item(record: $0, progress: nil) }
        }
    }
    var visible: [Item] { items.filter { !$0.isFinished || FileManager.default.fileExists(atPath: $0.record.path) } }
    var pendingDestinations: Set<URL> { Set(items.filter { !$0.isFinished }.map { $0.record.url }) }
    @discardableResult func begin(_ url: URL, progress: Progress?) -> UUID {
        let item = Item(record: DownloadRecord(path: url.path), progress: progress ?? Progress(totalUnitCount: -1))
        item.readProgress(); items.insert(item, at: 0); changed()
        return item.record.id
    }
    /// A new row for a download saving to `destination`, run by the control `make` gives.
    func track(at destination: URL, progress: Progress, expectedBytes: Int64, control make: (Item, DownloadList) -> DownloadControl) {
        let id = begin(destination, progress: progress)
        let item = items.first { $0.record.id == id }!
        item.totalBytes = max(item.totalBytes, expectedBytes)
        transfers[id] = make(item, self)
    }
    func togglePause(_ id: UUID) { transfers[id]?.togglePause() }
    func cancel(_ id: UUID) { transfers[id]?.cancel() }
    func setState(_ state: Item.State, for id: UUID) {
        guard let item = items.first(where: { $0.record.id == id }), !item.isFinished else { return }
        item.readProgress(); item.state = state; item.resetRate(); changed()
    }
    func resume(_ id: UUID, progress: Progress, restarting: Bool) {
        guard let item = items.first(where: { $0.record.id == id }), !item.isFinished else { return }
        item.resumeBase = restarting ? 0 : item.receivedBytes
        if restarting { item.receivedBytes = 0; item.totalBytes = 0 }
        item.progress = progress; item.state = .downloading; item.resetRate(); changed()
    }
    func finish(_ id: UUID) {
        guard let item = items.first(where: { $0.record.id == id }), !item.isFinished else { return }
        item.readProgress(); item.progress = nil; item.state = .finished; item.bytesPerSecond = 0
        transfers[id] = nil; save(); onFinish?(item); changed()
    }
    /// Clears the list entry only; the completed file stays on disk.
    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.record.id == id }), item.isFinished else { return }
        items.removeAll { $0.record.id == id }; save(); changed()
    }
    /// Takes the entry off the list at once, as `remove` does, and moves its file to the Trash
    /// behind it; if that fails, the entry comes back where it was and `completion` has the error.
    func deleteFromDisk(_ id: UUID, completion: ((Error?) -> Void)? = nil) {
        guard let index = items.firstIndex(where: { $0.record.id == id }), items[index].isFinished else { return }
        let item = items[index], url = item.record.url
        items.remove(at: index); save(); changed()
        Task { [weak self] in
            let failure = await Self.trash(url)
            if let failure, let self, !self.items.contains(where: { $0.record.id == id }) {
                self.items.insert(item, at: min(index, self.items.count)); self.save(); self.changed()
            }
            completion?(failure)
        }
    }
    /// Off the main thread, where moving a file to the Trash can take a moment.
    private nonisolated static func trash(_ url: URL) async -> Error? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); return nil } catch { return error }
    }
    func fail(_ id: UUID) {
        transfers[id] = nil; items.removeAll { $0.record.id == id }; changed()
    }
    /// Sample at a bounded rate rather than rebuilding the UI for every network chunk.
    func sample(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        items.filter { !$0.isFinished }.forEach { $0.sample(at: now) }; onChange?()
    }
    private func changed() {
        if items.contains(where: { $0.state == .downloading }) {
            if timer == nil {
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        } else { timer?.invalidate(); timer = nil }
        onChange?()
    }
    private func save() {
        nonisolated(unsafe) let records = Array(items.filter(\.isFinished).prefix(Self.limit).map(\.record))
        BackgroundFiles.write(to: storeURL, failed: { error in NSLog("Rise downloads save failed: %@", error.localizedDescription) }) {
            try JSONEncoder().encode(records)
        }
    }
    deinit { timer?.invalidate() }
}
