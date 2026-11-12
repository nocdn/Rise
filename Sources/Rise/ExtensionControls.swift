import AppKit
import RiseChromium

/// Chrome extensions in Rise's chrome, as Arc has them: pinned ones in the sidebar's address row,
/// every one in the site controls popover (where they're pinned and unpinned), and their popups in
/// the hover cards' card, under the button that opened them.
@MainActor extension BrowserController {
    static let pinnedExtensionsKey = "Rise.PinnedExtensions"
    static let pinnedExtensionsChanged = Notification.Name("Rise.PinnedExtensionsChanged")
    /// Pinned extensions' ids, in the order they show.
    var pinnedExtensions: [String] { preferences.stringArray(forKey: Self.pinnedExtensionsKey) ?? [] }
    func setExtension(_ id: String, pinned: Bool) {
        var ids = pinnedExtensions.filter { $0 != id }
        if pinned { ids.append(id) }
        preferences.set(ids, forKey: Self.pinnedExtensionsKey)
        NotificationCenter.default.post(name: Self.pinnedExtensionsChanged, object: nil)
    }
    /// The pinned extensions in the order the page bar's buttons were dragged into; any pinned but
    /// not showing keep their places among them.
    func setPinnedExtensionOrder(_ shown: [String]) {
        var rest = shown.makeIterator()
        let ids = pinnedExtensions.map { shown.contains($0) ? rest.next() ?? $0 : $0 }
        guard ids != pinnedExtensions else { return }
        preferences.set(ids, forKey: Self.pinnedExtensionsKey)
        NotificationCenter.default.post(name: Self.pinnedExtensionsChanged, object: nil)
    }
    /// ⌥⇧1 to ⌥⇧9: the pinned extension that many from the left, as if its button were clicked;
    /// again while its popup shows, it closes. False when there's no extension there.
    func openPinnedExtension(at index: Int) -> Bool {
        let buttons = navBar.extensionButtons
        guard buttons.indices.contains(index) else { return false }
        let button = buttons[index]
        if let popup = extensionPopup, popup.anchor === button { popup.close(); return true }
        button.runAction()
        return true
    }
    var extensionActions: [RCExtensionAction] { (extensionWindow as? ExtensionWindow)?.actions ?? [] }
    /// The page extensions act on: the selected tab's, when it's Chromium's.
    var selectedChromiumView: RCBrowserView? { (selectedTab?.page as? ChromiumPage)?.browserView }
    /// The page extensions are run on from the menus, the site controls and their shortcuts: an open Peek's.
    var commandChromiumView: RCBrowserView? { (commandTab?.page as? ChromiumPage)?.browserView }

    /// Clicks extension `id`'s button for the selected tab; its popup, if any, opens under
    /// `anchor` (in the page bar), or the site controls button.
    func runExtension(_ id: String, anchor: NSView? = nil) {
        guard let tab = commandChromiumView, let action = extensionActions.first(where: { $0.extensionID == id }) else { return }
        siteControlsPopover.close()
        guard let url = action.click(inTab: tab) else { return }
        showExtensionPopup(url, extensionID: id, anchor: anchor)
    }

    /// Also used by chrome.action.openPopup(), without granting any additional tab access.
    /// API requests fail if a popup already owns the slot, as they do in Chrome.
    func showExtensionPopup(_ url: URL, extensionID: String, anchor: NSView? = nil, completion: ((Bool) -> Void)? = nil) {
        AuthenticationDiagnostics.popups.notice("Popup requested byAPI=\(completion != nil)")
        guard url.scheme == "chrome-extension", url.host == extensionID,
              extensionActions.contains(where: { $0.extensionID == extensionID }),
              completion == nil || extensionPopup == nil else {
            AuthenticationDiagnostics.popups.notice("Popup refused invalidActionOrExistingPopup=1")
            completion?(false); return
        }
        siteControlsPopover.close()
        // One the extension opens itself (chrome.action.openPopup) comes from its pinned button
        // too, as a click on it does; or the site controls, as when it isn't pinned.
        let anchor = anchor ?? navBar.extensionButtons.first {
            $0.extensionID == extensionID && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0
        }
        // An open Peek's comes out of its own bar's site controls, and stays inside its card.
        let anchorView: NSView = showsPeekBar ? (anchor.flatMap { $0.isDescendant(of: peekBar) ? $0 : nil } ?? peekBar.settingsButton)
            : anchor ?? selectedBar.settingsButton
        guard anchorView.window != nil else {
            AuthenticationDiagnostics.popups.notice("Popup refused missingWindow=1")
            completion?(false); return
        }
        extensionPopup?.close()
        let popup = spareExtensionPopup ?? ExtensionPopup()
        spareExtensionPopup = nil
        popup.apply(theme)
        popup.onShown = completion
        popup.onClose = { [weak self, weak popup] in
            guard let self, self.extensionPopup === popup else { return }
            self.extensionPopup = nil
            self.updatePeekCovers()
            if let page = popup?.page.view, let responder = self.window?.firstResponder as? NSView, responder.isDescendant(of: page) {
                self.window?.makeFirstResponder(self.selectedTab?.page.view)
            }
        }
        // The pages under the card would otherwise take its pointer for their own hover.
        popup.card.onPointer = { [weak self] inside in
            guard let self else { return }
            if inside { self.tabs.forEach { self.setCovered(true, $0) } } else { self.updatePeekCovers() }
        }
        // What the popup opens goes in tabs, as from Chrome's.
        popup.page.onPopup = { [weak self, weak popup] page, _ in
            guard let self else { return false }
            _ = self.addTab(page: page); popup?.close()
            return true
        }
        popup.page.onOpenElsewhere = { [weak self] url, background in
            self?.addTab(url: url, background: background); return true
        }
        extensionPopup = popup
        popup.bounds = { [weak self] in
            guard let self, self.showsPeekBar, let card = self.peekCard else { return nil }
            return card.convert(card.bounds, to: self.root)
        }
        raiseHoverCard(popup.card)
        popup.show(under: anchorView)
        popup.load(url)
        // The next one's page, once this one has opened.
        DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in self?.prepareSpareExtensionPopup() }
    }
    /// A popup's page made ahead, for any extension, with nothing loaded: making one takes 15 ms
    /// or so, on the main thread, between a press and its popup starting to load.
    func prepareSpareExtensionPopup() {
        guard spareExtensionPopup == nil, window != nil else { return }
        spareExtensionPopup = ExtensionPopup()
    }
    /// The pointer on an extension's button starts the extension's process, which its popup
    /// shares, so a press opens it without waiting for one to start (100 ms or more). The page is
    /// its manifest, loaded out of sight with scripts off, so nothing of the extension runs; it
    /// goes ten seconds after the pointer leaves.
    /// A spare popup page is made then too, if there isn't one.
    func warmExtension(_ id: String, _ hovering: Bool) {
        if hovering {
            prepareSpareExtensionPopup()
            extensionWarmer?.ends?.cancel(); extensionWarmer?.ends = nil
            guard extensionWarmer?.id != id, let url = URL(string: "chrome-extension://\(id)/manifest.json") else { return }
            extensionWarmer.map { $0.page.browserView.close() }
            let page = ChromiumPage()
            page.browserView.scriptsDisabled = true
            page.load(url)
            extensionWarmer = (id, page, nil)
        } else if extensionWarmer?.id == id {
            let ends = DispatchWorkItem { [weak self] in
                guard let self, self.extensionWarmer?.id == id else { return }
                self.extensionWarmer?.page.browserView.close(); self.extensionWarmer = nil
            }
            extensionWarmer?.ends = ends
            DispatchQueue.main.asyncAfter(deadline: .now()+10, execute: ends)
        }
    }
    /// An extension's keyboard shortcut: its button's opens its popup, under its page bar button if
    /// it's pinned, as a click does; others go to the extension. False if `event` isn't one.
    func runExtensionShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = RCExtensions.shortcut(for: event) else { return false }
        if shortcut.clicksButton {
            runExtension(shortcut.extensionID, anchor: navBar.extensionButtons.first { $0.extensionID == shortcut.extensionID })
        } else {
            shortcut.run(inTab: commandChromiumView)
        }
        return true
    }
    /// Right-clicking an extension's button: pin or unpin it, or manage it.
    func extensionMenu(for action: RCExtensionAction) -> NSMenu {
        let id = action.extensionID, pinned = pinnedExtensions.contains(id)
        let menu = NSMenu()
        let name = NSMenuItem(title: action.name, action: nil, keyEquivalent: ""); name.isEnabled = false
        menu.addItem(name)
        menu.addItem(.separator())
        menu.addItem(menuItem(pinned ? "Unpin from Sidebar" : "Pin to Sidebar") { [weak self] in self?.setExtension(id, pinned: !pinned) })
        menu.addItem(menuItem("Manage Extension…") { [weak self] in self?.showExtensions(id) })
        return menu
    }
    /// Chrome's extensions page, as rise://extensions; open on one extension, given its id.
    func showExtensions(_ id: String? = nil) {
        siteControlsPopover.close()
        addTab(url: URL(string: id.map { "rise://extensions/?id=\($0)" } ?? "rise://extensions")!)
    }

    // MARK: Installing

    /// The Chrome Web Store extension a store page is about, if it is one.
    static func webStoreExtensionID(_ url: URL?) -> String? {
        guard let url, url.host?.lowercased() == "chromewebstore.google.com", url.path.hasPrefix("/detail/") else { return nil }
        return url.pathComponents.last { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }
    }
    func isExtensionInstalled(_ id: String) -> Bool { RCExtensions.actions.contains { $0.extensionID == id } }
    /// Installs a Web Store extension, after Rise's install sheet asks, and pins it, so it shows.
    func addFromWebStore(_ id: String) {
        siteControlsPopover.close()
        ExtensionWindow.setUpInstallPrompt()
        RCExtensions.install(fromWebStore: id) { [weak self] success, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if success {
                    if !self.pinnedExtensions.contains(id) { self.setExtension(id, pinned: true) }
                } else if let error, !error.localizedCaseInsensitiveContains("cancel") {
                    self.showMessage("Couldn’t add the extension", error)
                }
                self.refreshWebStoreButtons()
            }
        }
    }
    /// Rise's install sheet: what the extension asks to do, and whether to go ahead.
    func showInstallPrompt(title: String, icon: NSImage?, permissions: [String], acceptLabel: String, answer: @escaping (Bool) -> Void) {
        guard let window else { answer(false); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = permissions.isEmpty ? "It won’t need any special permissions."
            : "It can:\n" + permissions.map { "• \($0)" }.joined(separator: "\n")
        if let icon { alert.icon = icon }
        alert.addButton(withTitle: acceptLabel.isEmpty ? "Add Extension" : acceptLabel)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    /// Rise's sheet before an extension is removed: Remove or Cancel.
    func showUninstallPrompt(title: String, icon: NSImage?, acceptLabel: String, answer: @escaping (Bool) -> Void) {
        guard let window else { answer(false); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Its settings and data in Rise go with it."
        if let icon { alert.icon = icon }
        let remove = alert.addButton(withTitle: acceptLabel.isEmpty ? "Remove" : acceptLabel)
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    static let webStoreHandler = "riseWebStore"
    /// An “Add to Rise” button by the extension's name on Web Store pages, which offer Chrome only,
    /// in place of the store's own Chrome button, its “Switch to Chrome” banner and its pop-up.
    func installWebStoreButton(on page: ChromiumPage) {
        page.addMessageHandler(Self.webStoreHandler, world: .named("Rise.WebStore")) { [weak self] message, reply in
            let origin = message.frame.origin.flatMap(URL.init(string:))
            guard let self, message.frame.isMain, origin?.scheme == "https", origin?.host == "chromewebstore.google.com",
                  let body = message.body as? [String: Any], let id = body["id"] as? String,
                  id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { reply(nil, "Not the Web Store"); return }
            if body["kind"] as? String == "add" { self.addFromWebStore(id) }
            reply(self.isExtensionInstalled(id), nil)
        }
        page.addUserScript(Self.webStoreScript, world: .named("Rise.WebStore"), mainFrameOnly: true, handlers: [Self.webStoreHandler])
    }
    func refreshWebStoreButtons() {
        for tab in tabs where Self.webStoreExtensionID(tab.url) != nil {
            tab.page.evaluate("window.riseWebStore?.refresh()", arguments: [:], in: nil, world: .named("Rise.WebStore")) { _ in }
        }
    }
    static let webStoreScript = """
    (() => {
      if (location.hostname !== 'chromewebstore.google.com') return;
      const send = body => riseHandlers.riseWebStore.postMessage(body);
      const idOf = () => (location.pathname.match(/^\\/detail\\/(?:[^/]+\\/)?([a-p]{32})(?:[/?#]|$)/) || [])[1];
      const button = document.createElement('button');
      button.type = 'button';
      button.style.cssText = 'display:inline-flex;align-items:center;height:40px;padding:0 24px;margin:16px 0 0;border:0;' +
        'border-radius:20px;background:#0b57d0;color:#fff;font:500 14px/20px "Google Sans",Roboto,system-ui,sans-serif;' +
        'letter-spacing:.1px;cursor:pointer;white-space:nowrap;flex:none;width:max-content;align-self:flex-start';
      let shown = null, installed = false;
      const draw = () => {
        button.textContent = installed ? 'Added to Rise' : 'Add to Rise';
        button.disabled = installed;
        button.style.opacity = installed ? '0.6' : '1';
        button.style.cursor = installed ? 'default' : 'pointer';
      };
      const check = async () => { installed = !!(await send({kind: 'state', id: shown}).catch(() => false)); draw(); };
      button.addEventListener('click', async () => {
        if (!shown || installed) return;
        installed = !!(await send({kind: 'add', id: shown}).catch(() => false)); draw();
      });
      // The store's Chrome offers, each hidden with what holds only offers (the banner's box with
      // its Install Chrome button), and its Switch to Chrome pop-up. The store's own button's place
      // stays, empty, so the store lays out the rest, Rise's button too, as it does with it.
      const offers = ['Add to Chrome', 'Remove from Chrome', 'Install Chrome', 'Try Chrome Enterprise Core',
                      'Switch to Chrome to install extensions and themes'];
      const onlyOffers = n => offers.reduce((t, offer) => t.split(offer).join(''), n.innerText || '').trim() === '';
      const wrapper = n => {
        while (n.parentElement && n.parentElement !== document.body && onlyOffers(n.parentElement)) n = n.parentElement;
        return n;
      };
      const hide = n => { n.dataset.riseHidden = ''; n.style.setProperty('display', 'none', 'important'); };
      const hideOffers = () => {
        for (const n of document.querySelectorAll('body *')) {
          if (n.childElementCount || n.closest('[data-rise-hidden], [data-rise-slot]')) continue;
          const own = n.textContent.trim();
          if (own === 'Add to Chrome' || own === 'Remove from Chrome') wrapper(n).dataset.riseSlot = '';
          else if (own === 'Switch to Chrome?') hide(n.closest('[role=dialog]') || n);
          else if (offers.includes(own)) hide(wrapper(n));
        }
        for (const slot of document.querySelectorAll('[data-rise-slot]')) {
          for (const child of slot.children) if (child !== button && !('riseHidden' in child.dataset)) hide(child);
        }
      };
      const place = () => {
        hideOffers();
        const id = idOf();
        const title = id && document.querySelector('main h1, h1');
        if (!title) { button.remove(); shown = null; return; }
        if (button.previousElementSibling !== title) title.after(button);
        if (shown !== id) { shown = id; installed = false; draw(); check(); }
      };
      let queued = false;
      new MutationObserver(() => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; place(); }, 100);
      }).observe(document, {childList: true, subtree: true});
      addEventListener('focus', () => shown && check());
      window.riseWebStore = {refresh: () => shown && check()};
      place();
    })();
    """
}

/// An extension's popup: its page, sized to what it shows (as Chrome does, from 25 by 25 to 800
/// by 600 points), in the tabs' hover card. Its right edge lines up with its button's, under it,
/// and it grows out of the button with the cards' motion once the page has loaded, as Chrome
/// shows its popups, and has drawn at its size.
@MainActor final class ExtensionPopup: NSObject {
    let page = ChromiumPage()
    let card = ExtensionPopupCard()
    var onClose: (() -> Void)?
    var onShown: ((Bool) -> Void)?
    private(set) var isShown = false
    /// The page's size, which the card takes as far as the window allows.
    private(set) var contentSize = NSSize.zero
    private(set) weak var anchor: NSView?
    /// Where the card must stay, in its host's coordinates, as an open Peek's card; the window's otherwise.
    var bounds: (() -> NSRect?)?
    /// `leaving` from the moment it's asked to close, so nothing opens it again on its way out.
    private var closed = false, leaving = false, loaded = false, sized = false, revealing = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    static let minimum = NSSize(width: 25, height: 25), maximum = NSSize(width: 800, height: 600)
    /// Below its button, and clear of the window's edges.
    static let gap: CGFloat = 6, margin: CGFloat = 8
    private static let handler = "riseExtensionPopupSize"

    /// Its page is made on the next turn, to load an extension's popup with `load`.
    override init() {
        super.init()
        page.browserView.extensionPopup = true
        page.view.frame = card.content.bounds
        page.view.autoresizingMask = [.width, .height]
        card.content.addSubview(page.view)
        // Sized as Chrome sizes popups, where the engine does; measured by the page, where not.
        if RCBrowserView.sizesExtensionPopups {
            page.onPreferredSize = { [weak self] size in self?.fit(size) }
        } else {
            page.addMessageHandler(Self.handler, world: .named("Rise.ExtensionPopup")) { [weak self] message in
                guard message.frame.isMain, let size = message.body as? [Double], size.count == 2 else { return }
                self?.fit(NSSize(width: size[0], height: size[1]))
            }
            page.addUserScript(Self.sizeScript, world: .named("Rise.ExtensionPopup"), mainFrameOnly: true, handlers: [Self.handler])
        }
        // `window.close()` from the popup, as many do when they're done.
        page.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .closed: close()
            case .finished: loaded = true; prepare()
            default: break
            }
        }
    }
    func apply(_ theme: RiseTheme) { card.apply(theme) }
    func load(_ url: URL) { page.load(url) }

    /// The card waits in its window out of sight, as big as a popup can be, where the page
    /// measures itself, and takes the page's size as soon as it has one. It opens under `anchor`
    /// once the page has loaded and drawn at that size, or after a second and a half regardless.
    func show(under anchor: NSView) {
        self.anchor = anchor
        card.frame = NSRect(origin: Self.outOfSight, size: Self.maximum)
        resized = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.asyncAfter(deadline: .now()+1.5) { [weak self] in self?.open() }
    }
    private static let outOfSight = NSPoint(x: -20000, y: 0)
    /// Where the engine sizes popups, the page has drawn at its size before the card hears it, so
    /// the card can open at once. Where the page measures itself, Chromium needs a frame or two to
    /// draw it again at the card's size, and shows only its background until then.
    private static let redraw = RCBrowserView.sizesExtensionPopups ? 0 : 0.035
    /// Where the card goes for the page's size: right-aligned under its button, as big as fits.
    private func frame(for size: NSSize) -> NSRect? {
        guard let anchor, let host = card.superview, anchor.window != nil, anchor.window === host.window else { return nil }
        let button = anchor.convert(anchor.bounds, to: host)
        let area = bounds?() ?? host.bounds
        let top = button.maxY+Self.gap
        let width = min(size.width, max(Self.minimum.width, button.maxX-area.minX-Self.margin))
        let height = min(size.height, max(Self.minimum.height, area.maxY-top-Self.margin))
        return NSRect(x: button.maxX-width, y: top, width: width, height: height)
    }
    /// The middle of the button's bottom edge, in the card's coordinates: where it grows from.
    private var growsFrom: CGPoint {
        guard let anchor, let host = card.superview else { return CGPoint(x: card.bounds.maxX, y: 0) }
        let button = anchor.convert(anchor.bounds, to: host)
        return CGPoint(x: button.midX-card.frame.minX, y: button.maxY-card.frame.minY)
    }
    private func fit(_ wanted: NSSize) {
        contentSize = NSSize(width: min(Self.maximum.width, max(Self.minimum.width, ceil(wanted.width))),
                             height: min(Self.maximum.height, max(Self.minimum.height, ceil(wanted.height))))
        sized = true
        if isShown { place() } else { resizeOutOfSight(); prepare() }
    }
    /// The page draws at the card's size while the card is still out of sight, and while it loads.
    private var resized = CFAbsoluteTimeGetCurrent()
    private func resizeOutOfSight() {
        guard !isShown, let frame = frame(for: contentSize), card.frame.size != frame.size else { return }
        card.frame = NSRect(origin: Self.outOfSight, size: frame.size)
        resized = CFAbsoluteTimeGetCurrent()
    }
    /// Once it has loaded and been measured, it opens as soon as it has had time to draw at its size.
    private func prepare() {
        guard !closed, !leaving, !isShown, !revealing, loaded, sized, frame(for: contentSize) != nil else { return }
        resizeOutOfSight()
        revealing = true
        let wait = Self.redraw-(CFAbsoluteTimeGetCurrent()-resized)
        if wait <= 0 { open(); return }
        DispatchQueue.main.asyncAfter(deadline: .now()+wait) { [weak self] in self?.open() }
    }
    private func place() {
        guard isShown, let frame = frame(for: contentSize), card.frame != frame else { return }
        card.frame = frame
        // A page that takes its size a moment after it loads, as many do: right-aligned, the card
        // grows to the left, and still comes out of its button.
        CardMotionAnimator.movePivotIn(card, CardMotion.selected, tab: growsFrom)
    }
    private func open() {
        guard !closed, !leaving, !isShown else { return }
        guard anchor?.window != nil, card.superview != nil else { finish(); return }
        if contentSize == .zero { contentSize = NSSize(width: 320, height: 400) }
        isShown = true
        place()
        card.isInteractive = true
        CardMotionAnimator.animateIn(card, CardMotion.selected, tab: growsFrom)
        card.window?.makeFirstResponder(page.view)
        watchForDismissal()
        AuthenticationDiagnostics.popups.notice("Popup presentation shown=true")
        reportShown(true)
    }
    /// As a transient popover: a click anywhere else, Escape, or leaving Rise closes it. A click on
    /// its own button only closes it, rather than opening it again.
    private func watchForDismissal() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.isShown else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53, event.window === self.card.window else { return event }
                self.close(); return nil
            }
            if event.window === self.card.window {
                if self.card.bounds.contains(self.card.convert(event.locationInWindow, from: nil)) { return event }
                if let anchor = self.anchor, anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                    self.close(); return nil
                }
            }
            self.close(); return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        if let window = card.window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
    }
    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }
    /// Goes with the cards' motion, back into its button.
    func close() {
        guard !closed, !leaving else { return }
        leaving = true
        guard isShown else { finish(); return }
        isShown = false; card.isInteractive = false
        stopWatching()
        // Rise has the keyboard back as the card goes, and lets go of the popup; the popup holds
        // itself until the card has gone, and goes even if the motion is cut short.
        onClose?(); onClose = nil
        let motion = CardMotion.selected
        CardMotionAnimator.animateOut(card, motion, tab: growsFrom) { self.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now()+max(motion.outDuration, motion.fadeOut)+0.25) { self.finish() }
    }
    private func finish() {
        guard !closed else { return }
        closed = true; isShown = false; card.isInteractive = false
        stopWatching()
        AuthenticationDiagnostics.popups.notice("Popup closed pendingResponse=\(self.onShown != nil)")
        card.removeFromSuperview()
        page.browserView.close()
        onClose?(); onClose = nil
        reportShown(false)
    }
    private func reportShown(_ shown: Bool) {
        let callback = onShown
        onShown = nil
        callback?(shown)
    }

    /// Measures the page's own size: its width as wide as its content wants, then its height.
    static let sizeScript = """
    (() => {
      let last = '', fixed = null;
      const measure = () => {
        const html = document.documentElement;
        if (!html || !document.body) return;
        // A page that sets its own width is narrower than the view, which starts as wide as a
        // popup can be; the rest are as wide as their content wants.
        if (fixed === null) fixed = html.getBoundingClientRect().width < innerWidth - 1;
        const width = html.style.width;
        if (!fixed) html.style.width = 'max-content';
        const wide = Math.min(800, Math.ceil(Math.max(html.getBoundingClientRect().width, fixed ? html.scrollWidth : 0)));
        if (!fixed) html.style.width = wide + 'px';
        const tall = Math.ceil(Math.max(html.getBoundingClientRect().height, document.body.getBoundingClientRect().bottom + scrollY));
        html.style.width = width;
        const size = wide + 'x' + tall;
        if (size === last) return;
        last = size;
        riseHandlers.riseExtensionPopupSize.postMessage([wide, tall]);
      };
      let queued = false;
      const soon = () => { if (!queued) { queued = true; setTimeout(() => { queued = false; measure(); }, 30); } };
      new MutationObserver(soon).observe(document, {childList: true, subtree: true, attributes: true, characterData: true});
      addEventListener('DOMContentLoaded', soon);
      addEventListener('load', soon);
      document.fonts?.ready.then(soon);
    })();
    """
}

/// The hover cards' surface around an extension's page: their fill, edge, shadow and corners.
@MainActor final class ExtensionPopupCard: FlippedView {
    private let panel = Surface(radius: FindBar.radius)
    /// The page's place, rounded as the card is.
    let content = FlippedView()
    var onPointer: ((Bool) -> Void)?
    /// Only once it has opened, and not while it goes.
    var isInteractive = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.12
        panel.layer?.shadowRadius = 10; panel.layer?.shadowOffset = NSSize(width: 0, height: -3)
        panel.clipsToBounds = false
        content.wantsLayer = true; content.layer?.cornerRadius = FindBar.radius
        content.layer?.cornerCurve = .continuous; content.layer?.masksToBounds = true
        panel.addSubview(content); addSubview(panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    private(set) var fill = NSColor.clear
    func apply(_ theme: RiseTheme) {
        appearance = theme.appearance
        fill = theme == .dark ? theme.popup : TabAppearance.selectedFill(theme)
        panel.fill = fill
        KeroLitEdge.apply(to: panel, theme: theme)
    }
    override func layout() {
        super.layout()
        panel.frame = bounds; content.frame = bounds
        panel.layer?.shadowPath = PageOutline.path(in: bounds, radius: FindBar.radius, continuous: true)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? super.hitTest(point) : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if isInteractive { onPointer?(true) } }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
}
