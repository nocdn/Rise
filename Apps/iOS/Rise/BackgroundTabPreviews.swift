import UIKit
import WebKit

/// Serial preview capture uses a temporary page, leaving restored tabs' history and lazy pages
/// alone. The renderer sits behind the browser in the same window so WebKit can paint normally.
@MainActor final class BackgroundTabPreviews {
    let host = UIView()
    let cache: TabPreviewCache
    var canRender: () -> Bool = { false }
    private let adBlocker: MobileAdBlocker
    private var tabs: [BrowserTab] = []
    private weak var selected: BrowserTab?
    private var viewport = CGSize.zero
    private var stripHeight: CGFloat = 0
    private var active = true
    private var work: Task<Void, Never>?
    private var renderer: TabPreviewRenderer?
    private var cached = Set<Key>()
    private var failures: [Key: Date] = [:]
    private var openIDs = Set<UUID>()
    private struct Key: Hashable { let id: UUID; let url: URL }

    init(cacheURL: URL, adBlocker: MobileAdBlocker) {
        cache = TabPreviewCache(folder: cacheURL)
        self.adBlocker = adBlocker
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
    }

    func update(tabs: [BrowserTab], selected: BrowserTab, viewport: CGSize, stripHeight: CGFloat) {
        self.tabs = tabs; self.selected = selected; self.viewport = viewport; self.stripHeight = stripHeight
        let ids = Set(tabs.map(\.id))
        if ids != openIDs {
            openIDs = ids; cache.prune(keeping: ids)
            cached = cached.filter { ids.contains($0.id) }
            failures = failures.filter { ids.contains($0.key.id) }
        }
        start()
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active { start() }
        else { work?.cancel(); renderer?.cancel() }
    }

    func save(_ tab: BrowserTab) {
        guard let url = tab.sessionTab.url, let image = tab.snapshot else { return }
        cache.save(id: tab.id, url: url, picture: image, favicon: tab.favicon)
    }

    private func start() {
        guard active, work == nil, host.window != nil, viewport.width > 0 else { return }
        work = Task { [weak self] in
            await self?.run()
            guard let self else { return }
            work = nil
            // A foreground callback may have arrived while the cancelled job was unwinding.
            if active, Task.isCancelled { start() }
        }
    }

    private func isCurrent(_ tab: BrowserTab, key: Key) -> Bool {
        tabs.contains { $0 === tab } && tab.sessionTab.url == key.url
    }

    private func waitUntilIdle() async throws {
        while !canRender() {
            guard active, host.window != nil else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }

    private func run() async {
        while active, !Task.isCancelled {
            // Restore cached cards before doing any networking, including the selected tab's.
            if let tab = tabs.first(where: { tab in
                tab.snapshot == nil && tab.sessionTab.url.map { !cached.contains(Key(id: tab.id, url: $0)) } == true
            }), let url = tab.sessionTab.url {
                let key = Key(id: tab.id, url: url)
                cached.insert(key)
                if let entry = await cache.load(id: tab.id, url: url), isCurrent(tab, key: key), tab.snapshot == nil {
                    tab.snapshot = UIImage(data: entry.picture)
                    tab.restoreFavicon(entry.favicon.flatMap(UIImage.init(data:)))
                }
                continue
            }
            guard let tab = tabs.first(where: { tab in
                guard tab !== selected, tab.snapshot == nil, let url = tab.sessionTab.url else { return false }
                return failures[Key(id: tab.id, url: url)].map { Date().timeIntervalSince($0) >= 60 } ?? true
            }), let url = tab.sessionTab.url else { return }
            let key = Key(id: tab.id, url: url)
            do {
                // Creating a WebKit page or composing a bitmap must not land in a gesture.
                try await Task.sleep(for: .milliseconds(300))
                try await waitUntilIdle()
                guard isCurrent(tab, key: key), tab !== selected, tab.snapshot == nil else { continue }
                let page = TabPreviewRenderer(host: host, size: CGSize(width: viewport.width, height: viewport.height-stripHeight),
                                              top: stripHeight, adBlocker: adBlocker)
                renderer = page
                defer { page.cancel(); renderer = nil }
                let picture = try await page.picture(for: url)
                try await waitUntilIdle()
                try Task.checkCancellation()
                guard isCurrent(tab, key: key), tab !== selected, tab.snapshot == nil else { continue }
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(1.5, 600/viewport.width); format.opaque = true
                let strip = picture.cgImage.flatMap(PageEdgeColor.dominantColor) ?? .systemBackground
                let image = UIGraphicsImageRenderer(size: viewport, format: format).image { context in
                    strip.setFill(); context.fill(CGRect(origin: .zero, size: viewport))
                    picture.draw(in: CGRect(x: 0, y: stripHeight, width: viewport.width, height: viewport.height-stripHeight))
                }
                tab.snapshot = image
                save(tab)
                let icon = await BrowserTab.favicon(for: page.webView)
                guard !Task.isCancelled, isCurrent(tab, key: key) else { continue }
                tab.restoreFavicon(icon)
                save(tab)
            } catch is CancellationError { return }
            catch { failures[key] = Date() }
        }
    }
}

/// No popups, downloads, permission prompts or media playback from preview-only pages.
@MainActor private final class TabPreviewRenderer: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let adBlocker: MobileAdBlocker
    private var loading: CheckedContinuation<Void, Error>?
    private var snapshot: CheckedContinuation<UIImage, Error>?
    private var deadline: Task<Void, Never>?
    private var cancelled = false
    private var failure: Error?
    private enum Failure: Error { case unavailable, timedOut }

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

    func picture(for url: URL) async throws -> UIImage {
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)); self?.fail(Failure.timedOut) }
            catch { }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loading = continuation
                webView.load(URLRequest(url: url, timeoutInterval: 15))
            }
            // Let fonts, image decoding and client-rendered articles reach their first paint.
            try await Task.sleep(for: .milliseconds(800))
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
            deadline?.cancel(); deadline = nil
            return image
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
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
        guard !BrowserViewController.shouldDownload(response) else { decisionHandler(.cancel); fail(Failure.unavailable); return }
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        allow(response.response.url) { decisionHandler($0 ? .allow : .cancel) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
