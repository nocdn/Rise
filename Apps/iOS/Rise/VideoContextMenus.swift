import UIKit
import WebKit

/// One native context-menu interaction follows a page even when a Peek hands it to a tab.
@MainActor final class VideoContextMenus: NSObject, WKScriptMessageHandler, UIContextMenuInteractionDelegate {
    private static let installed = NSMapTable<WKWebView, VideoContextMenus>.weakToStrongObjects()
    private static let symbols: [String: UIImage] = Dictionary(uniqueKeysWithValues:
        ["play", "pause", "speaker.wave.2", "speaker.slash", "arrow.up.left.and.arrow.down.right",
         "pip", "link", "square.and.arrow.up", "arrow.down.circle"].compactMap { name in
            UIImage(systemName: name).map { (name, $0) }
        })
    private weak var page: WKWebView?
    private weak var browser: BrowserViewController?
    private let authorization: String
    private var observer: TouchObserver!
    private var nonce = ""
    private var touchTime: CFTimeInterval = 0
    private var touchPoint = CGPoint.zero
    private var selection: Selection?
    private var menuAnchor: VideoContextMenuAnchor?
    private var showing = false
    private var afterDismissal: (() -> Void)?

    struct Selection {
        let token: String
        let frame: WKFrameInfo
        let rect: CGRect
        let state: [String: Any]
    }

    static func install(on page: WKWebView, browser: BrowserViewController) {
        if let installed = installed.object(forKey: page) { installed.browser = browser; return }
        let menu = VideoContextMenus(page: page, browser: browser)
        installed.setObject(menu, forKey: page)
    }
    private init(page: WKWebView, browser: BrowserViewController) {
        self.page = page; self.browser = browser; authorization = browser.videoPlayback.menuAuthorization
        super.init()
        // Resolve the symbols once, before a long press, rather than loading them in
        // UIKit's first menu animation. Later pages reuse the same immutable images.
        _ = Self.symbols
        page.configuration.userContentController.add(self, name: "riseVideoMenu")
        observer = TouchObserver { [weak self] point in self?.probe(at: point) }
        observer.moved = { [weak self] in self?.cancelProbe() }
        page.addGestureRecognizer(observer)
        page.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func cancelProbe() {
        selection = nil; nonce = ""
        if !showing { menuAnchor?.finish(); menuAnchor = nil }
    }
    private func probe(at point: CGPoint) {
        guard !showing, let page else { return }
        cancelProbe()
        nonce = UUID().uuidString; selection = nil; touchPoint = point; touchTime = CACurrentMediaTime()
        page.callAsyncJavaScript("window.__riseVideoMenu?.probeNativePoint(x, y, width, height, nonce)",
            arguments: ["x":point.x, "y":point.y, "width":page.bounds.width, "height":page.bounds.height, "nonce":nonce],
            in: nil, in: .page, completionHandler: nil)
        let probedNonce = nonce
        DispatchQueue.main.asyncAfter(deadline: .now()+2) { [weak self] in
            guard let self, nonce == probedNonce, !showing else { return }
            cancelProbe()
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === page, let body = message.body as? [String: Any],
              body["nonce"] as? String == nonce, CACurrentMediaTime()-touchTime < 2,
              let token = body["token"] as? String, token.count <= 128,
              let rect = body["rect"] as? [Double], rect.count == 4, rect.allSatisfy(\.isFinite),
              rect[2] > 0, rect[3] > 0 else { return }
        selection = Selection(token: token, frame: message.frameInfo, rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), state: body)
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !showing, let page, let selection, CACurrentMediaTime()-touchTime < 2,
              hypot(location.x-touchPoint.x, location.y-touchPoint.y) < 24 else { return nil }
        menuAnchor?.finish(); menuAnchor = nil
        guard let anchor = VideoContextMenuAnchor(page: page, point: location) else { return nil }
        menuAnchor = anchor
        // The touch probe already returned the menu state. Avoid a second WebKit round trip
        // or a deferred-menu resize while UIKit is animating the preview into place.
        return UIContextMenuConfiguration(identifier: selection.token as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: actions(for: selection, state: selection.state))
        }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
        menuAnchor?.targeted
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
        // Only the invisible finger anchor participates in UIKit's transition.
        menuAnchor?.targeted
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        showing = true; browser?.isVideoContextMenuOpen = true
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionAnimating?) {
        let finish = { [weak self] in
            guard let self else { return }
            menuAnchor?.finish(); menuAnchor = nil
            showing = false; selection = nil; nonce = ""; browser?.isVideoContextMenuOpen = false
            let action = afterDismissal; afterDismissal = nil; action?()
            browser?.applyPendingChanges()
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }
    private func afterMenu(_ action: @escaping () -> Void) {
        if showing { afterDismissal = action } else { action() }
    }
    private func actions(for selection: Selection, state: [String: Any]) -> [UIMenuElement] {
        func command(_ title: String, _ symbol: String, _ command: String, enabled: Bool = true) -> UIAction {
            UIAction(title: title, image: Self.symbols[symbol], attributes: enabled ? [] : .disabled) { [weak self] _ in
                self?.afterMenu { [weak self] in Task { await self?.perform(command, on: selection) } }
            }
        }
        let paused = state["paused"] as? Bool == true, muted = state["muted"] as? Bool == true
        var playback: [UIMenuElement] = [command(paused ? "Play" : "Pause", paused ? "play" : "pause", paused ? "play" : "pause"),
            command(muted ? "Unmute" : "Mute", muted ? "speaker.wave.2" : "speaker.slash", muted ? "unmute" : "mute")]
        if state["fullscreen"] as? Bool == true { playback.append(command("Enter Full Screen", "arrow.up.left.and.arrow.down.right", "fullscreen", enabled: state["ready"] as? Bool == true)) }
        if state["pip"] as? Bool == true { playback.append(command("Picture in Picture", "pip", "pip", enabled: state["ready"] as? Bool == true)) }
        var actions: [UIMenuElement] = [UIMenu(options: .displayInline, children: playback)]
        if let address = state["url"] as? String, let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
            var links: [UIMenuElement] = [UIAction(title: "Copy Video Address", image: Self.symbols["link"]) { [weak self] _ in
                self?.afterMenu { UIPasteboard.general.url = url }
            }, UIAction(title: "Share Video", image: Self.symbols["square.and.arrow.up"]) { [weak self] _ in
                self?.afterMenu { [weak self] in self?.share(url, from: selection.rect) }
            }]
            if state["downloadable"] as? Bool == true {
                links.append(UIAction(title: "Download Video", image: Self.symbols["arrow.down.circle"]) { [weak self] _ in
                    self?.afterMenu { [weak self] in self?.download(url, from: selection.rect) }
                })
            }
            actions.append(UIMenu(options: .displayInline, children: links))
        }
        return actions
    }
    private func perform(_ command: String, on selection: Selection) async {
        guard let page else { return }
        do {
            let result = try await page.callAsyncJavaScript("return await window.__riseVideoMenu?.perform(token, command, authorization)",
                arguments: ["token":selection.token, "command":command, "authorization":authorization], in: selection.frame, contentWorld: .page) as? Bool
            if result != true { showError("This video is no longer available.") }
        } catch { showError("The video couldn't complete that action. Try its own playback controls.") }
    }
    private func share(_ url: URL, from rect: CGRect) {
        guard let page, let browser, browser.presentedViewController == nil else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = page
        share.popoverPresentationController?.sourceRect = rect.intersection(page.bounds)
        browser.present(share, animated: true)
    }
    private func download(_ url: URL, from rect: CGRect) {
        guard let page else { return }
        let origin = page.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        // Keep the request in this page's WebKit data store and download pipeline.
        page.startDownload(using: URLRequest(url: url)) { download in MobileDownloads.shared.begin(download, origin: origin, requiresVideoFile: true) }
    }
    private func showError(_ message: String) {
        guard let browser, browser.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Couldn't update video", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); browser.present(alert, animated: true)
    }

    private final class TouchObserver: UIGestureRecognizer {
        let began: (CGPoint) -> Void
        var moved: (() -> Void)?
        private var start: CGPoint?
        init(began: @escaping (CGPoint) -> Void) {
            self.began = began
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
        }
        override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touches.count == 1, let touch = touches.first, let view else { moved?(); state = .failed; return }
            let point = touch.location(in: view); start = point; began(point)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let start, let touch = touches.first, let view else { return }
            let now = touch.location(in: view)
            if hypot(now.x-start.x, now.y-start.y) > 14 { moved?(); state = .failed }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    }
}
