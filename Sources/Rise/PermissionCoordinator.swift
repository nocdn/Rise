import AppKit
import UserNotifications

/// A single native prompt owns its completion. Its ✕, tab changes and navigation deny it once;
/// a permission can only be saved by choosing its ✓. A click elsewhere leaves the prompt, and its
/// icon in the bar puts it away unanswered and brings it back.
@MainActor final class PermissionCoordinator: NSObject, UNUserNotificationCenterDelegate {
    weak var browser: BrowserController?
    /// The prompt: Find's panel, coming down from under the asking page's bar.
    let panel = PermissionPanel()
    /// The page asking, as its view, and the bar over it, whose icon for what it asks shows meanwhile.
    private weak var requestingWebView: NSView?
    private weak var requestingBar: PlainNavBar?
    private var reply: ((Bool) -> Void)?
    var requestNotificationAuthorization: (@escaping (Bool) -> Void) -> Void = { done in
        guard Bundle.main.bundleIdentifier != nil else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            Task { @MainActor in done(allowed) }
        }
    }
    init(browser: BrowserController) {
        self.browser = browser; super.init()
        panel.applyTheme(browser.theme)
        panel.answer = { [weak self] in self?.resolve($0) }
        panel.onGone = { [weak self] in self?.panelGone() }
    }
    private let pages = NSHashTable<AnyObject>.weakObjects()
    func install(on page: WebPage) {
        guard !pages.contains(page) else { return }
        pages.add(page)
        page.addMessageHandler("riseSiteControls", world: .page) { [weak self] message, reply in
            let origin = message.frame.origin.flatMap(URL.init(string:))
            guard let self, message.frame.isMain, let view = message.page?.view else { reply(nil, "Invalid origin"); return }
            self.receive(message.body, origin: SitePermissions.origin(origin), host: origin?.host, in: view, reply: reply)
        }
        page.addUserScript(Self.script, world: .page, mainFrameOnly: true, handlers: ["riseSiteControls"])
    }
    /// `web` is the asking page's view.
    func request(in web: NSView, origin: String?, capabilities: [SiteCapability], completion: @escaping (Bool) -> Void) {
        guard !capabilities.isEmpty, let browser, let origin, let url = URL(string: origin),
              url.scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              web.window === browser.window, !web.isHidden,
              browser.visibleTabIDs.contains(where: { id in browser.tabs.contains { $0.id == id && $0.page.view === web } }) || browser.peekTab?.page.view === web else { completion(false); return }
        let decisions = capabilities.map { browser.sitePermissions.permission($0, origin: origin) }
        guard !decisions.contains(.block) else { completion(false); return }
        if decisions.allSatisfy({ $0 == .allow }) { completion(true); return }
        // The page asking the same again while it waits brings a prompt put away back down, and
        // is answered with it.
        if reply != nil, let waiting, requestingWebView === web, waiting.origin == origin, waiting.capabilities == capabilities {
            waiting.completions.append(completion)
            if !panel.isPresented { snoozed = false; showPrompt() }
            return
        }
        guard reply == nil else { completion(false); return }
        browser.siteControlsPopover.close(); browser.siteInfoPopover.close()
        requestingWebView = web
        let documentURL = browser.page(showing: web)?.url
        let waiting = Waiting(origin: origin, capabilities: capabilities, completion: completion)
        self.waiting = waiting
        reply = { [weak self, weak browser, weak web] allowed in
            guard let browser, let web, web.window === browser.window else { waiting.answer(false); return }
            let finish: (Bool) -> Void = { [weak web, weak browser] granted in
                guard let browser, let web, browser.page(showing: web)?.url == documentURL, web.window === browser.window else { waiting.answer(false); return }
                if granted { capabilities.forEach { browser.sitePermissions.set(.allow, for: $0, origin: origin) } }
                waiting.answer(granted)
            }
            if allowed && capabilities.contains(.notifications), let self { self.requestNotificationAuthorization(finish) }
            else { finish(allowed) }
        }
        question = PermissionQuestion(host: url.host ?? origin, capabilities: capabilities)
        // Its icon shows in the bar over the asking page, and the prompt comes down under it.
        let bar = browser.pageBarTabs.first { $0.tab.page.view === web }?.bar ?? browser.selectedBar
        requestingBar = bar
        bar.requestedPermission = (capabilities.first?.tablerIcon ?? TablerIcon.camera, question?.heading ?? "")
        browser.layoutChrome(); bar.layoutSubtreeIfNeeded()
        // The icon grows in first, and the prompt comes down as it nears its size.
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let show = DispatchWorkItem { [weak self] in self?.pendingShow = nil; self?.showPrompt() }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now()+(still ? 0 : PlainNavBar.PermissionMotion.promptDelay), execute: show)
    }
    private var pendingShow: DispatchWorkItem?
    /// What the page now waiting asked for, and everyone waiting on the answer: it may ask again.
    private final class Waiting {
        let origin: String, capabilities: [SiteCapability]
        var completions: [(Bool) -> Void]
        init(origin: String, capabilities: [SiteCapability], completion: @escaping (Bool) -> Void) {
            self.origin = origin; self.capabilities = capabilities; completions = [completion]
        }
        func answer(_ granted: Bool) { let all = completions; completions = []; all.forEach { $0(granted) } }
    }
    private var waiting: Waiting?
    /// What the request now asks, which the panel takes as it comes down.
    private(set) var question: PermissionQuestion?
    /// A bar whose answered prompt is going back up under it, whose icon goes once it has.
    private weak var leavingBar: PlainNavBar?
    var isShowingPrompt: Bool { panel.isPresented }
    /// Its icon puts the prompt away unanswered, and brings it back.
    func togglePrompt() {
        guard reply != nil else { return }
        if panel.isPresented { snoozed = true; panel.hide() } else { snoozed = false; showPrompt() }
    }
    /// Put away from its icon, it stays away until the icon brings it back.
    private var snoozed = false
    /// The prompt, again if it was put away; one going away from an earlier request finishes first.
    func showPrompt() {
        guard reply != nil, let question, !panel.isPresented, !panel.isLeaving, let browser,
              let web = requestingWebView, web.window === browser.window else { return }
        snoozed = false
        panel.ask(question)
        layoutPanel()
        panel.present()
    }
    /// Over the asking page, under its bar, in front of the pages and behind Find, held below an open find panel.
    func layoutPanel() {
        guard let browser, let web = requestingWebView ?? (panel.isHidden ? nil : lastPageView) else { return }
        lastPageView = web
        let root = browser.root
        let findBar = browser.selectedFindBar
        if panel.superview !== root {
            if findBar.superview === root { root.addSubview(panel, positioned: .below, relativeTo: findBar) }
            else { root.addSubview(panel, positioned: .below, relativeTo: browser.linkStatus) }
        }
        let page = browser.pageShadow.frame, column = web.convert(web.bounds, to: root)
        let left = max(page.minX, column.minX), right = min(page.maxX, column.maxX)
        panel.frame = right-left > 100 ? NSRect(x: left, y: page.minY, width: right-left, height: page.height) : page
        panel.topInset = PlainNavBar.Metrics.height
        let findOpen = findBar.isPresented && findBar.superview === root && abs(findBar.frame.maxX-panel.frame.maxX) < 1
        panel.stackOffset = findOpen ? findBar.panel.frame.height+FindBar.top : 0
    }
    private weak var lastPageView: NSView?
    func applyTheme(_ theme: RiseTheme) { panel.applyTheme(theme) }
    /// Answered, the page hears at once, and the prompt goes back up under the bar, its icon then going.
    func resolve(_ allowed: Bool) {
        guard let completion = reply else { return }
        reply = nil; requestingWebView = nil; waiting = nil; snoozed = false
        pendingShow?.cancel(); pendingShow = nil
        let bar = requestingBar; requestingBar = nil
        if panel.isPresented || panel.isLeaving { leavingBar = bar; panel.hide() } else { removeIcon(from: bar) }
        completion(allowed)
    }
    private func removeIcon(from bar: PlainNavBar?) {
        // A page asking again from the same bar meanwhile keeps its icon.
        guard let bar, bar !== requestingBar else { return }
        bar.requestedPermission = nil; browser?.layoutChrome()
    }
    func cancel(for web: NSView? = nil) {
        if web == nil || requestingWebView === web { resolve(false) }
    }
    /// A page that asked again while one went gets its prompt once it's gone, unless its icon
    /// put the prompt away.
    private func panelGone() {
        removeIcon(from: leavingBar); leavingBar = nil
        if reply != nil, !snoozed, pendingShow == nil { showPrompt() }
    }
    /// A request from the site controls script in a page's main frame, as its view, from
    /// `origin`, which must still be the page's own.
    func receive(_ message: Any, origin: String?, host: String?, in web: NSView, reply: @escaping (Any?, String?) -> Void) {
        guard let browser, let origin, origin == SitePermissions.origin(browser.page(showing: web)?.url),
              let body = message as? [String: Any], let kind = body["kind"] as? String else { reply(nil, "Invalid origin"); return }
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
            content.title = String(title.prefix(200)); content.subtitle = host ?? ""
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

    // Pages' notifications, asked for in Rise's own prompt and shown through UserNotifications,
    // without claiming Push API support.
    static let script = #"""
    (() => {
      if (window.riseSiteControls || !window.isSecureContext) return;
      const send = body => riseHandlers.riseSiteControls.postMessage(body);
      let permission = 'default', pip = true;
      const refresh = () => send({kind:'status'}).then(value => { permission = value.notifications; pip = value.pip; }).catch(() => {});
      window.riseSiteControls = { refresh, autoPiP() {
        if (!pip) return;
        // Runs when Rise leaves the foreground. Leaving a tab floats its video in
        // Rise's own player instead, on every site. Rise owns YouTube's player and
        // its page, so the system's separate picture in picture never starts there.
        if (/(^|\.)youtube\.com$/.test(location.hostname)) return;
        // Only video with sound, so muted previews and background loops stay put.
        const video = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState >= 2 && !v.muted && v.volume > 0);
        if (!video) return;
        try {
          if (document.pictureInPictureEnabled && !document.pictureInPictureElement) video.requestPictureInPicture().catch(() => {});
        } catch {}
      }};
      refresh();
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
