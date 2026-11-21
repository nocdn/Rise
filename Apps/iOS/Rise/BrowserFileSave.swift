import UIKit
import WebKit

/// Save to Files for pages that are files, such as an MP3 or MP4 in WebKit's player: offered by a
/// toast and in the share sheet, as Safari's sheet offers it. The file downloads through its
/// page, then the Files picker chooses where it goes, opening where the last one was saved.
extension BrowserViewController {
    func showFileSaveToast(_ document: FileDocument, on page: WKWebView) {
        let next = FileSaveToast(document: document, page: page)
        next.onActivate = { [weak self, weak next] in
            guard let self, let next, toast === next, let page = next.page, page === webView else { return }
            // Tapped over an open panel, through its dimming: the Files picker needs it closed.
            closePanel()
            saveFile(on: page, fromToast: true)
        }
        next.onUserDismiss = { [weak self, weak page] in
            guard let self, let page else { return }
            fileDocuments.dismiss(for: page)
        }
        showToast(next)
        next.isHidden = isTabSwitcherOpen
        refreshFileSaveToast(next)
    }

    /// The toast shown for this page's file, if that's the toast showing.
    func fileSaveToast(for page: WKWebView) -> FileSaveToast? {
        (toast as? FileSaveToast).flatMap { $0.page === page && !$0.dismissed ? $0 : nil }
    }

    /// Catches a new toast up with a download already going, or done while it was away.
    func refreshFileSaveToast(_ toast: FileSaveToast) {
        guard let page = toast.page, let state = fileDocuments.state(for: page) else { return }
        if case .downloading(let fraction)? = state.save?.state { toast.show(.downloading, progress: fraction) }
        else if toast.phase == .downloading { toast.show(.ready) }
    }

    /// Downloads the page's file, or uses the copy already downloaded, and asks where to save it.
    /// The share sheet's Save to Files brings a swiped-away toast back, to show it going.
    func saveFile(on page: WKWebView, fromToast: Bool = false) {
        guard let state = fileDocuments.state(for: page), let document = state.document else { return }
        state.dismissed = false; state.saved = false
        switch state.save?.state {
        case .finished(let file)?:
            updatePageToast()
            presentFileSavePicker(file, for: page, closingPanel: fromToast)
            return
        case .downloading?:
            updatePageToast(); return
        default: break
        }
        let save = FileSaveDownload(document: document, page: page)
        state.save = save
        save.onChange = { [weak self, weak page, weak save] in
            guard let self, let page, let save else { return }
            fileSaveChanged(save, on: page)
        }
        updatePageToast()
    }

    private func fileSaveChanged(_ save: FileSaveDownload, on page: WKWebView) {
        guard let state = fileDocuments.state(for: page), state.save === save else { return }
        let toast = fileSaveToast(for: page)
        switch save.state {
        case .downloading(let fraction):
            toast?.show(.downloading, progress: fraction)
        case .finished(let file):
            // Only straight onto the page it's for: not over a panel, the switcher or another sheet
            // opened meanwhile. Otherwise the toast offers it again, ready to save at once.
            let free = page === webView && !isPanelOpen && !isTabSwitcherOpen && presentedViewController == nil
                && view.window?.windowScene?.activationState == .foregroundActive
            if free { presentFileSavePicker(file, for: page, closingPanel: false) } else { toast?.show(.ready) }
        case .failed:
            state.save = nil
            if let toast { toast.show(.failed) }
            else if page === webView {
                let failure = Toast(message: FileSaveToast.failedMessage, glyph: UIImage(named: "GitHubToastError"), name: "file-save-failed")
                showToast(failure)
                failure.leave(after: 3)
                UIAccessibility.post(notification: .announcement, argument: failure.label.text)
            }
        }
    }

    private func presentFileSavePicker(_ file: URL, for page: WKWebView, closingPanel: Bool) {
        if closingPanel, isPanelOpen { closePanel() }
        // Behind the picker it's an offer again, for when the picker is cancelled.
        fileSaveToast(for: page)?.show(.ready)
        let finished: @MainActor (URL?) -> Void = { [weak self, weak page] destination in
            guard let self, let page, let destination else { return }
            FileSaveLocation.remember(destination)
            guard let state = fileDocuments.state(for: page) else { return }
            state.saved = true
            state.save = nil
            if let toast = fileSaveToast(for: page) { toast.show(.saved) }
            else if page === webView {
                let saved = Toast(message: FileSaveToast.savedMessage, glyph: UIImage(systemName: "checkmark"), name: "file-saved")
                showToast(saved)
                saved.leave(after: 2.5)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: saved.label.text)
            }
        }
        if let fileSavePickerOverride { fileSavePickerOverride(file, finished); return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.directoryURL = FileSaveLocation.folder
        picker.shouldShowFileExtensions = true
        let delegate = FileSavePickerDelegate(finished)
        picker.delegate = delegate
        fileSavePickerDelegate = delegate
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(picker, animated: true)
    }
}

/// Where the last file was saved, for the picker to open there next time. iOS doesn't let an app
/// name another app's folder, such as On My iPhone › Downloads, so the first save starts where
/// the picker chooses; each one after starts where the one before went.
enum FileSaveLocation {
    static let key = "SaveToFilesFolder"
    static var folder: URL? { UserDefaults.standard.url(forKey: key) }
    static func remember(_ saved: URL) {
        UserDefaults.standard.set(saved.deletingLastPathComponent(), forKey: key)
    }
}

/// The picker holds its delegate weakly; the browser keeps this one until it answers.
@MainActor final class FileSavePickerDelegate: NSObject, UIDocumentPickerDelegate {
    private var finished: (@MainActor (URL?) -> Void)?
    init(_ finished: @escaping @MainActor (URL?) -> Void) { self.finished = finished }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    private func finish(_ url: URL?) {
        let finished = finished
        self.finished = nil
        finished?(url)
    }
}

/// The share sheet's Save to Files for a page that's a file. A link alone gives the system's
/// own sheet nothing to save, so this downloads it, as the toast does, once the sheet has gone.
final class SaveToFilesActivity: UIActivity {
    static let type = UIActivity.ActivityType("dev.bartosz.Rise.save-to-files")
    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { Self.type }
    override var activityTitle: String? { "Save to Files" }
    override var activityImage: UIImage? { UIImage(systemName: "folder") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }
    override func perform() { activityDidFinish(true) }
}
