import UIKit
import WebKit

/// Apple may return an empty document and redirect to itms-appss instead of serving a
/// product page to an iPhone. Keep a native way to open that product even if WebKit
/// cancels the redirect. Artwork lookup is optional; the handoff never waits for it.
struct AppStoreLink: Equatable {
    let appID: String
    let webURL: URL
    var externalURL: URL {
        var parts = URLComponents(url: webURL, resolvingAgainstBaseURL: false)!
        parts.scheme = "itms-apps"
        return parts.url!
    }

    init?(_ url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https", "itms-apps", "itms-appss"].contains(parts.scheme?.lowercased()),
              ["apps.apple.com", "itunes.apple.com"].contains(parts.host?.lowercased()),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path = parts.path.split(separator: "/")
        guard (path.first == "app" || path.dropFirst().first == "app"),
              let last = path.last, last.hasPrefix("id") else { return nil }
        let id = String(last.dropFirst(2))
        guard !id.isEmpty, id.count <= 20, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        appID = id
        parts.scheme = "https"
        parts.host = parts.host?.lowercased()
        webURL = parts.url!
    }
}

/// Handoffs belong to their page and live only in memory, including in private tabs.
@MainActor final class AppStoreLinks {
    private final class PageState: NSObject {
        var link: AppStoreLink?
        var dismissed = false
        init(_ link: AppStoreLink?) { self.link = link }
    }
    private let pages = NSMapTable<WKWebView, PageState>.weakToStrongObjects()

    /// Main-frame requests and responses both participate: server redirects need
    /// not produce an action callback, and an app-scheme redirect may never commit.
    func noteNavigation(to url: URL, in page: WKWebView) {
        if let link = AppStoreLink(url) {
            let state = pages.object(forKey: page)
            if state?.link?.appID == link.appID { state?.link = link }
            else { pages.setObject(PageState(link), forKey: page) }
        } else if ["http", "https", "about", "file", "data"].contains(url.scheme?.lowercased()) {
            pages.setObject(PageState(nil), forKey: page)
        }
    }

    func link(for page: WKWebView, address: URL?) -> AppStoreLink? {
        // A restored listing offers Open before its first request completes.
        if pages.object(forKey: page) == nil { pages.setObject(PageState(address.flatMap(AppStoreLink.init)), forKey: page) }
        return pages.object(forKey: page)?.link
    }
    func isDismissed(for page: WKWebView) -> Bool { pages.object(forKey: page)?.dismissed == true }
    func dismiss(for page: WKWebView) { pages.object(forKey: page)?.dismissed = true }
}
