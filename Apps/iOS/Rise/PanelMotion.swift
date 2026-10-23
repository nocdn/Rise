import UIKit

/// A scoped ProMotion request for finger tracking and the spring that follows it.
/// Measurements stay in memory until landing; no files are written on the drag path.
@MainActor final class PanelMotion {
    struct Record: Codable, Sendable {
        struct Frame: Codable, Sendable {
            var phase: String
            var t: Double, gapMS: Double, intervalMS: Double
        }
        struct Work: Codable, Sendable { var t: Double, ms: Double }
        struct Event: Codable, Sendable { var t: Double, name: String }
        var started = Date()
        var panel: String
        var maximumFPS: Int
        var lowPower: Bool
        var thermalState: Int
        var frames: [Frame] = []
        var work: [Work] = []
        var events: [Event] = []
    }
    private var link: CADisplayLink?
    private var record: Record?
    private var start = 0.0, previousVsync: Double?
    private var until: Double?
    private var phase = "drag"
    var isHoldingRate: Bool { link != nil }
    var preferredFPS: Float { link?.preferredFrameRateRange.preferred ?? 0 }
    var minimumFPS: Float { link?.preferredFrameRateRange.minimum ?? 0 }

    func begin(_ panel: BottomBar.Panel, screen: UIScreen?) {
        begin(String(describing: panel), screen: screen)
    }

    func begin(_ name: String, screen: UIScreen?, minimumFPS: Int = 80) {
        until = nil
        let maximum = min(120, screen?.maximumFramesPerSecond ?? 120)
        let range = CAFrameRateRange(minimum: Float(min(minimumFPS, maximum)), maximum: Float(maximum), preferred: Float(maximum))
        if let link { link.preferredFrameRateRange = range; phase = "drag"; return }
        start = CACurrentMediaTime(); previousVsync = nil; phase = "drag"
        record = Record(panel: name, maximumFPS: maximum,
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        thermalState: ProcessInfo.processInfo.thermalState.rawValue)
        record?.frames.reserveCapacity(240); record?.work.reserveCapacity(160)
        let link = CADisplayLink(target: FrameTicker { [weak self] in self?.tick() }, selector: #selector(FrameTicker.tick))
        link.preferredFrameRateRange = range
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func tracked(since began: Double) {
        guard let count = record?.work.count, count < 3600 else { return }
        record?.work.append(.init(t: began-start, ms: (CACurrentMediaTime()-began)*1000))
    }
    func event(_ name: String) {
        record?.events.append(.init(t: CACurrentMediaTime()-start, name: name))
    }
    func settle(for duration: Double) {
        guard link != nil else { return }
        phase = "settle"; until = CACurrentMediaTime()+duration+0.1
    }
    func stop() {
        link?.invalidate(); link = nil; until = nil
        guard let record else { return }
        self.record = nil
        Task.detached(priority: .utility) { await PanelMotionStore.shared.append(record) }
    }
    private func tick() {
        guard let link else { return }
        if let previousVsync, record?.frames.count ?? 0 < 3600 {
            record?.frames.append(.init(phase: phase, t: link.timestamp-start,
                gapMS: (link.timestamp-previousVsync)*1000, intervalMS: (link.targetTimestamp-link.timestamp)*1000))
        }
        previousVsync = link.timestamp
        if let until, CACurrentMediaTime() >= until { stop() }
    }
    isolated deinit { link?.invalidate() }
}

private actor PanelMotionStore {
    static let shared = PanelMotionStore()
    func append(_ record: PanelMotion.Record) {
        let url = URL.cachesDirectory.appendingPathComponent("Panels/log.jsonl")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record), let text = String(data: data, encoding: .utf8) else { return }
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(text)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.suffix(20).joined(separator: "\n")+"\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
