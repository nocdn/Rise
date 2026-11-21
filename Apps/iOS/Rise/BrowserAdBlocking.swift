import UIKit
import WebKit

extension BrowserViewController {
    func updateAdBlockingSettings() {
        let url = webView.url
        bottomBar.siteSettings.setAdBlocking(enabled: adBlocker.isEnabled(for: url),
            available: url?.host != nil && !MobileAdBlocker.isYouTube(url) && (!reloadingCookieBanners || adBlockingPage == nil), busy: adBlockingPage === webView && !reloadingCookieBanners,
            isYouTube: MobileAdBlocker.isYouTube(url))
        bottomBar.siteSettings.setCookieBanners(enabled: adBlocker.cookieBanners.isEnabled(for: url),
            available: url?.host != nil && ["http","https"].contains(url?.scheme ?? "") && (reloadingCookieBanners || adBlockingPage == nil),
            busy: adBlockingPage === webView && reloadingCookieBanners)
        bottomBar.siteSettings.setPopups(enabled: adBlocker.popups.isEnabled(for: url),
            available: CookieConsentPolicy.site(url) != nil)
    }

    func changePopupBlocking(_ enabled: Bool) {
        guard let url = webView.url else { updateAdBlockingSettings(); return }
        adBlocker.popups.setEnabled(enabled, for: url)
        updateAdBlockingSettings()
    }

    func changeAdBlocking(_ enabled: Bool) {
        changePageProtection(enabled, cookieBanners: false)
    }
    func changeCookieBanners(_ enabled: Bool) {
        changePageProtection(enabled, cookieBanners: true)
    }
    private func changePageProtection(_ enabled: Bool, cookieBanners: Bool) {
        let page = webView
        guard let url = page.url, (cookieBanners || !MobileAdBlocker.isYouTube(url)), adBlockingPage == nil else { updateAdBlockingSettings(); return }
        let previous = cookieBanners ? adBlocker.cookieBanners.isEnabled(for: url) : adBlocker.isEnabled(for: url)
        let id = UUID()
        adBlockingID = id
        if cookieBanners { adBlocker.cookieBanners.setEnabled(enabled, for: url) }
        else { adBlocker.setEnabled(enabled, for: url) }
        reloadingCookieBanners = cookieBanners
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
                if cookieBanners { adBlocker.cookieBanners.setEnabled(previous, for: url) }
                else { adBlocker.setEnabled(previous, for: url) }
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
        reloadingCookieBanners = false
        adBlockingTask?.cancel()
        adBlockingTask = nil
        updateAdBlockingSettings()
    }

    func showAdBlockingError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Couldn't update site settings", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let adBlocker = blocker(for: page)
        if action.targetFrame?.isMainFrame == true {
            adBlocker.popups.noteNavigation("navigation.requested", in: page, destination: action.request.url,
                details: ["navigationType": String(action.navigationType.rawValue), "method": action.request.httpMethod ?? "GET"])
        }
        if adBlocker.popups.blocksOpenerNavigation(action, in: page) {
            decisionHandler(.cancel); return
        }
        if action.targetFrame?.isMainFrame == true, let url = action.request.url,
           adBlocker.popups.blocksPopupNavigation(to: url, in: page) {
            decisionHandler(.cancel); webViewDidClose(page); return
        }
        if let url = action.request.url, url.scheme == MobileTabHistory.scheme {
            decisionHandler(action.targetFrame?.isMainFrame == true && MobileTabHistory.permits(url, in: page) ? .allow : .cancel)
            return
        }
        if action.shouldPerformDownload { finishAdBlockingReload(on: page); decisionHandler(.download); return }
        if action.targetFrame?.isMainFrame == true, let url = action.request.url {
            appStoreLinks.noteNavigation(to: url, in: page)
            if page === webView { updatePageToast() }
        }
        // New-window links pass the popup policy in createWebViewWith first.
        if action.targetFrame != nil, handleExternalAppLink(action, in: page) {
            decisionHandler(.cancel); return
        }
        // A nil target opens another window; its own browser applies its policy. Do not
        // change this page's filtering while it is merely opening a link elsewhere.
        guard action.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        // Open Here's load and its redirects stay in Rise rather than going to an app.
        let allow = allowPolicy(for: action, in: page)
        if adBlocker.prepareIfReady(page, for: action.request.url) { decisionHandler(allow); return }
        Task {
            do { try await adBlocker.prepare(page, for: action.request.url); decisionHandler(allow) }
            catch is CancellationError { decisionHandler(.cancel) }
            catch { finishAdBlockingReload(on: page); showAdBlockingError(error); decisionHandler(.cancel) }
        }
    }

    func webView(_ page: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let adBlocker = blocker(for: page)
        if response.isForMainFrame {
            adBlocker.popups.noteNavigation("navigation.response", in: page, destination: response.response.url,
                details: ["status": String((response.response as? HTTPURLResponse)?.statusCode ?? 0), "displayable": String(response.canShowMIMEType)])
        }
        if response.isForMainFrame, let url = response.response.url, adBlocker.popups.blocksPopupNavigation(to: url, in: page, stage: "response") {
            decisionHandler(.cancel); webViewDidClose(page); return
        }
        if let url = response.response.url, url.scheme == MobileTabHistory.scheme {
            decisionHandler(response.isForMainFrame && MobileTabHistory.permits(url, in: page) ? .allow : .cancel)
            return
        }
        if Self.shouldDownload(response) { finishAdBlockingReload(on: page); decisionHandler(.download); return }
        guard response.isForMainFrame else { decisionHandler(.allow); return }
        if let url = response.response.url {
            appStoreLinks.noteNavigation(to: url, in: page)
            if page === webView { updatePageToast() }
        }
        // An MP3 or MP4 shown in WebKit's player can be saved once its document commits.
        fileDocuments.noteResponse(response.response, in: page)
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
        launchCoverPageFailed(page, error: error)
        handlePageFailure(page, navigation: navigation, error: error)
    }

    func webView(_ page: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishAdBlockingReload(on: page, navigation: navigation)
        launchCoverPageFailed(page, error: error)
        handlePageFailure(page, navigation: navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ page: WKWebView) {
        finishAdBlockingReload(on: page)
        handlePageProcessTermination(page)
    }
}
