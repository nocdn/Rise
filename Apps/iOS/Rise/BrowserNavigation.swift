import WebKit
import OSLog

extension BrowserViewController {
    func webView(_ page: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        blocker(for: page).popups.noteNavigation("navigation.started", in: page, details: ["hasNavigationObject": String(navigation != nil)])
        // WebKit may omit the navigation object for a script-created blank window.
        if let navigation { tabs.first { $0.webView === page }?.didStart(navigation) }
        if page === webView { updateNavigationStatus() }
    }
    func handlePageFailure(_ page: WKWebView, navigation: WKNavigation?, error: Error) {
        let diagnosticError = error as NSError
        blocker(for: page).popups.noteNavigation("navigation.failed", in: page,
            details: ["errorDomain": diagnosticError.domain, "errorCode": String(diagnosticError.code)])
        guard let tab = tabs.first(where: { $0.webView === page }) else { return }
        addressSuggestions.failed(page, error: error)
        let retry = tab.didFail(navigation, error: error)
        if retry {
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, self.tabs.contains(where: { $0 === tab }) else { return }
                tab.loadIfNeeded()
                if page === self.webView { self.updateNavigationStatus() }
            }
        }
        let code = (error as NSError).code
        Logger(subsystem: "dev.bartosz.Rise", category: "Navigation").notice("Page navigation failed: \(code)")
        if page === webView { updateNavigationStatus(); updateAddress() }
    }
    func handlePageProcessTermination(_ page: WKWebView) {
        blocker(for: page).popups.noteNavigation("process.terminated", in: page)
        guard let tab = tabs.first(where: { $0.webView === page }) else { return }
        tab.processTerminated()
        if page === webView { tab.loadIfNeeded(); updateNavigationStatus() }
    }
    func webView(_ page: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        blocker(for: page).popups.noteNavigation("navigation.server_redirect", in: page)
    }
}
