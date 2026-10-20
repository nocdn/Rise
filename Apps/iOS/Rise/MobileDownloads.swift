import CoreHaptics
import UIKit
import WebKit

/// Downloads, kept in Rise's Downloads folder in Files (On My iPhone › Rise › Downloads). Each one
/// is asked about first, as Safari does, then streams to its file; the list remembers
/// finished downloads across launches. Removing a finished item leaves its file; cancelling
/// an active download deletes its partial file once WebKit has stopped writing.
@MainActor final class MobileDownloads: NSObject, WKDownloadDelegate {
    static let shared = MobileDownloads()

    enum State: Equatable { case downloading, finished, failed }

    final class Item {
        let id: UUID
        let url: URL
        let date: Date
        var state: State
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var bytesPerSecond: Double = 0
        fileprivate var download: WKDownload?
        fileprivate var progress: NSKeyValueObservation?
        fileprivate var sample: (time: TimeInterval, bytes: Int64)?

        init(id: UUID = UUID(), url: URL, date: Date = Date(), state: State) {
            self.id = id
            self.url = url
            self.date = date
            self.state = state
        }

        var name: String { url.lastPathComponent }
        var fraction: Double? { totalBytes > 0 ? min(1, Double(receivedBytes)/Double(totalBytes)) : nil }
    }

    static var folder: URL {
        URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }
    private static var listFile: URL {
        URL.applicationSupportDirectory.appending(path: "Downloads.json")
    }
    private let downloadsFolder: URL
    private let recordsFile: URL

    /// Newest first.
    private(set) var items: [Item] = []
    /// Downloads came, went or finished.
    var onListChange: (() -> Void)?
    /// A download's progress moved on.
    var onProgress: ((Item) -> Void)?
    /// Fires once an accepted transfer is added, preserving its original page touch.
    var onStart: ((Item, CGPoint?) -> Void)?
    /// Asks whether to download the named file, of this many bytes if known, from the host, as Safari does.
    var confirm: ((_ name: String, _ host: String?, _ bytes: Int64?, _ answer: @escaping (Bool) -> Void) -> Void)?
    var failed: ((Error) -> Void)?
    private let completionFeedback = DownloadCompletionFeedback()
    private var liveActivities: DownloadLiveActivities?

    override private init() {
        downloadsFolder = Self.folder
        recordsFile = Self.listFile
        super.init()
        load()
        liveActivities = DownloadLiveActivities()
    }
    #if DEBUG
    /// Real WebKit download audits use an isolated directory, leaving saved downloads intact.
    init(directory: URL) {
        downloadsFolder = directory.appending(path: "Downloads", directoryHint: .isDirectory)
        recordsFile = directory.appending(path: "Downloads.json")
        super.init()
        load()
    }
    var successFeedbackCount: Int { completionFeedback.requestCount }
    var pendingCancellationCount: Int { cancelling.count }
    #endif

    /// WebKit has turned a navigation into a download; ask about it once its name is known.
    func begin(_ download: WKDownload, origin: CGPoint? = nil, requiresVideoFile: Bool = false) {
        download.delegate = self
        pending.insert(ObjectIdentifier(download))
        retained[ObjectIdentifier(download)] = download
        origins[ObjectIdentifier(download)] = origin
        if requiresVideoFile { videoFiles.insert(ObjectIdentifier(download)) }
    }

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    /// Takes a download off the list, cancelling it first if it's still going. A finished file
    /// stays in Downloads.
    func remove(_ id: UUID) { remove(Set([id])) }

    /// Clears these downloads from the list, cancelling any still going. Finished files stay in Downloads.
    func remove(_ ids: Set<UUID>) {
        let removing = items.filter { ids.contains($0.id) }
        guard !removing.isEmpty else { return }
        for item in removing where item.state == .downloading {
            liveActivities?.end(item, successfully: false)
            item.progress = nil
            if let download = item.download {
                let key = ObjectIdentifier(download)
                // Keep the destination reserved and the transfer alive until cancellation
                // finishes. Removing its row must not make a late write an orphaned file.
                cancelling[key] = CancelledDownload(download: download, destination: item.url)
                download.cancel { [weak self] _ in
                    guard let self, let cancelled = cancelling[key] else { return }
                    try? FileManager.default.removeItem(at: cancelled.destination)
                    cancelling[key] = nil
                }
            } else {
                try? FileManager.default.removeItem(at: item.url)
            }
            item.download = nil
        }
        items.removeAll { ids.contains($0.id) }
        save()
        onListChange?()
    }

    /// Clears the list, cancelling any downloads still going. Finished files stay in Downloads.
    func removeAll() { remove(Set(items.map(\.id))) }

    // MARK: WKDownloadDelegate

    private var pending: Set<ObjectIdentifier> = []
    private var retained: [ObjectIdentifier: WKDownload] = [:]
    private var origins: [ObjectIdentifier: CGPoint] = [:]
    private var videoFiles: Set<ObjectIdentifier> = []

    static func isVideoFile(_ response: URLResponse) -> Bool {
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) { return false }
        let type = response.mimeType?.lowercased() ?? ""
        return !type.contains("mpegurl") && !type.contains("dash+xml") &&
            (type.hasPrefix("video/") || ["application/mp4", "application/octet-stream", "binary/octet-stream"].contains(type))
    }
    private struct CancelledDownload {
        let download: WKDownload
        let destination: URL
    }
    private var cancelling: [ObjectIdentifier: CancelledDownload] = [:]

    /// A terminal callback can precede the cancellation completion. Clean up here too,
    /// keeping the path reserved until cancel's completion confirms that writing stopped.
    private func discardCancelledFile(for download: WKDownload) -> Bool {
        guard let cancelled = cancelling[ObjectIdentifier(download)] else { return false }
        try? FileManager.default.removeItem(at: cancelled.destination)
        return true
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        if videoFiles.remove(key) != nil, !Self.isVideoFile(response) {
            pending.remove(key); retained[key] = nil; origins[key] = nil
            completionHandler(nil)
            failed?(NSError(domain: "Rise.VideoDownload", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This address doesn't provide a downloadable video file."]))
            return
        }
        let name = Self.cleanName(suggestedFilename)
        let host = download.originalRequest?.url?.host() ?? response.url?.host()
        let start = { [weak self] (accepted: Bool) in
            guard let self else { completionHandler(nil); return }
            let key = ObjectIdentifier(download)
            pending.remove(key)
            retained[key] = nil
            let origin = origins.removeValue(forKey: key)
            guard accepted else { completionHandler(nil); return }
            try? FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
            let destination = Self.destination(for: name, in: downloadsFolder) { url in
                self.items.contains { $0.url == url } || self.cancelling.values.contains { $0.destination == url }
                    || FileManager.default.fileExists(atPath: url.path)
            }
            let item = Item(url: destination, state: .downloading)
            item.totalBytes = max(0, response.expectedContentLength)
            item.download = download
            items.insert(item, at: 0)
            observe(download.progress, for: item)
            onListChange?()
            if self.item(item.id) === item { onStart?(item, origin) }
            if self.item(item.id) === item { liveActivities?.start(item) }
            // List callbacks can immediately cancel. Never hand WebKit a destination
            // for an item that was already removed before the file could be created.
            completionHandler(self.item(item.id) === item ? destination : nil)
        }
        let bytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let confirm { confirm(name, host, bytes, start) } else { start(true) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !discardCancelledFile(for: download) else { return }
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.download = nil
        item.progress = nil
        item.state = .finished
        item.bytesPerSecond = 0
        item.totalBytes = Self.size(of: item.url)
        item.receivedBytes = item.totalBytes
        liveActivities?.end(item, successfully: true)
        save()
        onListChange?()
        completionFeedback.play()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        videoFiles.remove(key)
        pending.remove(key)
        retained[key] = nil
        origins[key] = nil
        guard !discardCancelledFile(for: download) else { return }
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.download = nil
        item.progress = nil
        item.state = .failed
        item.bytesPerSecond = 0
        try? FileManager.default.removeItem(at: item.url)
        liveActivities?.end(item, successfully: false)
        onListChange?()
        if (error as NSError).code != NSURLErrorCancelled { failed?(error) }
    }

    private func observe(_ progress: Progress, for item: Item) {
        let id = item.id
        item.progress = progress.observe(\.completedUnitCount, options: [.initial]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in
                guard let self, let item = self.item(id), item.state == .downloading else { return }
                self.update(item, received: received, total: total)
            }
        }
    }

    /// Progress arrives many times a second; the speed is smoothed over about a second.
    private func update(_ item: Item, received: Int64, total: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        item.receivedBytes = received
        if total > 0 { item.totalBytes = total }
        if let sample = item.sample {
            let elapsed = now-sample.time
            guard elapsed >= 0.25 else { return }
            let speed = Double(received-sample.bytes)/elapsed
            item.bytesPerSecond = item.bytesPerSecond == 0 ? speed : item.bytesPerSecond*0.6+speed*0.4
        }
        item.sample = (now, received)
        liveActivities?.update(item)
        onProgress?(item)
    }

    // MARK: Files

    static func cleanName(_ suggested: String) -> String {
        let name = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }

    /// Names already in use, on disk or by another download, get a number, as on the Mac.
    static func destination(for name: String, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name), number = 2
        while isTaken(candidate) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private struct Record: Codable {
        let id: UUID
        /// Within the Downloads folder, as the app's container moves between installs.
        let name: String
        let date: Date
    }

    private func load() {
        guard let data = try? Data(contentsOf: recordsFile),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        items = records.compactMap { record in
            let url = downloadsFolder.appending(path: record.name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let item = Item(id: record.id, url: url, date: record.date, state: .finished)
            item.totalBytes = Self.size(of: url)
            item.receivedBytes = item.totalBytes
            return item
        }
    }

    private func save() {
        let records = items.filter { $0.state == .finished }.map { Record(id: $0.id, name: $0.name, date: $0.date) }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: recordsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: recordsFile, options: .atomic)
    }
}

/// Success's rising feedback, with three brief pulses instead of the system's two-pulse pattern.
@MainActor final class DownloadCompletionFeedback {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var queued = 0
    private var playback: Task<Void, Never>?
    #if DEBUG
    private(set) var requestCount = 0
    #endif
    static func pattern() throws -> CHHapticPattern {
        let pulses: [(time: TimeInterval, intensity: Float, sharpness: Float)] = [
            (0, 0.35, 0.25), (0.08, 0.60, 0.35), (0.18, 0.95, 0.45),
        ]
        return try CHHapticPattern(events: pulses.map { pulse in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
            ], relativeTime: pulse.time)
        }, parameters: [])
    }
    func play() {
        #if DEBUG
        requestCount += 1
        #endif
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        queued += 1
        guard playback == nil else { return }
        // Near-simultaneous finishes each get their own pattern instead of mixing into
        // three stronger pulses. Keep the player alive through all three events.
        playback = Task { [weak self] in
            while let self, queued > 0 {
                queued -= 1
                playOne()
                try? await Task.sleep(for: .milliseconds(320))
            }
            self?.player = nil
            self?.playback = nil
        }
    }
    private func playOne() {
        do {
            if engine == nil {
                let next = try CHHapticEngine()
                next.playsHapticsOnly = true
                next.isAutoShutdownEnabled = true
                next.resetHandler = { [weak self] in Task { @MainActor in self?.engine = nil; self?.player = nil } }
                engine = next
            }
            guard let engine else { return }
            try engine.start()
            player = try engine.makePlayer(with: Self.pattern())
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch { engine = nil; player = nil }
    }
}
