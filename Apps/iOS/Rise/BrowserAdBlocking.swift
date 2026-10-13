import UIKit
import WebKit

extension BrowserViewController {
    func updateAdBlockingSettings() {
        let url = webView.url
        bottomBar.siteSettings.setAdBlocking(enabled: adBlocker.isEnabled(for: url),
            available: url?.host != nil && !MobileAdBlocker.isYouTube(url), busy: adBlockingPage === webView,
            isYouTube: MobileAdBlocker.isYouTube(url))
    }

    func changeAdBlocking(_ enabled: Bool) {
        let page = webView
        guard let url = page.url, !MobileAdBlocker.isYouTube(url), adBlockingPage == nil else { updateAdBlockingSettings(); return }
        let previous = adBlocker.isEnabled(for: url)
        let id = UUID()
        adBlockingID = id
        adBlocker.setEnabled(enabled, for: url)
        adBlockingPage = page
        updateAdBlockingSettings()
        adBlockingTask = Task { [weak self, weak page] in
            guard let self, let page else { return }
            do {
                try await adBlocker.prepare(page, for: url)
                guard adBlockingID == id else { return }
                guard page === webView, page.url == url else { finishAdBlockingReload(on: page); return }
                adBlockingNavigation = page.reloadFromOrigin()
                guard let navigation = adBlockingNavigation else { finishAdBlockingReload(on: page); return }
                // A replacement navigation need not deliver the old reload's completion.
                // Also watch loading state so the row settles after an interrupted load.
                try await Task.sleep(for: .milliseconds(250))
                while adBlockingID == id {
                    if !page.isLoading { finishAdBlockingReload(on: page, navigation: navigation); return }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch is CancellationError {
                if adBlockingID == id { finishAdBlockingReload(on: page) }
            }
            catch {
                guard adBlockingID == id else { return }
                adBlocker.setEnabled(previous, for: url)
                finishAdBlockingReload(on: page)
                showAdBlockingError(error)
            }
        }
    }

    func finishAdBlockingReload(on page: WKWebView, navigation: WKNavigation? = nil) {
        guard adBlockingPage === page,
              navigation == nil || navigation === adBlockingNavigation else { return }
        adBlockingPage = nil
        adBlockingNavigation = nil
        adBlockingID = nil
        adBlockingTask?.cancel()
        adBlockingTask = nil
        updateAdBlockingSettings()
    }

    func showAdBlockingError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Couldn't update ad blocking", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { finishAdBlockingReload(on: page); decisionHandler(.download); return }
        // A nil target opens another window; its own browser applies its policy. Do not
        // change this page's filtering while it is merely opening a link elsewhere.
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        if adBlocker.prepareIfReady(page, for: action.request.url) { decisionHandler(.allow); return }
        Task {
            do { try await adBlocker.prepare(page, for: action.request.url); decisionHandler(.allow) }
            catch is CancellationError { decisionHandler(.cancel) }
            catch { finishAdBlockingReload(on: page); showAdBlockingError(error); decisionHandler(.cancel) }
        }
    }

    func webView(_ page: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if Self.shouldDownload(response) { finishAdBlockingReload(on: page); decisionHandler(.download); return }
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        // A server redirect can change the final host without another action-policy callback.
        if adBlocker.prepareIfReady(page, for: response.response.url) { decisionHandler(.allow); return }
        Task {
            do { try await adBlocker.prepare(page, for: response.response.url); decisionHandler(.allow) }
            catch is CancellationError { decisionHandler(.cancel) }
            catch { finishAdBlockingReload(on: page); showAdBlockingError(error); decisionHandler(.cancel) }
        }
    }

    func webView(_ page: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishAdBlockingReload(on: page, navigation: navigation)
    }

    func webView(_ page: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishAdBlockingReload(on: page, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ page: WKWebView) { finishAdBlockingReload(on: page) }
}
