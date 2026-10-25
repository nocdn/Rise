import UIKit

extension BrowserViewController {
    func sharePopupDiagnostics() {
        guard presentedViewController == nil else { return }
        let diagnostics = adBlocker.popups.diagnostics
        let row = bottomBar.appSettings.popupDiagnosticsRow
        row.isEnabled = false
        Task { [weak self] in
            defer { row.isEnabled = true }
            guard let self else { return }
            do {
                let snapshot = await diagnostics.snapshot()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PopupDiagnosticsExports", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                    if let date = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: file) }
                }
                let file = folder.appendingPathComponent("Rise-popup-diagnostics-\(UUID().uuidString.prefix(8)).json")
                try PopupLogRecord.encoder(pretty: true).encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                guard presentedViewController == nil, view.window != nil else { try? FileManager.default.removeItem(at: file); return }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = row
                share.popoverPresentationController?.sourceRect = row.bounds
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
                present(share, animated: true)
            } catch {
                let alert = UIAlertController(title: "Couldn't share diagnostics", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                if presentedViewController == nil { present(alert, animated: true) }
            }
        }
    }
}
