import AppKit
import WebKit

/// Owns WebKit's cancel/resume lifecycle separately from the popover's lifetime.
@MainActor final class DownloadTransfer: NSObject, WKDownloadDelegate {
    private var download: WKDownload?
    private let source: WKWebView
    private let request: URLRequest?
    private let item: DownloadList.Item
    private weak var list: DownloadList?
    private var resumeData: Data?
    private let failed: (Error) -> Void

    init(download: WKDownload, item: DownloadList.Item, list: DownloadList, failed: @escaping (Error) -> Void) {
        self.download = download; self.item = item; self.list = list; self.failed = failed
        request = download.originalRequest
        if let webView = download.webView { source = webView }
        else {
            let configuration = WKWebViewConfiguration()
            configuration.applicationNameForUserAgent = BrowserIdentity.applicationName
            source = WKWebView(frame: .zero, configuration: configuration)
        }
        super.init(); download.delegate = self
    }
    func togglePause() {
        switch item.state {
        case .downloading: pause()
        case .paused: resume()
        default: break
        }
    }
    private func pause() {
        guard let download else { return }
        list?.setState(.pausing, for: item.record.id)
        download.cancel { [weak self] data in
            guard let self else { return }
            self.download = nil
            if self.item.state == .cancelling { self.discard(); return }
            guard self.item.state == .pausing else { return }
            self.resumeData = data; self.list?.setState(.paused, for: self.item.record.id)
        }
    }
    private func resume() {
        list?.setState(.resuming, for: item.record.id)
        let restarting = resumeData == nil
        if let data = resumeData {
            source.resumeDownload(fromResumeData: data) { [weak self] download in self?.adopt(download, restarting: false) }
        } else if let request {
            // A server without resume support can still restart the original download.
            try? FileManager.default.removeItem(at: item.record.url)
            source.startDownload(using: request) { [weak self] download in self?.adopt(download, restarting: restarting) }
        } else {
            list?.setState(.paused, for: item.record.id)
            failed(NSError(domain: "Rise.Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "This download cannot be resumed."]))
        }
    }
    private func adopt(_ download: WKDownload, restarting: Bool) {
        self.download = download; download.delegate = self
        resumeData = nil
        if item.state == .cancelling { download.cancel { [weak self] _ in self?.discard() }; return }
        list?.resume(item.record.id, progress: download.progress, restarting: restarting)
    }
    func cancel() {
        guard !item.isFinished, item.state != .cancelling else { return }
        let state = item.state
        list?.setState(.cancelling, for: item.record.id)
        // A pending pause/resume callback performs the final cancellation itself.
        if state == .pausing || state == .resuming { return }
        if let download { download.cancel { [weak self] _ in self?.discard() } }
        else { discard() }
    }
    private func discard() {
        download = nil; resumeData = nil
        try? FileManager.default.removeItem(at: item.record.url)
        list?.fail(item.record.id)
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        completionHandler(item.state == .cancelling ? nil : item.record.url)
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard self.download === download, item.state == .downloading else { return }
        discard(); failed(error)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard self.download === download else { return }
        if item.state == .cancelling { discard(); return }
        self.download = nil; resumeData = nil; list?.finish(item.record.id)
    }
}
