import AppKit

/// The settings page's banner offering to make Rise the default browser. macOS asks the person to
/// confirm; dismissing the banner hides it for good, and System Settings can still choose Rise.
@MainActor extension BrowserController {
    static let defaultBrowserBannerDismissedKey = "Rise.DefaultBrowserBannerDismissed"

    /// Whether web links open in Rise, any build of it.
    static func opensWebLinks(_ scheme: String) -> Bool {
        guard let id = Bundle.main.bundleIdentifier, let url = URL(string: "\(scheme)://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: app)?.bundleIdentifier == id
    }
    static var isDefaultBrowser: Bool { opensWebLinks("http") && opensWebLinks("https") }

    var showsDefaultBrowserBanner: Bool {
        !Self.isDefaultBrowser && !preferences.bool(forKey: Self.defaultBrowserBannerDismissedKey)
    }

    /// `action` is `state`, `set` or `dismiss`; each answers with whether the banner still shows.
    func handleDefaultBrowserRequest(_ body: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        switch body["action"] as? String {
        case "set": makeDefaultBrowser { [weak self] in reply(["shown": self?.showsDefaultBrowserBanner ?? false], nil) }
        case "dismiss":
            preferences.set(true, forKey: Self.defaultBrowserBannerDismissedKey)
            reply(["shown": false], nil)
        default: reply(["shown": showsDefaultBrowserBanner], nil)
        }
    }

    /// macOS asks once, for the browser, and https usually follows http. If it doesn't, Rise asks
    /// for https too, but not after a no.
    func makeDefaultBrowser(_ done: @escaping @MainActor () -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            DispatchQueue.main.async {
                guard Self.opensWebLinks("http"), !Self.opensWebLinks("https") else { done(); return }
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                    DispatchQueue.main.async { done() }
                }
            }
        }
    }
}
