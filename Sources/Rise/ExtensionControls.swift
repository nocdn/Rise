import AppKit
#if RISE_CHROMIUM
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
    /// `anchor` (in the sidebar), or the site controls button.
    func runExtension(_ id: String, anchor: NSView? = nil) {
        guard let tab = selectedChromiumView, let action = extensionActions.first(where: { $0.extensionID == id }) else { return }
        siteControlsPopover.close()
        guard let url = action.click(inTab: tab) else { return }
        let anchorView = sidebar.address
        let rect = anchor.map { anchorView.convert($0.bounds, from: $0) } ?? sidebar.settingsAnchorRect
        extensionPopup?.close()
        let popup = ExtensionPopup(url: url, theme: theme)
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

    static let webStoreHandler = "riseWebStore"
    /// An “Add to Rise” button by the extension's name on Web Store pages, which offer Chrome only.
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
      const place = () => {
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
        page.addMessageHandler(Self.handler, world: .named("Rise.ExtensionPopup")) { [weak self] message in
            guard message.frame.isMain, let size = message.body as? [Double], size.count == 2 else { return }
            self?.fit(NSSize(width: size[0], height: size[1]))
        }
        page.addUserScript(Self.sizeScript, world: .named("Rise.ExtensionPopup"), mainFrameOnly: true, handlers: [Self.handler])
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
        guard !closed, !popover.isShown, let anchor, anchor.view.window != nil else { return }
        popover.contentSize = size ?? NSSize(width: 320, height: 400)
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(page.view)
    }
    func close() {
        guard !closed else { return }
        if popover.isShown { popover.performClose(nil) } else { finish() }
    }
    func popoverDidClose(_ notification: Notification) { finish() }
    private func finish() {
        guard !closed else { return }
        closed = true
        page.browserView.close()
        onClose?()
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
#endif
