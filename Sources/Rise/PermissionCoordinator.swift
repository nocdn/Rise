import AppKit
import WebKit
import UserNotifications

@MainActor private final class PermissionBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: PermissionCoordinator?
    init(_ owner: PermissionCoordinator) { self.owner = owner }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Browser closed"); return }
        owner.receive(message, reply: replyHandler)
    }
}

/// A single native prompt owns its completion. Dismissal, tab changes and
/// navigation deny it once; a permission can only be saved by choosing Allow.
@MainActor final class PermissionCoordinator: NSObject, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    weak var browser: BrowserController?
    let popover = NSPopover()
    private weak var requestingWebView: WKWebView?
    private var reply: ((Bool) -> Void)?
    private var controllers = NSHashTable<WKUserContentController>.weakObjects()
    var requestNotificationAuthorization: (@escaping (Bool) -> Void) -> Void = { done in
        guard Bundle.main.bundleIdentifier != nil else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            Task { @MainActor in done(allowed) }
        }
    }
    init(browser: BrowserController) {
        self.browser = browser; super.init()
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
    }
    func install(on web: WKWebView) {
        let content = web.configuration.userContentController
        guard !controllers.contains(content) else { return }
        controllers.add(content)
        content.addScriptMessageHandler(PermissionBridge(self), contentWorld: .page, name: "riseSiteControls")
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    func request(in web: WKWebView, origin: String?, capabilities: [SiteCapability], completion: @escaping (Bool) -> Void) {
        guard !capabilities.isEmpty, let browser, let origin, let url = URL(string: origin),
              url.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              web.window === browser.window, !web.isHidden,
              browser.visibleTabIDs.contains(where: { id in browser.tabs.contains { $0.id == id && $0.webView === web } }) || browser.peekTab?.webView === web else { completion(false); return }
        let decisions = capabilities.map { browser.sitePermissions.permission($0, origin: origin) }
        guard !decisions.contains(.block) else { completion(false); return }
        if decisions.allSatisfy({ $0 == .allow }) { completion(true); return }
        guard reply == nil else { completion(false); return }
        browser.siteControlsPopover.close(); browser.siteInfoPopover.close()
        browser.copiedLinkPopover.close()
        browser.showSidebarAtOnce()
        requestingWebView = web
        let documentURL = web.url
        reply = { [weak self, weak browser, weak web] allowed in
            guard let browser, let web, web.window === browser.window else { completion(false); return }
            let finish: (Bool) -> Void = { [weak web, weak browser] granted in
                guard let browser, let web, web.url == documentURL, web.window === browser.window else { completion(false); return }
                if granted { capabilities.forEach { browser.sitePermissions.set(.allow, for: $0, origin: origin) } }
                completion(granted)
            }
            if allowed && capabilities.contains(.notifications), let self { self.requestNotificationAuthorization(finish) }
            else { finish(allowed) }
        }
        let controller = PermissionPromptController(host: url.host ?? origin, capabilities: capabilities) { [weak self] in self?.resolve($0) }
        popover.appearance = browser.theme.appearance
        controller.view.appearance = browser.theme.appearance
        popover.contentViewController = controller; popover.contentSize = controller.view.frame.size
        popover.show(relativeTo: browser.sidebar.settingsAnchorRect, of: browser.sidebar.address, preferredEdge: .maxY)
    }
    func resolve(_ allowed: Bool) {
        let completion = reply; reply = nil; requestingWebView = nil
        popover.close(); completion?(allowed)
    }
    func cancel(for web: WKWebView? = nil) {
        if web == nil || requestingWebView === web { resolve(false) }
    }
    func popoverDidClose(_ notification: Notification) { resolve(false) }
    func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        guard let browser, let web = message.webView, message.frameInfo.isMainFrame,
              let origin = SitePermissions.origin(message.frameInfo.securityOrigin),
              origin == SitePermissions.origin(web.url),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { reply(nil, "Invalid origin"); return }
        switch kind {
        case "status":
            let status = browser.sitePermissions.permission(.notifications, origin: origin)
            reply(["notifications": status == .allow ? "granted" : status == .block ? "denied" : "default",
                   "pip": browser.sitePermissions.automaticPictureInPicture(origin: origin)], nil)
        case "permission":
            request(in: web, origin: origin, capabilities: [.notifications]) { [weak browser] allowed in
                reply(allowed ? "granted" : browser?.sitePermissions.permission(.notifications, origin: origin) == .block ? "denied" : "default", nil)
            }
        case "notify":
            guard browser.sitePermissions.permission(.notifications, origin: origin) == .allow,
                  Bundle.main.bundleIdentifier != nil, let title = body["title"] as? String else { reply(nil, "Notifications not allowed"); return }
            let content = UNMutableNotificationContent()
            content.title = String(title.prefix(200)); content.subtitle = message.frameInfo.securityOrigin.host
            content.body = String((body["body"] as? String ?? "").prefix(2000)); content.sound = body["silent"] as? Bool == true ? nil : .default
            let id = Self.notificationID(origin: origin, identifier: body["id"] as? String ?? UUID().uuidString)
            let center = UNUserNotificationCenter.current(); center.delegate = self
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                Task { @MainActor in reply(error == nil, error?.localizedDescription) }
            }
        case "close":
            if Bundle.main.bundleIdentifier != nil, let id = body["id"] as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID(origin: origin, identifier: id)])
            }
            reply(true, nil)
        default: reply(nil, "Unknown request")
        }
    }
    private static func notificationID(origin: String, identifier: String) -> String { "Rise.Web.\(origin).\(identifier.prefix(200))" }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Public WKWebView has no web-push permission delegate. Supply page-open
    // notifications through UserNotifications, without claiming Push API support.
    static let script = #"""
    (() => {
      if (window.riseSiteControls || !window.isSecureContext) return;
      const send = body => window.webkit.messageHandlers.riseSiteControls.postMessage(body);
      let permission = 'default', pip = true;
      const refresh = () => send({kind:'status'}).then(value => { permission = value.notifications; pip = value.pip; }).catch(() => {});
      window.riseSiteControls = { refresh, autoPiP() {
        if (!pip) return;
        // Runs when Rise leaves the foreground. Leaving a tab floats its video in
        // Rise's own player instead, on every site. Rise owns YouTube's player and
        // its original web view, so WebKit's separate native PiP never starts there.
        if (/(^|\.)youtube\.com$/.test(location.hostname)) return;
        // Only video with sound, so muted previews and background loops stay put.
        const video = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState >= 2 && !v.muted && v.volume > 0);
        if (!video) return;
        try {
          if (video.webkitSupportsPresentationMode?.('picture-in-picture')) video.webkitSetPresentationMode('picture-in-picture');
          else if (document.pictureInPictureEnabled && !document.pictureInPictureElement) video.requestPictureInPicture().catch(() => {});
        } catch {}
      }};
      refresh();
      // WKWebView can expose Notification without a public permission delegate.
      // Own the page-open API so every request uses the same native site prompt.
      class RiseNotification extends EventTarget {
        static get permission() { return permission; }
        static async requestPermission(callback) {
          if (permission === 'default') {
            if (!navigator.userActivation?.isActive) return 'default';
            permission = await send({kind:'permission'}).catch(() => 'default');
          }
          callback?.(permission); return permission;
        }
        constructor(title, options = {}) {
          super();
          if (permission !== 'granted') throw new DOMException('Notifications are not allowed', 'NotAllowedError');
          this.title = String(title); this.body = String(options.body || ''); this.tag = String(options.tag || '');
          this.id = this.tag || crypto.randomUUID();
          send({kind:'notify', id:this.id, title:this.title, body:this.body, silent:!!options.silent})
            .then(() => { const event = new Event('show'); this.dispatchEvent(event); this.onshow?.(event); })
            .catch(() => { const event = new Event('error'); this.dispatchEvent(event); this.onerror?.(event); });
        }
        close() { send({kind:'close', id:this.id}).catch(() => {}); const event = new Event('close'); this.dispatchEvent(event); this.onclose?.(event); }
      }
      window.Notification = RiseNotification;
    })();
    """#
}
