import AppKit
import RiseChromium

/// The image, video or audio clicked, got for AirDrop: Chromium fetches it as the page would, with
/// the page's cookies, into a temporary folder rather than Downloads, and AirDrop sends the file
/// itself rather than its address.
@MainActor final class MediaAirDrop {
    enum Outcome: Equatable { case finished(URL), failed, cancelled }
    nonisolated static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Rise AirDrop", isDirectory: true) }
    /// Each in a folder of its own, so it keeps its name.
    nonisolated static func newFile(named name: String, in folder: URL = folder) -> URL {
        let base = (name as NSString).lastPathComponent
        let inner = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        return inner.appendingPathComponent(base.isEmpty || base == "/" ? "download" : base)
    }
    /// AirDrop doesn't reliably say when it's done with a file, and it may still be sending one, so
    /// files stay a while: until a much later AirDrop, or the next launch.
    nonisolated static func clearLeftovers(olderThan age: TimeInterval = 0, now: Date = Date(), in folder: URL = folder) {
        let manager = FileManager.default
        for item in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) >= age { try? manager.removeItem(at: item) }
        }
    }

    private var download: RCDownload?
    private var file: URL?
    private var timeout: Timer?
    private var done: ((Outcome) -> Void)?
    /// Fails if Chromium hasn't begun within `timeout`, as when the page has since gone.
    init(timeout seconds: TimeInterval = 30, done: @escaping (Outcome) -> Void) {
        self.done = done
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failed) }
        }
        timeout = timer; RunLoop.main.add(timer, forMode: .common)
    }
    /// Takes the download Chromium began, saying where it goes.
    func take(_ download: RCDownload, name: String) -> URL? {
        guard done != nil else { return nil }
        timeout?.invalidate(); timeout = nil
        let file = Self.newFile(named: name)
        self.download = download; self.file = file
        download.onUpdate = { [weak self] download in MainActor.assumeIsolated { self?.update(download) } }
        update(download)
        return file
    }
    private func update(_ download: RCDownload) {
        switch download.state {
        case .finished: if let file { finish(.finished(file)) }
        case .failed: finish(.failed)
        case .cancelled: finish(.cancelled)
        default: break
        }
    }
    func cancel() {
        let download = done == nil ? nil : self.download
        finish(.cancelled)
        download?.cancel()
    }
    private func finish(_ outcome: Outcome) {
        guard let done else { return }
        self.done = nil
        timeout?.invalidate(); timeout = nil
        download?.onUpdate = nil
        if case .finished = outcome {} else if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        done(outcome)
    }
}

@MainActor extension BrowserController {
    /// Gets the media clicked and opens AirDrop's panel on it. Most are at hand and go straight
    /// there; one that takes longer says so in the page bar, where it can be cancelled.
    func airDropMedia(_ source: URL, named noun: String, video: Bool, from info: RCContextMenu, in page: ChromiumPage) {
        mediaAirDrop?.cancel()
        MediaAirDrop.clearLeftovers(olderThan: 3600)
        let bar = selectedBar, words = "Preparing \(noun) for AirDrop"
        let notice = DispatchWorkItem { [weak self] in
            bar.showNotice(words, image: BarNotice.spinnerImage,
                           action: .init(text: "Cancel") { [weak self] in self?.mediaAirDrop?.cancel() }, hold: 3600)
        }
        let transfer = MediaAirDrop { [weak self, weak page] outcome in
            notice.cancel()
            page?.nextDownload = nil
            if bar.notice?.text == BarNotice.text(words, link: nil) { bar.hideNotice() }
            guard let self else { return }
            self.mediaAirDrop = nil
            switch outcome {
            case .finished(let file):
                if let airDropFile = self.airDropFile { airDropFile(file) }
                else { AirDropMenuItem.send([file], in: { [weak self] in self?.window }) }
            case .failed: bar.showNotice("Couldn’t Get \(noun) for AirDrop", image: BarNotice.warningImage, hold: 3)
            case .cancelled: break
            }
        }
        mediaAirDrop = transfer
        page.nextDownload = { [weak transfer] download, name in transfer?.take(download, name: name) }
        DispatchQueue.main.asyncAfter(deadline: .now()+0.25, execute: notice)
        guard video else { info.download(source); return }
        Task { info.download(await ContextMenuVideoSource.resolve(source, in: page)) }
    }
}
