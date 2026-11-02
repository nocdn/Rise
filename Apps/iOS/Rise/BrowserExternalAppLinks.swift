import UIKit
import WebKit

extension BrowserViewController {
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
