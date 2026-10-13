import UIKit
import WebKit

/// Downloads, kept in Rise's Downloads folder in Files (On My iPhone › Rise › Downloads). Each one
/// is asked about first, as Safari does, then runs without any animation; the list remembers
/// finished downloads across launches. Removing one takes it off the list and leaves the file.
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

    /// Newest first.
    private(set) var items: [Item] = []
    /// Downloads came, went or finished.
    var onListChange: (() -> Void)?
    /// A download's progress moved on.
    var onProgress: ((Item) -> Void)?
    /// Asks whether to download the named file, of this many bytes if known, from the host, as Safari does.
    var confirm: ((_ name: String, _ host: String?, _ bytes: Int64?, _ answer: @escaping (Bool) -> Void) -> Void)?
    var failed: ((Error) -> Void)?

    override private init() {
        super.init()
        load()
    }

    /// WebKit has turned a navigation into a download; ask about it once its name is known.
    func begin(_ download: WKDownload) {
        download.delegate = self
        pending.insert(ObjectIdentifier(download))
        retained[ObjectIdentifier(download)] = download
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
            item.progress = nil
            let partial = item.url
            item.download?.cancel { _ in try? FileManager.default.removeItem(at: partial) }
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

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let name = Self.cleanName(suggestedFilename)
        let host = download.originalRequest?.url?.host() ?? response.url?.host()
        let start = { [weak self] (accepted: Bool) in
            guard let self else { completionHandler(nil); return }
            let key = ObjectIdentifier(download)
            pending.remove(key)
            retained[key] = nil
            guard accepted else { completionHandler(nil); return }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let destination = Self.destination(for: name, in: Self.folder) { url in
                self.items.contains { $0.url == url } || FileManager.default.fileExists(atPath: url.path)
            }
            let item = Item(url: destination, state: .downloading)
            item.totalBytes = max(0, response.expectedContentLength)
            item.download = download
            items.insert(item, at: 0)
            observe(download.progress, for: item)
            onListChange?()
            completionHandler(destination)
        }
        let bytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let confirm { confirm(name, host, bytes, start) } else { start(true) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.download = nil
        item.progress = nil
        item.state = .finished
        item.bytesPerSecond = 0
        item.totalBytes = Self.size(of: item.url)
        item.receivedBytes = item.totalBytes
        save()
        onListChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        pending.remove(key)
        retained[key] = nil
        guard let item = items.first(where: { $0.download === download }) else { return }
        item.download = nil
        item.progress = nil
        item.state = .failed
        item.bytesPerSecond = 0
        try? FileManager.default.removeItem(at: item.url)
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
        guard let data = try? Data(contentsOf: Self.listFile),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        items = records.compactMap { record in
            let url = Self.folder.appending(path: record.name)
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
        try? FileManager.default.createDirectory(at: Self.listFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.listFile, options: .atomic)
    }
}
