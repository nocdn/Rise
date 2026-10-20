import WebKit

/// One preference for normal tabs, private tabs and Peeks. Existing pages update without
/// reloading; replacing only our user script also keeps the next navigation up to date.
@MainActor final class VideoPlaybackPolicy {
    static let shared = VideoPlaybackPolicy()
    private static let preferenceKey = "autoplayVideos"
    private static let scriptMarker = "// Rise video playback policy\n"
    private let preferences: UserDefaults
    private let pages = NSHashTable<WKWebView>.weakObjects()
    /// A capability for explicit native menu commands; page scripts cannot approve themselves.
    let menuAuthorization = UUID().uuidString

    var allowsAutoplay: Bool { preferences.object(forKey: Self.preferenceKey) as? Bool ?? true }

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.allowsInlineMediaPlayback = true
        // Keep WebKit's audible-playback gesture requirement. The script handles the video
        // switch, including muted autoplay, and can change it on an already-created web view.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        installScript(in: configuration.userContentController)
    }

    func track(_ page: WKWebView) { pages.add(page) }

    func setAllowsAutoplay(_ enabled: Bool) {
        guard enabled != allowsAutoplay else { return }
        preferences.set(enabled, forKey: Self.preferenceKey)
        for page in pages.allObjects {
            installScript(in: page.configuration.userContentController)
            page.evaluateJavaScript("window.__riseVideoPlayback?.setAutoplay(\(enabled))", completionHandler: nil)
        }
    }

    private func installScript(in controller: WKUserContentController) {
        let retained = controller.userScripts.filter { !$0.source.hasPrefix(Self.scriptMarker) }
        controller.removeAllUserScripts()
        retained.forEach(controller.addUserScript)
        controller.addUserScript(WKUserScript(source: Self.scriptMarker + VideoPlaybackScript.source(allowsAutoplay: allowsAutoplay, menuAuthorization: menuAuthorization),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }
}
