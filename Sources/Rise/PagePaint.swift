import AppKit
import WebKit

@MainActor private final class PagePaintBridge: NSObject, WKScriptMessageHandler {
    weak var watcher: PagePaintWatcher?
    init(_ watcher: PagePaintWatcher) { self.watcher = watcher }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme != "about" else { return }
        watcher?.didPaint(webView)
    }
}

/// WebKit fills a page that hasn't painted yet with white, which flashes in Dark. Until its
/// first paint, a page in Dark draws no background, so the dark surface behind it shows
/// instead. After that it draws normally again: pages without a background of their own
/// rely on WebKit's white. Later navigations keep showing the old page until the new one
/// paints, so they don't flash.
@MainActor final class PagePaintWatcher {
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

    func install(on webView: WKWebView, dark: Bool) {
        let controller = webView.configuration.userContentController
        // window.open can supply a configuration sharing the opener's controller.
        if !controllers.contains(controller) {
            controllers.add(controller)
            controller.add(PagePaintBridge(self), contentWorld: Self.world, name: "risePainted")
            controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                                 forMainFrameOnly: true, in: Self.world))
        }
        applyTheme(dark: dark, to: webView)
    }
    func applyTheme(dark: Bool, to webView: WKWebView) {
        guard !painted.contains(webView) else { return }
        Self.setDrawsBackground(!dark, on: webView)
    }
    func hasPainted(_ webView: WKWebView) -> Bool { painted.contains(webView) }
    func didPaint(_ webView: WKWebView) {
        guard !painted.contains(webView) else { return }
        painted.add(webView)
        Self.setDrawsBackground(true, on: webView)
    }
    /// A finished load on screen has painted, even if its script never ran.
    func didFinish(_ webView: WKWebView) {
        guard webView.window != nil, webView.url?.scheme != "about" else { return }
        didPaint(webView)
    }
    static func drawsBackground(_ webView: WKWebView) -> Bool { webView.value(forKey: "drawsBackground") as? Bool ?? true }
    private static func setDrawsBackground(_ value: Bool, on webView: WKWebView) {
        if drawsBackground(webView) != value { webView.setValue(value, forKey: "drawsBackground") }
    }
}
