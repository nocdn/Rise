import AppKit
import CloudKit
import Dispatch

// Provisioning helper. Rise itself is built by SwiftPM; this target obtains its profile.
// The optional diagnostic reads account/zone availability without changing browser data.
if CommandLine.arguments.contains("--test-tab-sync") {
    Task { exit(await TabSyncAudit.run()) }
    dispatchMain()
} else if let index = CommandLine.arguments.firstIndex(of: "--cleanup-audit-zone"), index+1 < CommandLine.arguments.count {
    let name = CommandLine.arguments[index+1]
    Task { exit(await TabSyncAudit.cleanup(name)) }
    dispatchMain()
} else if CommandLine.arguments.contains("--check-cloudkit") {
    Task {
        do {
            let container = CKContainer(identifier: "iCloud.dev.bartosz.Rise")
            let status = try await container.accountStatus()
            print("CloudKit account status: \(status.rawValue)")
            let zones = try await container.privateCloudDatabase.allRecordZones()
            print("CloudKit accessible; private zones: \(zones.count)")
            exit(0)
        } catch {
            print("CloudKit unavailable: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
} else {
    print("Provisioning helper only. Use --check-cloudkit or --test-tab-sync for diagnostics.")
}
