import AppKit
import RiseChromium

/// A Chromium download in Rise's list: Chromium pauses, resumes and cancels it, and saves
/// straight to its row's file.
@MainActor final class ChromiumDownloadTransfer: DownloadControl {
    private let download: RCDownload
    private let item: DownloadList.Item
    private weak var list: DownloadList?
    private let failed: (Error) -> Void
    let progress = Progress(totalUnitCount: -1)

    init(download: RCDownload, item: DownloadList.Item, list: DownloadList, progress: Progress, failed: @escaping (Error) -> Void) {
        self.download = download; self.item = item; self.list = list; self.failed = failed
        download.onUpdate = { [weak self] _ in MainActor.assumeIsolated { self?.update(progress) } }
        update(progress)
    }
    private func update(_ progress: Progress) {
        progress.totalUnitCount = download.totalBytes; progress.completedUnitCount = download.receivedBytes
        let id = item.record.id
        switch download.state {
        case .downloading:
            if item.state == .resuming { list?.setState(.downloading, for: id) }
        case .paused:
            if item.state == .pausing || item.state == .downloading { list?.setState(.paused, for: id) }
        case .finished:
            if item.state == .cancelling { discard() } else { list?.finish(id) }
        case .cancelled:
            discard()
        case .failed:
            let cancelling = item.state == .cancelling
            discard()
            if !cancelling { failed(NSError(domain: "Rise.Download", code: 2, userInfo: [NSLocalizedDescriptionKey: "The download didn’t finish."])) }
        @unknown default: break
        }
    }
    func togglePause() {
        switch item.state {
        case .downloading: list?.setState(.pausing, for: item.record.id); download.pause()
        case .paused: list?.setState(.resuming, for: item.record.id); download.resume()
        default: break
        }
    }
    func cancel() {
        guard !item.isFinished, item.state != .cancelling else { return }
        list?.setState(.cancelling, for: item.record.id); download.cancel()
    }
    private func discard() {
        download.onUpdate = nil
        try? FileManager.default.removeItem(at: item.record.url)
        list?.fail(item.record.id)
    }
}

@MainActor extension BrowserController {
    /// A Chromium page saving a file: it goes to Downloads, into the list, with the download's flight.
    func beginChromiumDownload(_ download: RCDownload, suggestedName: String) -> URL? {
        let destination = newDownloadDestination(suggestedName.isEmpty ? "download" : suggestedName)
        let progress = Progress(totalUnitCount: download.totalBytes)
        downloads.track(at: destination, progress: progress, expectedBytes: max(0, download.totalBytes)) { [weak self] item, list in
            ChromiumDownloadTransfer(download: download, item: item, list: list, progress: progress) { error in
                self?.showMessage("Download failed", error.localizedDescription)
            }
        }
        if let item = downloads.items.first(where: { $0.record.url == destination }) { launchDownloadFlight(item) }
        return destination
    }
}
