import UIKit
import WebKit

/// No popups, downloads, permission prompts or media playback from preview-only pages.
@MainActor final class TabPreviewRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let adBlocker: MobileAdBlocker
    private var loading: CheckedContinuation<Void, Error>?
    private var snapshot: CheckedContinuation<UIImage, Error>?
    private var deadline: Task<Void, Never>?
    private var cancelled = false
    private var failure: Error?
    private enum Failure: Error { case unavailable, timedOut, blank }

    init(host: UIView, size: CGSize, top: CGFloat, adBlocker: MobileAdBlocker) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsPictureInPictureMediaPlayback = false
        // Match the real page's position below the status strip. Starting at y=0 would
        // make automatic safe-area insets include that strip a second time in the picture.
        webView = WKWebView(frame: CGRect(origin: CGPoint(x: 0, y: top), size: size), configuration: configuration)
        self.adBlocker = adBlocker
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        host.addSubview(webView)
    }

    func picture(for url: URL, beforeCapture: @escaping @MainActor () async throws -> Void) async throws -> UIImage {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)); self?.fail(Failure.timedOut) }
            catch { }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loading = continuation
                webView.load(URLRequest(url: url, timeoutInterval: 15))
            }
            // Start from commit, rather than waiting for every advert/image to finish loading.
            // Leave time for fonts and the first consent-API fallback before taking a picture.
            try await Task.sleep(for: .milliseconds(1400))
            let paintDeadline = Date().addingTimeInterval(8)
            repeat {
                try await beforeCapture()
                try Task.checkCancellation()
                if let failure { throw failure }
                guard !cancelled else { throw CancellationError() }
                let configuration = WKSnapshotConfiguration()
                configuration.snapshotWidth = NSNumber(value: Double(min(600, webView.bounds.width*1.5)))
                configuration.afterScreenUpdates = true
                let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                    snapshot = continuation
                    webView.takeSnapshot(with: configuration) { [weak self] image, error in
                        guard let self, let waiting = snapshot else { return }
                        snapshot = nil
                        if let image { waiting.resume(returning: image) }
                        else { waiting.resume(throwing: error ?? Failure.unavailable) }
                    }
                }
                if !Self.isBlank(image) {
                    deadline?.cancel(); deadline = nil
                    return image
                }
                // Client-rendered pages can paint well after load/commit. Never make their
                // first empty frame a permanent cached preview.
                try await Task.sleep(for: .milliseconds(500))
            } while Date() < paintDeadline
            throw Failure.blank
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Check a tiny bitmap for actual visual detail; exclude the status strip on cached cards.
    static func isBlank(_ image: UIImage, topInset: CGFloat = 0) -> Bool {
        guard let source = image.cgImage else { return true }
        let width = 32, height = 48
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { return true }
        let firstRow = min(height-1, max(0, Int(ceil(topInset/max(1, image.size.height)*CGFloat(height)))))
        for channel in 0..<3 {
            let values = stride(from: width*4*firstRow+channel, to: width*height*4, by: 4).map { Int(pixels[$0]) }
            if (values.max() ?? 0)-(values.min() ?? 0) > 12 { return false }
        }
        return true
    }

    func cancel() {
        cancelled = true
        deadline?.cancel(); deadline = nil
        fail(CancellationError())
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.stopLoading(); webView.removeFromSuperview()
    }

    private func fail(_ error: Error) {
        failure = error
        let load = loading, picture = snapshot
        loading = nil; snapshot = nil
        load?.resume(throwing: error); picture?.resume(throwing: error)
    }

    private func allow(_ url: URL?, decision: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !cancelled, let url, MobileBrowserSession.canRestore(url) else { decision(false); return }
        if adBlocker.prepareIfReady(webView, for: url) { decision(true); return }
        Task {
            do { try await adBlocker.prepare(webView, for: url); decision(!cancelled) }
            catch { decision(false); fail(error) }
        }
    }

    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !action.shouldPerformDownload, action.targetFrame != nil else { decisionHandler(.cancel); return }
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        allow(action.request.url) { decisionHandler($0 ? .allow : .cancel) }
    }

    func webView(_ page: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel); fail(Failure.unavailable); return
        }
        guard !BrowserViewController.shouldDownload(response) else { decisionHandler(.cancel); fail(Failure.unavailable); return }
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        allow(response.response.url) { decisionHandler($0 ? .allow : .cancel) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let waiting = loading; loading = nil; waiting?.resume()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let waiting = loading; loading = nil; waiting?.resume()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(Failure.unavailable) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
}
