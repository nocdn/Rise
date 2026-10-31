import UIKit
import WebKit

/// A separate, scrollable page inside the native link menu. It shares only the
/// source page's website data and protections: previewing never creates a tab or
/// records history, and dismissing never changes the source page or its offset.
@MainActor final class LinkPreviewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let page: WKWebView
    let initialURL: URL
    private let blocker: MobileAdBlocker
    private var preparation: Task<Void, Never>?
    private(set) var stopped = false
    private(set) var opening = false
    private let errorLabel = UILabel()

    init(url: URL, source: WKWebView, blocker: MobileAdBlocker, videoPlayback: VideoPlaybackPolicy) {
        initialURL = url; self.blocker = blocker
        page = BrowserViewController.makeWebView(dataStore: source.configuration.websiteDataStore, videoPlayback: videoPlayback)
        super.init(nibName: nil, bundle: nil)
        let size = source.window?.bounds.size ?? source.bounds.size
        preferredContentSize = CGSize(width: max(240, min(600, size.width-32)), height: max(240, min(600, size.height*0.6)))
        page.navigationDelegate = self; page.uiDelegate = self
        page.allowsLinkPreview = false
        page.scrollView.contentInsetAdjustmentBehavior = .never
        page.scrollView.keyboardDismissMode = .interactive
        page.accessibilityIdentifier = "link-preview-page"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = UIView(); host.backgroundColor = .systemBackground
        host.addSubview(page)
        page.frame = host.bounds; page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = host
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.textColor = .secondaryLabel; errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0; errorLabel.isHidden = true
        host.addSubview(errorLabel)
        page.load(URLRequest(url: initialURL))
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        errorLabel.frame = view.bounds.insetBy(dx: 24, dy: 24)
    }

    func stop() {
        guard !stopped, !opening else { return }
        stopped = true; preparation?.cancel(); preparation = nil
        page.stopLoading(); page.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        page.navigationDelegate = nil; page.uiDelegate = nil
    }
    func prepareToOpen() { opening = true }
    func cancelOpening() { opening = false; stop() }

    private func allow(_ url: URL?, answer: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard !stopped, let url, BrowserViewController.canPeek(url) else { answer(false); return }
        if blocker.prepareIfReady(page, for: url) { answer(true); return }
        preparation = Task { [weak self] in
            guard let self else { answer(false); return }
            do { try await blocker.prepare(page, for: url); answer(!stopped && !Task.isCancelled) }
            catch { answer(false) }
        }
    }
    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !stopped, !action.shouldPerformDownload else { decisionHandler(.cancel); return }
        guard action.targetFrame != nil else {
            // A deliberate target=_blank link can navigate within the preview. No
            // script-created windows, external apps or new tabs while previewing.
            if action.navigationType == .linkActivated, action.request.httpMethod == "GET",
               let url = action.request.url, BrowserViewController.canPeek(url) { page.load(action.request) }
            decisionHandler(.cancel); return
        }
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        errorLabel.isHidden = true
        allow(action.request.url) { decisionHandler($0 ? .allow : .cancel) }
    }
    func webView(_ page: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !stopped, !BrowserViewController.shouldDownload(response) else { decisionHandler(.cancel); return }
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        allow(response.response.url) { decisionHandler($0 ? .allow : .cancel) }
    }
    private func failed(_ error: Error) {
        guard !stopped, (error as NSError).code != NSURLErrorCancelled else { return }
        errorLabel.text = "Couldn’t load preview.\nYou can still open the link from the menu."
        errorLabel.isHidden = false
    }
    func webView(_ page: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ page: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ page: WKWebView) { failed(NSError(domain: "Rise.Preview", code: 1)) }
    func webView(_ page: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    func webView(_ page: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
    func webView(_ page: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    func webView(_ page: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
