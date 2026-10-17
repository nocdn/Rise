#if DEBUG
@preconcurrency import ActivityKit
import UIKit
import WebKit

/// Uses real WKDownloads and ActivityKit on the phone. Fixture files are the only
/// records it removes; existing downloads, tabs and history are left alone.
@MainActor enum DownloadActivityAudit {
    static let argument = "-RiseDownloadActivityAudit"
    private static var pages: [WKWebView] = []
    private static var server: DownloadHTTPFixture?

    static func run() {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("DownloadActivityAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try await exercise(folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                var top = window?.rootViewController
                while let next = top?.presentedViewController { top = next }
                let state = "\(error) | app \(UIApplication.shared.applicationState.rawValue) | top \(top.map { String(describing: type(of: $0)) } ?? "none")"
                    + " | items \(MobileDownloads.shared.items.map { "\($0.name):\($0.state)" })"
                try? state.write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    private struct Failure: Error { let message: String }
    private static func exercise(_ folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ value: Bool) throws {
            checks[name] = value
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("checks.json"))
            if !value { throw Failure(message: name) }
        }
        func wait(_ what: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<400 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw Failure(message: "Timed out: \(what)")
        }
        let downloads = MobileDownloads.shared
        // The browser resets download handling, including its "Download …?" alert, in viewDidAppear.
        // Let it appear before the fixtures replace that alert with an automatic answer.
        try await wait("the browser appears") {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?
                .rootViewController?.viewIfLoaded?.window != nil
        }
        try await Task.sleep(for: .seconds(1))
        // A development reinstall can terminate the deliberately slow visual fixture.
        // Clean only its recognizable test files, never the user's other downloads.
        for file in (try? FileManager.default.contentsOfDirectory(at: MobileDownloads.folder, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("150MB-Live-Activity-Test") && file.pathExtension == "bin"
                && !downloads.items.contains(where: { $0.url == file }) {
            try? FileManager.default.removeItem(at: file)
        }
        let fixture = try DownloadHTTPFixture(); server = fixture
        try await fixture.start()
        func start(_ name: String) async throws -> MobileDownloads.Item {
            let existing = Set(downloads.items.map(\.id))
            downloads.confirm = { _, _, _, answer in answer(true) }
            let page = WKWebView(); pages.append(page)
            page.startDownload(using: URLRequest(url: fixture.url.appendingPathComponent(name))) { download in downloads.begin(download) }
            try await wait("the download is listed") { downloads.items.contains { !existing.contains($0.id) } }
            return downloads.items.first { !existing.contains($0.id) }!
        }
        func activity(_ item: MobileDownloads.Item) -> Activity<DownloadActivityAttributes>? {
            Activity.activities.first { $0.attributes.downloadID == item.id.uuidString }
        }
        typealias State = DownloadActivityAttributes.ContentState
        try check("decimal-byte-count-matches-safari", State(receivedBytes: 22_000_000, totalBytes: 157_286_400).progressText == "22.0 MB of 157.3 MB")
        try check("unknown-size-shows-only-received-bytes", State(receivedBytes: 2_400_000, totalBytes: 0).progressText == "2.4 MB")
        try check("progress-is-bounded-and-never-divides-by-zero", State(receivedBytes: -1, totalBytes: 10).fraction == 0
                  && State(receivedBytes: 20, totalBytes: 10).fraction == 1 && State(receivedBytes: 10, totalBytes: 0).fraction == 0)
        try check("live-activities-are-authorized", ActivityAuthorizationInfo().areActivitiesEnabled)
        let cancelling = try await start("cancel.bin")
        try await wait("its activity starts with progress") { activity(cancelling) != nil && cancelling.receivedBytes > 0 }
        let cancelActivity = activity(cancelling)!
        try check("accepting-a-real-download-starts-one-activity", cancelActivity.attributes.name == cancelling.name
                  && cancelActivity.activityState == .active)
        try await wait("the activity receives progress") { cancelActivity.content.state.receivedBytes > 0 }
        try check("real-network-progress-reaches-the-activity", cancelActivity.content.state.totalBytes == cancelling.totalBytes
                  && cancelActivity.content.state.receivedBytes <= cancelling.receivedBytes)
        _ = try await StopDownloadIntent(downloadID: cancelling.id.uuidString).perform()
        try await wait("stop cancels it") { downloads.item(cancelling.id) == nil && downloads.pendingCancellationCount == 0
            && cancelActivity.activityState != .active }
        try check("the-stop-intent-cancels-and-deletes-the-real-partial-file", !FileManager.default.fileExists(atPath: cancelling.url.path))
        let completed = try await start("first.bin")
        try await wait("the completed download's activity starts") { activity(completed) != nil }
        let completedActivity = activity(completed)!
        try await wait("it finishes and its activity ends") { completed.state == .finished && completedActivity.activityState == .ended }
        try check("successful-completion-ends-the-activity-with-full-progress", completedActivity.content.state.finished
                  && completedActivity.content.state.fraction == 1 && completedActivity.content.state.receivedBytes == 131_072)
        try check("successful-download-remains-on-disk", MobileDownloads.size(of: completed.url) == 131_072)
        downloads.remove(completed.id); try? FileManager.default.removeItem(at: completed.url)
        let failing = try await start("truncated.bin")
        try await wait("the truncated download fails") { failing.state == .failed }
        try await wait("its activity ends") { activity(failing) == nil || activity(failing)?.activityState != .active }
        try check("network-failure-removes-the-ring-without-reporting-success", !FileManager.default.fileExists(atPath: failing.url.path)
                  && activity(failing)?.content.state.finished != true)
        downloads.remove(failing.id)
        let first = try await start("cancel.bin"), second = try await start("cancel.bin")
        try await wait("both concurrent activities start") { activity(first) != nil && activity(second) != nil }
        _ = try await StopDownloadIntent(downloadID: first.id.uuidString).perform()
        try await wait("stop cancels the first") { downloads.item(first.id) == nil && downloads.pendingCancellationCount == 0 }
        try check("stop-affects-only-its-own-concurrent-download", downloads.item(second.id)?.state == .downloading
                  && activity(second)?.activityState == .active)
        downloads.remove(second.id)
        try await wait("the second cancels") { downloads.pendingCancellationCount == 0 }
        try check("concurrent-cancellation-cleans-both-partial-files", !FileManager.default.fileExists(atPath: first.url.path)
                  && !FileManager.default.fileExists(atPath: second.url.path))
        if ProcessInfo.processInfo.arguments.contains("-RiseDownloadActivityPreview") {
            let preview = try await start("150MB-Live-Activity-Test.bin")
            try await wait("the preview activity starts") { activity(preview) != nil }
            // A second shows both as the island's minimal views: one attached, one detached.
            if ProcessInfo.processInfo.arguments.contains("-RiseDownloadActivityMinimalPreview") {
                let second = try await start("150MB-Live-Activity-Test.bin")
                try await wait("the second preview activity starts") { activity(second) != nil }
            }
            try preview.id.uuidString.write(to: folder.appendingPathComponent("preview-id.txt"), atomically: true, encoding: .utf8)
        } else { fixture.stop(); server = nil; pages = [] }
    }
}
#endif
