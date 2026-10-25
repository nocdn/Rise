#if DEBUG
import Foundation

@MainActor enum PopupLoggingChecks {
    private struct Failed: Error { let message: String }
    static func run() async throws -> [String] {
        var checks: [String] = []
        func check(_ passed: Bool, _ name: String) throws {
            guard passed else { throw Failed(message: name) }; checks.append(name)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PopupLogChecks-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PopupLogStore(directory: folder)
        let privateLog = PopupDiagnostics(isPrivate: true, store: store)
        for index in 0..<600 { privateLog.record("private-fixture", details: ["index": String(index)]) }
        let privateTrace = await privateLog.snapshot()
        try check(privateTrace.events.count == 512 && privateTrace.evictedMemoryEvents > 0, "Private memory is bounded with explicit eviction accounting")
        try check(!FileManager.default.fileExists(atPath: folder.path) && privateTrace.events.allSatisfy(\.privateMode), "Private traces never create disk logs or mix regular events")
        try await privateLog.clear()
        let cleared = await privateLog.snapshot()
        try check(cleared.events.isEmpty, "A private session trace can be erased")
        let log = PopupDiagnostics(isPrivate: false, store: store)
        let url = URL(string: "https://username:password@example.com/reset/path-secret?token=query-secret#fragment-secret")!
        log.record("normal-fixture", source: url, destination: url, details: ["allowed": "false", "reason": "fixture"])
        let trace = await log.snapshot()
        let text = String(decoding: try PopupLogRecord.encoder().encode(trace), as: UTF8.self)
        try check(!["username", "password", "path-secret", "query-secret", "fragment-secret"].contains(where: text.contains), "Private URL fields are scrubbed before persistence and export")
        try check(trace.events.contains { $0.event == "normal-fixture" } && trace.writeFailures == 0, "Regular traces persist asynchronously and export flushes queued events")
        let recreated = PopupLogStore(directory: folder)
        let restored = await recreated.snapshot()
        try check(restored.events.contains { $0.event == "normal-fixture" }, "On-device persistence survives logger recreation")
        let excluded = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        try check(excluded == true, "Diagnostic folder is excluded from backup")
        try check(trace.events.contains { $0.event == "run.started" && $0.details["binarySHA256"]?.count == 64 }, "Persistent runs identify the exact app binary")
        let evaluation = PopupDestinationRules.bundled.evaluate(URL(string: "https://accounts.google.com/oauth")!, from: URL(string: "https://streamtape.com/"))
        try check(!evaluation.blocked && evaluation.blockingCount > 0 && evaluation.exceptionCount > 0 && evaluation.exceptions.first?.filter != nil,
                  "Diagnostics explain an exception overriding a blocking rule")
        try await log.clear()
        return checks
    }
}
#endif
