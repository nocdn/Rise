import Foundation

/// Runs the production redactor/matcher/store on Foundation without XCTest's
/// Simulator service. Real WebKit/isolated-world assertions also run in the app audit.
@main struct PopupLoggingTests {
    struct Failure: Error { let message: String }
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(message: message) }; checks += 1
        }
        let url = URL(string: "https://username:password@example.com/reset/short-secret/article?token=secret-query&code=abc&q=private-search#private-fragment")!
        let redacted = PopupLogURL.describe(url)!
        for secret in ["username", "password", "short-secret", "secret-query", "abc", "private-search", "private-fragment"] {
            try check(!redacted.contains(secret), "Redacted "+secret)
        }
        try check(redacted.contains("example.com") && redacted.contains("article") && redacted.contains("token="), "Useful route and parameter names retained")
        for value in ["data:text/plain,do-not-log", "file:///private/secret-file", "blob:https://example.com/secret-blob-id"] {
            let output = PopupLogURL.describe(URL(string: value))!
            try check(!output.contains("do-not-log") && !output.contains("secret-file") && !output.contains("secret-blob-id"), "Opaque payload and local paths redacted")
        }
        try check(PopupLogURL.fingerprint(url) == PopupLogURL.fingerprint(url), "Stable per-run correlation")
        try check(PopupLogURL.fingerprint(URL(string: "https://example.com/?token=a")) != PopupLogURL.fingerprint(URL(string: "https://example.com/?token=b")), "Different hidden query values remain distinguishable")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RisePopupLogTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PopupLogStore(directory: folder, segmentBytes: 4096, segmentCount: 3)
        func event(_ name: String, privateMode: Bool = false) -> PopupLogRecord {
            PopupLogRecord(runID: "test-run", policyID: "test-policy", privateMode: privateMode, event: name, source: url, details: ["reason": "fixture", "padding": String(repeating: "x", count: 700)])
        }
        store.append(event("private-secret", privateMode: true))
        let noPrivate = await store.snapshot()
        try check(noPrivate.events.isEmpty && !FileManager.default.fileExists(atPath: folder.path), "Private input never creates persistent storage")
        store.append(event("persisted"))
        let first = await store.snapshot()
        try check(first.events.contains { $0.event == "persisted" } && first.writeFailures == 0, "Queued append flushed before snapshot")
        let reopened = PopupLogStore(directory: folder, segmentBytes: 4096, segmentCount: 3)
        let recovered = await reopened.snapshot()
        try check(recovered.events.contains { $0.event == "persisted" }, "Survives store recreation / app restart")
        reopened.append(event("after-relaunch"))
        let after = await reopened.snapshot()
        try check(after.events.contains { $0.event == "after-relaunch" }, "Can append after reopening")
        for index in 0..<45 { reopened.append(event("rotate-\(index)")) }
        let rotated = await reopened.snapshot()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        try check(files.count <= 3, "File count bounded")
        let bytes = try files.reduce(0) { try $0+($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        try check(bytes <= 3*4096 && rotated.events.count < 45, "Disk bytes and retained events bounded")
        try check(rotated.events.contains { $0.event == "rotate-44" }, "Latest event survives rotation")
        try "{}".write(to: folder.appendingPathComponent("popups-20000101-stale.jsonl"), atomically: true, encoding: .utf8)
        let aged = PopupLogStore(directory: folder, segmentBytes: 4096, segmentCount: 3)
        // Force a new day/segment boundary by filling the existing segment.
        for index in 0..<8 { aged.append(event("age-\(index)")) }
        _ = await aged.snapshot()
        try check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("popups-20000101-stale.jsonl").path), "Old UTC date removed")
        let corrupt = folder.appendingPathComponent("popups-99999999-partial.jsonl")
        try "{truncated".write(to: corrupt, atomically: true, encoding: .utf8)
        let damaged = await aged.snapshot()
        try check(damaged.unreadableLines == 1 && !damaged.events.isEmpty, "Corrupt tail is reported and valid events remain readable")
        let export = try PopupLogRecord.encoder().encode(damaged)
        let text = String(decoding: export, as: UTF8.self)
        try check(!text.contains("secret-query") && !text.contains("short-secret"), "Export remains redacted")
        let badPath = folder.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: badPath)
        let failing = PopupLogStore(directory: badPath)
        failing.append(event("disk-failure"))
        let fallback = await failing.snapshot()
        try check(fallback.writeFailures == 1 && fallback.events.contains { $0.event == "disk-failure" }, "Disk errors visible with bounded memory fallback")
        try await aged.clear()
        let cleared = await aged.snapshot()
        try check(cleared.events.isEmpty, "Clear removes records and in-memory fallback")
        print("Passed \(checks) production redaction, persistence, rotation, corruption, and IO-failure checks")
    }
}
