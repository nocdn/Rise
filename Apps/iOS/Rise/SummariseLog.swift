import UIKit
import os

/// How one Summarise ran, frame by frame, kept on the device so a choppy one can be looked at
/// afterwards: `scripts/summarise-log.py` fetches and reads the last few.
struct SummariseRecord: Codable, Sendable {
    struct Frame: Codable, Sendable {
        /// Seconds into the scene, at the vsync before this frame.
        var t: Double
        var phase: String
        /// Since the vsync before the previous frame, and the display's frame interval then, in ms:
        /// a gap of two intervals or more means a frame was dropped.
        var gap: Double
        var interval: Double
        /// How late after its vsync the frame's callback ran, and how long its work took, in ms.
        var late: Double
        var work: Double
    }
    struct Event: Codable, Sendable {
        var t: Double
        var name: String
        var detail: String
    }

    var started: Date
    var path: String
    var page: String
    var device: String
    var frames: [Frame] = []
    var events: [Event] = []
}

/// Notes a scene's frames and what happened when, and saves it once the scene is over.
@MainActor final class SummariseLog {
    private static let logger = Logger(subsystem: "dev.bartosz.Rise.iOS", category: "Summarise")
    private static let signposter = OSSignposter(logger: logger)
    /// Every frame of these is kept; of the others, only the dropped ones.
    private static let detailed: Set<String> = ["pinch", "cancel", "flight", "reveal", "close", "after"]
    /// How long the page is watched after the scene ends, as it takes over from the card.
    private static let afterwards = 0.5

    private var record: SummariseRecord
    private let clock0 = CACurrentMediaTime()
    private var lastVsync: CFTimeInterval?
    private var closing: OSSignpostIntervalState?
    private var after: CADisplayLink?
    private var afterUntil = 0.0

    init(path: String, page: String) {
        let screen = UIScreen.main, process = ProcessInfo.processInfo
        let device = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion), up to \(screen.maximumFramesPerSecond) fps, "
            + "thermal \(Self.describe(process.thermalState)), low power \(process.isLowPowerModeEnabled)"
        record = SummariseRecord(started: Date(), path: path, page: page, device: device)
        event("start", "\(path) on \(page); \(device)")
    }

    var now: Double { CACurrentMediaTime()-clock0 }

    func event(_ name: String, _ detail: String = "") {
        record.events.append(.init(t: now, name: name, detail: detail))
        Self.logger.debug("\(name, privacy: .public) \(detail, privacy: .public)")
        switch name {
        case "close": closing = Self.signposter.beginInterval("Close")
        case "finish": if let closing { Self.signposter.endInterval("Close", closing); self.closing = nil }
        default: break
        }
    }

    /// One frame of the scene: its vsync and the next, and when its work started and ended.
    func frame(phase: String, vsync: CFTimeInterval, target: CFTimeInterval, started: CFTimeInterval, ended: CFTimeInterval) {
        defer { lastVsync = vsync }
        guard let lastVsync else { return }
        let interval = (target-vsync)*1000, gap = (vsync-lastVsync)*1000
        guard Self.detailed.contains(phase) || gap > interval*1.5 else { return }
        record.frames.append(.init(t: vsync-clock0, phase: phase, gap: gap, interval: interval,
                                   late: (started-vsync)*1000, work: (ended-started)*1000))
    }

    /// Watches the page's frames for a moment as it takes over, then saves the record.
    func finish() {
        lastVsync = nil
        afterUntil = now+Self.afterwards
        // The link holds on to the log, the scene gone, until it's done.
        let link = CADisplayLink(target: FrameTicker { [self] in watchAfter() }, selector: #selector(FrameTicker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        after = link
    }

    private func watchAfter() {
        guard let after else { return }
        let started = CACurrentMediaTime()
        frame(phase: "after", vsync: after.timestamp, target: after.targetTimestamp, started: started, ended: started)
        guard now >= afterUntil else { return }
        after.invalidate()
        self.after = nil
        let record = record
        Task.detached(priority: .utility) { await SummariseLogStore.shared.append(record) }
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// The last few records, a JSON object a line, in the app's caches.
actor SummariseLogStore {
    static let shared = SummariseLogStore()
    static let kept = 40
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Summarise", isDirectory: true).appendingPathComponent("log.jsonl")
    }

    func append(_ record: SummariseRecord) {
        let url = Self.url
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let line = try? encoder.encode(record), let text = String(data: line, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(text)
        try? (lines.suffix(Self.kept).joined(separator: "\n")+"\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
