import UIKit
import WebKit

@MainActor private final class PagePaintBridge: NSObject, WKScriptMessageHandler {
    weak var watcher: PagePaintWatcher?
    init(_ watcher: PagePaintWatcher) { self.watcher = watcher }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Any document counts, about: ones too: pages here start empty rather than on a blank document.
        guard let webView = message.webView, message.frameInfo.isMainFrame else { return }
        watcher?.didPaint(webView)
    }
}

/// As on the Mac: WebKit fills a page that hasn't painted yet with white, which flashes in dark
/// mode. Until its first paint, a page in dark mode is transparent, so the dark surface behind it
/// shows instead. After that it's opaque again: pages without a background of their own rely on
/// WebKit's white. Later navigations keep showing the old page until the new one paints, so they
/// don't flash.
@MainActor final class PagePaintWatcher {
    static let shared = PagePaintWatcher()
    /// Posted with the page as its object when it first paints.
    static let didPaint = Notification.Name("PagePaintWatcher.didPaint")
    static let world = WKContentWorld.world(name: "Rise.PagePaint")
    /// Two frames after the document is parsed, its first frame is on screen. Hidden pages
    /// don't run frames, so they report once they're first shown.
    static let script = """
    (() => {
      if (window.top !== window) return;
      const post = () => requestAnimationFrame(() => requestAnimationFrame(() => webkit.messageHandlers.risePainted.postMessage(0)));
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", post, { once: true });
      else post();
    })();
    """
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let painted = NSHashTable<WKWebView>.weakObjects()
    /// The backgrounds a transparent page had, to put back once it paints.
    private var opaque: [ObjectIdentifier: (view: UIColor?, scroll: UIColor?)] = [:]

    /// Whether the app is showing dark, as new pages are made before they're in a window.
    static var isDark: Bool {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .dark
    }

    func install(on webView: WKWebView, dark: Bool = PagePaintWatcher.isDark) {
        let controller = webView.configuration.userContentController
        if !controllers.contains(controller) {
            controllers.add(controller)
            controller.add(PagePaintBridge(self), contentWorld: Self.world, name: "risePainted")
            controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                                 forMainFrameOnly: true, in: Self.world))
        }
        guard dark, !painted.contains(webView), webView.isOpaque else { return }
        opaque[ObjectIdentifier(webView)] = (webView.backgroundColor, webView.scrollView.backgroundColor)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
    }

    /// Whether the page is still waiting to paint, showing what's behind it.
    func isTransparent(_ webView: WKWebView) -> Bool { opaque[ObjectIdentifier(webView)] != nil }

    func didPaint(_ webView: WKWebView) {
        guard !painted.contains(webView) else { return }
        painted.add(webView)
        guard let backgrounds = opaque.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        webView.isOpaque = true
        webView.backgroundColor = backgrounds.view
        webView.scrollView.backgroundColor = backgrounds.scroll
        NotificationCenter.default.post(name: Self.didPaint, object: webView)
    }

    /// A finished load on screen has painted, even if its script never ran.
    func didFinish(_ webView: WKWebView) {
        guard webView.window != nil else { return }
        didPaint(webView)
    }
}
