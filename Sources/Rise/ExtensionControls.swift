import AppKit
import RiseChromium

/// Chrome extensions in Rise's chrome, as Arc has them: pinned ones in the sidebar's address row,
/// every one in the site controls popover (where they're pinned and unpinned), and their popups in
/// popovers under the button that opened them.
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
    var extensionActions: [RCExtensionAction] { (extensionWindow as? ExtensionWindow)?.actions ?? [] }
    /// The page extensions act on: the selected tab's, when it's Chromium's.
    var selectedChromiumView: RCBrowserView? { (selectedTab?.page as? ChromiumPage)?.browserView }

    /// Clicks extension `id`'s button for the selected tab; its popup, if any, opens under
    /// `anchor` (in the page bar), or the site controls button.
    func runExtension(_ id: String, anchor: NSView? = nil) {
        guard let tab = selectedChromiumView, let action = extensionActions.first(where: { $0.extensionID == id }) else { return }
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
        let anchorView: NSView = anchor ?? navBar.settingsButton
        guard anchorView.window != nil else {
            AuthenticationDiagnostics.popups.notice("Popup refused missingWindow=1")
            completion?(false); return
        }
        let rect = anchorView.bounds
        extensionPopup?.close()
        let popup = ExtensionPopup(url: url, theme: theme)
        popup.onShown = completion
        popup.onClose = { [weak self, weak popup] in if self?.extensionPopup === popup { self?.extensionPopup = nil } }
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
        popup.show(relativeTo: rect, of: anchorView)
    }
    /// An extension's keyboard shortcut: its button's opens its popup, under its page bar button if
    /// it's pinned, as a click does; others go to the extension. False if `event` isn't one.
    func runExtensionShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = RCExtensions.shortcut(for: event) else { return false }
        if shortcut.clicksButton {
            runExtension(shortcut.extensionID, anchor: navBar.extensionButtons.first { $0.extensionID == shortcut.extensionID })
        } else {
            shortcut.run(inTab: selectedChromiumView)
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
/// by 600 points), in a popover that opens once the page knows its size.
@MainActor final class ExtensionPopup: NSObject, NSPopoverDelegate {
    let page = ChromiumPage()
    let popover = NSPopover()
    var onClose: (() -> Void)?
    var onShown: ((Bool) -> Void)?
    private var anchor: (rect: NSRect, view: NSView)?
    private var closed = false
    static let minimum = NSSize(width: 25, height: 25), maximum = NSSize(width: 800, height: 600)
    private static let handler = "riseExtensionPopupSize"

    init(url: URL, theme: RiseTheme) {
        super.init()
        page.browserView.extensionPopup = true
        popover.behavior = .transient
        popover.appearance = theme.appearance
        popover.delegate = self
        let content = PopoverContentView(frame: NSRect(origin: .zero, size: Self.maximum))
        page.view.frame = content.bounds
        page.view.autoresizingMask = [.width, .height]
        content.addSubview(page.view)
        let controller = NSViewController(); controller.view = content
        popover.contentViewController = controller
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
        page.onEvent = { [weak self] event in if case .closed = event { self?.close() } }
        page.load(url)
    }

    /// Opens under `rect` of `view` once the page has measured itself, or after a second regardless.
    func show(relativeTo rect: NSRect, of view: NSView) {
        anchor = (rect, view)
        DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in self?.open(size: nil) }
    }
    private func fit(_ wanted: NSSize) {
        let size = NSSize(width: min(Self.maximum.width, max(Self.minimum.width, ceil(wanted.width))),
                          height: min(Self.maximum.height, max(Self.minimum.height, ceil(wanted.height))))
        if popover.isShown {
            if popover.contentSize != size { popover.contentSize = size }
        } else { open(size: size) }
    }
    private func open(size: NSSize?) {
        guard !closed, !popover.isShown else { return }
        guard let anchor else { return }
        guard anchor.view.window != nil else { finish(); return }
        popover.contentSize = size ?? NSSize(width: 320, height: 400)
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(page.view)
        AuthenticationDiagnostics.popups.notice("Popup presentation shown=\(self.popover.isShown)")
        reportShown(popover.isShown)
    }
    func close() {
        guard !closed else { return }
        if popover.isShown { popover.performClose(nil) } else { finish() }
    }
    func popoverDidClose(_ notification: Notification) { finish() }
    private func finish() {
        guard !closed else { return }
        closed = true
        AuthenticationDiagnostics.popups.notice("Popup closed pendingResponse=\(self.onShown != nil)")
        page.browserView.close()
        onClose?()
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
