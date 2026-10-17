@preconcurrency import ActivityKit
import OSLog
import UIKit

/// Starts while foregrounded; coalesces progress to once a second. Ending waits for
/// any in-flight update, so a late progress value can never revive a finished activity.
@MainActor final class DownloadLiveActivities {
    private final class Session {
        let activity: Activity<DownloadActivityAttributes>
        var state: DownloadActivityAttributes.ContentState
        var lastUpdate = Date()
        var task: Task<Void, Never>?
        init(_ activity: Activity<DownloadActivityAttributes>, state: DownloadActivityAttributes.ContentState) {
            self.activity = activity; self.state = state
        }
    }
    private var sessions: [UUID: Session] = [:]
    private let log = Logger(subsystem: "dev.bartosz.Rise.iOS", category: "DownloadActivity")
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        // WKDownloads do not survive process termination. Never leave their old rings running.
        let abandoned = Activity<DownloadActivityAttributes>.activities.map(\.id)
        Task { for id in abandoned { await Self.endActivity(id, content: nil, policy: .immediate) } }
    }

    func start(_ item: MobileDownloads.Item) {
        guard sessions[item.id] == nil, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState != .background else { return }
        let state = content(item)
        do {
            let activity = try Activity.request(attributes: DownloadActivityAttributes(downloadID: item.id.uuidString, name: item.name),
                content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            sessions[item.id] = Session(activity, state: state)
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish downloads") { [weak self] in
                    self?.endBackgroundTask()
                }
            }
        } catch { log.notice("Could not start download activity: \(error.localizedDescription, privacy: .public)") }
    }

    func update(_ item: MobileDownloads.Item) {
        guard let session = sessions[item.id], session.activity.activityState == .active else { return }
        session.state = content(item)
        guard session.task == nil else { return }
        session.task = Task { [weak self, weak session] in
            guard let self, let session else { return }
            let delay = max(0, 1-Date().timeIntervalSince(session.lastUpdate))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, sessions[item.id] === session else { return }
            let state = session.state
            await Self.updateActivity(session.activity.id, state: state)
            session.lastUpdate = Date()
            session.task = nil
            if session.state != state { update(item) }
        }
    }

    func end(_ item: MobileDownloads.Item, successfully: Bool) {
        guard let session = sessions.removeValue(forKey: item.id) else { return }
        let pending = session.task
        let activityID = session.activity.id
        pending?.cancel()
        var final = content(item)
        final.finished = successfully
        Task {
            // A stopped or failed download goes at once; only a finished one waits for any
            // progress already on its way, so its card ends full.
            if successfully { await pending?.value }
            await Self.endActivity(activityID, content: successfully ? final : nil,
                policy: successfully ? .after(Date().addingTimeInterval(3)) : .immediate)
            if sessions.isEmpty { endBackgroundTask() }
        }
    }

    private func content(_ item: MobileDownloads.Item) -> DownloadActivityAttributes.ContentState {
        .init(receivedBytes: max(0, item.receivedBytes), totalBytes: max(0, item.totalBytes))
    }
    // ActivityKit's handle predates Sendable. Pass immutable IDs and content across
    // executors, obtaining the handle locally for the SDK's asynchronous operations.
    nonisolated private static func updateActivity(_ id: String, state: DownloadActivityAttributes.ContentState) async {
        guard let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
    nonisolated private static func endActivity(_ id: String, content: DownloadActivityAttributes.ContentState?,
                                               policy: ActivityUIDismissalPolicy) async {
        guard let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(content.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: policy)
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask; backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
