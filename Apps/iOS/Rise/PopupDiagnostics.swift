import Foundation
import UIKit

@MainActor final class PopupDiagnostics {
    static let runID = UUID().uuidString
    let policyID = UUID().uuidString
    let isPrivate: Bool
    private let store: PopupLogStore
    private var memory: [PopupLogRecord] = [], evicted = 0
    private var backgroundObserver: NSObjectProtocol?

    init(isPrivate: Bool, store: PopupLogStore = .shared) {
        self.isPrivate = isPrivate; self.store = store
        if !isPrivate {
            backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { _ in store.flush() }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        record("policy.session_started", details: ["version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown", "OS": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": "popup-policy-2-diagnostics"])
    }
    isolated deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }

    func record(_ event: String, pageID: String? = nil, documentID: String? = nil, chainID: String? = nil, requestID: String? = nil,
                source: URL? = nil, destination: URL? = nil, frame: URL? = nil,
                details: [String: String] = [:], rules: PopupDestinationRules.Evaluation? = nil) {
        let record = PopupLogRecord(runID: Self.runID, policyID: policyID, privateMode: isPrivate, event: event,
            pageID: pageID, documentID: documentID, chainID: chainID, requestID: requestID,
            source: source, destination: destination, frame: frame, details: details, rules: rules)
        if isPrivate {
            memory.append(record)
            if memory.count > 512 { evicted += memory.count-512; memory.removeFirst(memory.count-512) }
        } else { store.append(record) }
    }
    func snapshot() async -> PopupLogSnapshot {
        if isPrivate {
            return PopupLogSnapshot(schema: 1, exportedAt: Date(), privateSession: true,
                notes: "Explicit export of this private session's in-memory diagnostics; not part of the persistent log. Cleared when this private session ends. Page observations are unverified; a null window handle does not prove blocking. URL secrets are redacted.",
                writeFailures: 0, unreadableLines: 0, evictedMemoryEvents: evicted, queueDroppedEvents: 0, events: memory)
        }
        return await store.snapshot()
    }
    func clear() async throws {
        if isPrivate { memory.removeAll(); evicted = 0 }
        else { try await store.clear() }
    }
}
