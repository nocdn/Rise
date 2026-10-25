import CryptoKit
import Foundation
import OSLog

/// Serial disk IO never blocks navigation decisions. Files survive relaunch and
/// app upgrades, are excluded from backup, and keep seven UTC dates / at most 8 MiB.
final class PopupLogStore: @unchecked Sendable {
    static let shared = PopupLogStore()
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RiseDiagnostics/Popups", isDirectory: true)
    }
    private let directory: URL
    private let queue = DispatchQueue(label: "Rise.PopupDiagnostics", qos: .utility)
    private let segmentBytes: Int, segmentCount: Int
    private var handle: FileHandle?, active: URL?, size = 0
    private var recent: [PopupLogRecord] = [], writeFailures = 0, runIDs = Set<String>()
    private var binaryHash: String?
    private let pendingLock = NSLock()
    private var pending = 0, queueDropped = 0, unreportedDrops = 0
    private let logger = Logger(subsystem: "dev.bartosz.Rise.iOS", category: "PopupDiagnostics")

    init(directory: URL = PopupLogStore.directory, segmentBytes: Int = 1_048_576, segmentCount: Int = 8) {
        self.directory = directory; self.segmentBytes = max(4096, segmentBytes); self.segmentCount = max(1, segmentCount)
    }
    func append(_ record: PopupLogRecord) {
        guard !record.privateMode else { return }
        pendingLock.lock()
        guard pending < 512 else { queueDropped += 1; unreportedDrops += 1; pendingLock.unlock(); return }
        pending += 1; pendingLock.unlock()
        queue.async {
            self.write(record)
            self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock()
        }
    }
    func flush() { queue.async { try? self.handle?.synchronize() } }

    func snapshot() async -> PopupLogSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.handle?.synchronize()
                var records: [PopupLogRecord] = [], unreadable = 0
                let decoder = PopupLogRecord.decoder()
                for file in self.files() {
                    guard let data = try? Data(contentsOf: file) else { unreadable += 1; continue }
                    for line in data.split(separator: 10) {
                        if let record = try? decoder.decode(PopupLogRecord.self, from: Data(line)) { records.append(record) }
                        else { unreadable += 1 }
                    }
                }
                let ids = Set(records.map(\.id))
                records += self.recent.filter { !ids.contains($0.id) }
                records = records.filter { $0.timestamp >= Self.cutoff() }.sorted { $0.timestamp < $1.timestamp }
                continuation.resume(returning: PopupLogSnapshot(schema: 1, exportedAt: Date(), privateSession: false,
                    notes: "Native decisions are authoritative. Page-world window.open observations are unverified and never authorize a window. A null handle can also mean noopener. URL credentials, query values, fragments and sensitive path segments are redacted. Seven UTC dates, capped at 8 MiB; older events rotate out.",
                    writeFailures: self.writeFailures, unreadableLines: unreadable, evictedMemoryEvents: 0, queueDroppedEvents: self.droppedCount(), events: records))
            }
        }
    }
    func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.handle?.close(); self.handle = nil; self.active = nil; self.size = 0
                    for file in self.files() { try FileManager.default.removeItem(at: file) }
                    self.recent.removeAll(); self.runIDs.removeAll(); self.writeFailures = 0
                    self.pendingLock.lock(); self.queueDropped = 0; self.unreportedDrops = 0; self.pendingLock.unlock()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func day(_ date: Date = Date()) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyyMMdd"
        return format.string(from: date)
    }
    private static func cutoff() -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
    }
    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("popups-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func write(_ input: PopupLogRecord) {
        guard !input.privateMode else { return } // Defense in depth: private records never reach disk.
        do {
            if !runIDs.contains(input.runID) {
                if binaryHash == nil, let executable = Bundle.main.executableURL,
                   let data = try? Data(contentsOf: executable, options: .mappedIfSafe) {
                    var hasher = SHA256(); hasher.update(data: data)
                    let debugLibrary = executable.appendingPathExtension("debug.dylib")
                    if let debug = try? Data(contentsOf: debugLibrary, options: .mappedIfSafe) { hasher.update(data: debug) }
                    binaryHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                }
                let info = Bundle.main.infoDictionary ?? [:]
                let session = PopupLogRecord(runID: input.runID, policyID: input.policyID, privateMode: false, event: "run.started",
                    details: ["version": info["CFBundleShortVersionString"] as? String ?? "unknown", "build": info["CFBundleVersion"] as? String ?? "unknown",
                              "binarySHA256": binaryHash ?? "unavailable", "OS": ProcessInfo.processInfo.operatingSystemVersionString,
                              "engine": "popup-policy-2-diagnostics"])
                try appendLine(PopupLogRecord.encoder().encode(session))
                runIDs.insert(input.runID)
            }
            pendingLock.lock(); let dropped = unreportedDrops; unreportedDrops = 0; pendingLock.unlock()
            if dropped > 0 {
                let summary = PopupLogRecord(runID: input.runID, policyID: input.policyID, privateMode: false, event: "log.queue_dropped", details: ["count": String(dropped)])
                try appendLine(PopupLogRecord.encoder().encode(summary))
            }
            try appendLine(PopupLogRecord.encoder().encode(input))
        } catch {
            recent.append(input); if recent.count > 256 { recent.removeFirst(recent.count-256) }
            writeFailures += 1
            try? handle?.close(); handle = nil; active = nil
            let error = error as NSError
            if writeFailures == 1 || writeFailures.isMultiple(of: 100) {
                logger.error("Popup diagnostics write failed: \(error.domain, privacy: .public) \(error.code)")
            }
        }
    }
    private func droppedCount() -> Int { pendingLock.lock(); defer { pendingLock.unlock() }; return queueDropped }
    private func appendLine(_ encoded: Data) throws {
        guard encoded.count < segmentBytes else { throw NSError(domain: "Rise.PopupDiagnostics.RecordTooLarge", code: 1) }
        let fm = FileManager.default, today = Self.day()
        if handle == nil || size+encoded.count+1 > segmentBytes || active?.lastPathComponent.hasPrefix("popups-"+today) != true {
            let canResume = handle == nil
            try handle?.close(); handle = nil
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if canResume, let last = files().last, last.lastPathComponent.hasPrefix("popups-"+today),
               let data = try? Data(contentsOf: last), data.last == 10, data.count+encoded.count+1 <= segmentBytes {
                active = last; size = data.count
            } else {
                // Never append to a partial line after a crash.
                active = directory.appendingPathComponent("popups-\(today)-\(String(format: "%020.0f", Date().timeIntervalSince1970*1_000_000))-\(UUID().uuidString.prefix(8)).jsonl")
                guard fm.createFile(atPath: active!.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                size = 0
            }
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: active!.path)
            #endif
            handle = try FileHandle(forWritingTo: active!); try handle?.seekToEnd()
            let cutoff = "popups-"+Self.day(Self.cutoff())
            var retained = files()
            for file in retained where file.lastPathComponent < cutoff { try fm.removeItem(at: file) }
            retained = files()
            for file in retained.filter({ $0 != active }).prefix(max(0, retained.count-segmentCount)) { try fm.removeItem(at: file) }
        }
        try handle?.write(contentsOf: encoded+Data([10])); size += encoded.count+1
    }
}
