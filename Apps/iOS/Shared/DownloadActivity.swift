import ActivityKit
import AppIntents
import Foundation

/// A download's Live Activity, as Safari shows one: in the Dynamic Island and on the Lock Screen.
/// Built into both the app, which starts and updates it, and the widget extension, which draws it.
struct DownloadActivityAttributes: ActivityAttributes, Sendable {
    static let downloadsURL = URL(string: "rise://downloads")!
    struct ContentState: Codable, Hashable, Sendable {
        var receivedBytes: Int64
        /// Zero when the server didn't say.
        var totalBytes: Int64
        var finished = false

        var fraction: Double { finished ? 1 : totalBytes > 0 ? min(1, max(0, Double(receivedBytes)/Double(totalBytes))) : 0 }
        /// "22.0 MB of 157.3 MB", or just what has arrived when the size isn't known.
        var progressText: String {
            if finished { return DownloadActivityAttributes.size(totalBytes) }
            guard totalBytes > 0 else { return DownloadActivityAttributes.size(receivedBytes) }
            return "\(DownloadActivityAttributes.size(receivedBytes)) of \(DownloadActivityAttributes.size(totalBytes))"
        }
    }

    var downloadID: String
    var name: String

    /// Safari's sizes: decimal units with one decimal place from a megabyte up.
    static func size(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        if value >= 1e9 { return String(format: "%.1f GB", value/1e9) }
        if value >= 1e6 { return String(format: "%.1f MB", value/1e6) }
        if value >= 1e3 { return String(format: "%.0f KB", value/1e3) }
        return "\(Int(value)) bytes"
    }
}

/// The ring's stop button: dismisses the activity and cancels the download straight away, then
/// brings Rise to the front.
struct StopDownloadIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Download"
    static let isDiscoverable = false
    /// Before iOS 26, the app can only come forward before the stop runs.
    static let openAppWhenRun = true
    /// From iOS 26, stop first in the background, then come forward.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.deferred)] }

    @Parameter(title: "Download") var downloadID: String

    init() {}
    init(downloadID: String) { self.downloadID = downloadID }

    @MainActor func perform() async throws -> some IntentResult {
        #if !RISE_WIDGET_EXTENSION
        if let id = UUID(uuidString: downloadID) { MobileDownloads.shared.remove(id) }
        #endif
        // Also covers an activity the app no longer tracks, and waits for the system to take
        // it away before Rise comes forward.
        await Self.dismiss(downloadID)
        if #available(iOS 26.0, *), systemContext.currentMode != .foreground {
            try? await continueInForeground(alwaysConfirm: false)
        }
        return .result()
    }

    nonisolated private static func dismiss(_ downloadID: String) async {
        for activity in Activity<DownloadActivityAttributes>.activities where activity.attributes.downloadID == downloadID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
