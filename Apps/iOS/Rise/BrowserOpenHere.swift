import UIKit
import WebKit

/// Open Here, under Open in a link's long-press menu: the link opens in this tab and stays in
/// Rise, where Open can hand a GitHub link, say, to the GitHub app.
///
/// WebKit's Open is a tap on the link, and a link the person taps is one iOS may open in the app
/// that claims it (a universal link). A page Rise loads itself, as it does a typed address, isn't
/// handed over, and WebKit is also told not to try the app for it or the redirects on its way.
extension BrowserViewController {
    /// WebKit's own Open in a link's menu.
    static let openLinkIdentifier = UIAction.Identifier("WKElementActionTypeOpen")
    static let openHereIdentifier = UIAction.Identifier("dev.bartosz.Rise.openHere")
    /// WebKit's `_WKNavigationActionPolicyAllowWithoutTryingAppLink`, the value after `.download`:
    /// allow the load, but never as a hand-off to another app.
    static let allowWithoutAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.download.rawValue+1) ?? .allow

    /// The menu's actions with Open Here right after Open, in Open's section, with its icon.
    /// Only web links get it; without an Open to go under, the menu stays as it was.
    func addingOpenHere(to actions: [UIMenuElement], url: URL?, in page: WKWebView) -> [UIMenuElement] {
        guard let url, Self.canPeek(url) else { return actions }
        // By WebKit's identifier, or failing that its English title, should the identifier change.
        func all(_ elements: [UIMenuElement]) -> [UIAction] {
            elements.flatMap { ($0 as? UIMenu).map { all($0.children) } ?? [$0 as? UIAction].compactMap { $0 } }
        }
        let flat = all(actions)
        guard let target = flat.first(where: { $0.identifier == Self.openLinkIdentifier }) ?? flat.first(where: { $0.title == "Open" }) else { return actions }
        var added = false
        func insert(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            elements.flatMap { element -> [UIMenuElement] in
                if let menu = element as? UIMenu { return [menu.replacingChildren(insert(menu.children))] }
                guard !added, let open = element as? UIAction, open === target else { return [element] }
                added = true
                return [open, openHereAction(url, image: open.image, in: page)]
            }
        }
        return insert(actions)
    }

    private func openHereAction(_ url: URL, image: UIImage?, in page: WKWebView) -> UIAction {
        UIAction(title: "Open Here", image: image ?? UIImage(systemName: "safari"), identifier: Self.openHereIdentifier) { [weak self, weak page] _ in
            guard let self, let page else { return }
            openHere(url, in: page)
        }
    }

    /// Loads the link in `page` as the link would, with the referrer a browser sends by default
    /// (the whole address within a site, its origin to another, none from HTTPS to HTTP).
    func openHere(_ url: URL, in page: WKWebView) {
        var request = URLRequest(url: url)
        if let referrer = Self.referrer(from: page.url, to: url) { request.setValue(referrer, forHTTPHeaderField: "Referer") }
        guard let navigation = page.load(request) else { return }
        openingHere.setObject(navigation, forKey: page)
    }

    /// `strict-origin-when-cross-origin`, the web's default referrer policy.
    static func referrer(from source: URL?, to destination: URL) -> String? {
        guard let source, let scheme = source.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = source.host(), !host.isEmpty else { return nil }
        if scheme == "https", destination.scheme?.lowercased() != "https" { return nil }
        func origin(_ url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }
        guard let from = origin(source) else { return nil }
        guard from == origin(destination) else { return from+"/" }
        var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        components?.fragment = nil; components?.user = nil; components?.password = nil
        return components?.string
    }

    /// How a main-frame navigation in `page` is allowed: an Open Here and its redirects without
    /// trying another app. A link tapped, a form sent, or Back or Forward meanwhile is the
    /// person's own again, and allowed as any other.
    func allowPolicy(for action: WKNavigationAction, in page: WKWebView) -> WKNavigationActionPolicy {
        guard openingHere.object(forKey: page) != nil else { return .allow }
        guard action.navigationType == .other || action.navigationType == .reload else {
            openingHere.removeObject(forKey: page); return .allow
        }
        return Self.allowWithoutAppLink
    }

    /// Once its page is committed, or it fails, an Open Here is over.
    func finishOpeningHere(_ page: WKWebView, navigation: WKNavigation?) {
        guard let navigation, openingHere.object(forKey: page) === navigation else { return }
        openingHere.removeObject(forKey: page)
    }
}
