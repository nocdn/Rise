import AppKit
import Sparkle

/// Rise's updates through Sparkle, from the appcast published with each GitHub release
/// (docs/Releasing.md). Only release builds carry the feed (`SUFeedURL`, which `scripts/release.sh` adds),
/// so a local build never offers to replace itself with a published one.
@MainActor final class AppUpdater {
    static let shared = AppUpdater()
    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let published = (info["SUFeedURL"] as? String)?.isEmpty == false && (info["SUPublicEDKey"] as? String)?.isEmpty == false
        // Starting it schedules Sparkle's checks (daily, as Info.plist asks); its window asks before installing.
        controller = published ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    /// "Check for Updates…", which Sparkle itself enables while a check can start; nil for builds without a feed.
    func menuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }
}
