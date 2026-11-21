import UIKit
import WebKit

extension BrowserViewController {
    /// A native button supplies the user action missing from Apple's empty redirect.
    /// Use the store scheme so the default-browser setting cannot route it back to Rise.
    func openAppStore(_ url: URL) {
        guard let current = toast as? AppStoreToast, !current.dismissed, current.link.externalURL == url,
              current.page === webView, !isTabSwitcherOpen, presentedViewController == nil else { return }
        if isPanelOpen { closePanel() }
        let page = webView
        openExternalURL(url) { [weak self, weak page] opened in
            guard let self, let page, !opened, page === webView,
                  (toast as? AppStoreToast)?.link.externalURL == url else { return }
            let message = "Couldn't open the App Store"
            let failure = Toast(message: message, glyph: UIImage(systemName: "exclamationmark.circle"), name: "app-store-failed")
            showToast(failure)
            failure.leave(after: 4)
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    static func isExternalAppURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        // Keep browser documents and Rise's own routes out of UIApplication.open.
        guard !["javascript", "blob", "rise", MobileTabHistory.scheme].contains(scheme) else { return false }
        return !WKWebView.handlesURLScheme(scheme)
    }

    /// Consume app schemes before WebKit tries to load them as web documents.
    /// Only a tapped link in the visible page can hand control to another app.
    func handleExternalAppLink(_ action: WKNavigationAction, in page: WKWebView) -> Bool {
        guard let url = action.request.url, Self.isExternalAppURL(url) else { return false }
        guard page === webView, !isPanelOpen, presentedViewController == nil,
              action.navigationType == .linkActivated, action.sourceFrame.isMainFrame,
              action.targetFrame?.isMainFrame != false, !action.shouldPerformDownload,
              action.request.httpMethod == "GET" else { return true }

        finishAdBlockingReload(on: page)
        // Don't preflight canOpenURL: undeclared schemes return false even when
        // their app is installed. open's completion reports the actual result.
        openExternalURL(url) { [weak self, weak page] opened in
            guard let self, let page else { return }
            blocker(for: page).popups.noteNavigation("navigation.external_app", in: page, destination: url,
                details: ["opened": String(opened)])
            guard !opened, page === webView else { return }
            let message = "Couldn't open this link"
            showToast(Toast(message: message, glyph: UIImage(systemName: "exclamationmark.circle"), name: "external-link-failed"))
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        return true
    }
}
