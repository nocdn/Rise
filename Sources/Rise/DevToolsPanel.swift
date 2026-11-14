import AppKit
import RiseChromium

/// Chromium's DevTools for the selected tab, docked at the window's right edge. Opening, it
/// springs in from the edge as the page makes room beside it, as the docked sidebar does from
/// the left; closing, it slides back off the same way as the page widens after it.
@MainActor final class DevToolsPanel {
    /// 0 off past the window's right edge, 1 docked beside the page.
    fileprivate var slide = MotionSpring(0)
    fileprivate var link: CADisplayLink?
    fileprivate var lastTick: CFTimeInterval?
    let shadow = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let clip = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    /// The split's handle, in the gap between the page and DevTools: dragged, it resizes them.
    let handle = SplitHandle()
    /// The width the handle was last dragged to, kept across launches; nil for the default.
    var chosenWidth: CGFloat?
    static let widthKey = "Rise.DevToolsWidth"
    static let animatesKey = "Rise.AnimateDevTools"
    /// The tab whose DevTools show, and the view showing them.
    fileprivate(set) var tabID: UUID?
    fileprivate var frontend: NSView?
    fileprivate var close: (() -> Void)?
    /// What DevTools ask of Rise: their menus, closing from their own close button, their
    /// toolbox, where to lay out the page, and their downloads and file choosers.
    fileprivate let events = DevToolsEvents()
    /// DevTools' toolbox, a page of theirs Rise shows in the inspected page's place, under it, as
    /// Chrome does: their device mode's toolbar and rulers, around the page.
    fileprivate(set) var toolbox: RCBrowserView?
    /// Where DevTools last laid out the page in their toolbox, from its top left: at the origin
    /// it fills it, and otherwise device mode has it on its screen.
    fileprivate(set) var inspectedBounds: NSRect?
    /// The panel the DevTools show ("elements", "console", "network"…), as they tell it, or as
    /// asked of them until they do.
    fileprivate(set) var shownPanel: String?
    /// Showing `tool` in the selected tab: its shortcut puts them away.
    func shows(_ tool: DevToolsTool, in tabID: UUID?) -> Bool { isOpen && tabID != nil && self.tabID == tabID && shownPanel == tool.rawValue }
    /// Device mode is on: the page is on its screen, in DevTools' toolbox.
    var isInDeviceMode: Bool { toolbox != nil && (inspectedBounds.map { $0.minX > 0.5 || $0.minY > 0.5 } ?? false) }
    var isOpen: Bool { slide.target > 0 }
    var progress: CGFloat { CGFloat(slide.value) }
    init() {
        shadow.layer?.cornerCurve = .continuous; clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true; clip.clipsToBounds = true
        shadow.addSubview(clip)
        shadow.isHidden = true
        handle.isHidden = true
    }
    /// Narrower and DevTools stop being usable; the page keeps as much beside them.
    static let minimumWidth: CGFloat = 320, minimumPageWidth: CGFloat = 360
    /// About a third of the window, within reason, or as dragged, leaving the
    /// page `room` of the window's width to keep some for itself.
    func width(in bounds: NSRect, room: CGFloat) -> CGFloat {
        let standard = min(600, max(Self.minimumWidth, (bounds.width*0.32).rounded()))
        let widest = max(Self.minimumWidth, room-Self.minimumPageWidth-PageAppearance.inset)
        return min(max(chosenWidth ?? standard, Self.minimumWidth), widest)
    }
    /// Turns off the size DevTools paint on the page as it's resized, for every page they inspect.
    /// DevTools turn it back on themselves, so it's held off where they set it.
    static let quietResizes = """
    const quiet = async () => {
      const SDK = await import('./core/sdk/sdk.js');
      const Model = SDK.OverlayModel.OverlayModel, set = Model.prototype.setShowViewportSizeOnResize;
      Model.prototype.setShowViewportSizeOnResize = function () { set.call(this, false); };
      SDK.TargetManager.TargetManager.instance().observeModels(Model, {modelAdded: model => model.setShowViewportSizeOnResize(false), modelRemoved() {}});
    };
    if (document.readyState === 'complete') quiet(); else addEventListener('load', quiet);
    """
    /// The panel DevTools show, told to Rise as it changes (`shownPanel`), and
    /// `riseDevTools.show(panel)` to change it: Elements picking an element in the page, as ⌘⇧C
    /// has them, and anywhere else not; `riseDevTools.toggle(panel)` says "shown" instead where
    /// it shows already. `opening` shows first, once DevTools are ready.
    static func panels(opening: DevToolsTool?) -> String {
        """
        (() => {
          const ready = (async () => {
            for (let tries = 0; tries < 150; tries++) {
              try {
                const [UI, SDK] = await Promise.all([import('./ui/legacy/legacy.js'), import('./core/sdk/sdk.js')]);
                const inspector = UI.InspectorView.InspectorView.maybeGetInspectorViewInstance();
                const registry = UI.ActionRegistry.ActionRegistry.instance();
                if (inspector && registry.hasAction('elements.toggle-element-search') && SDK.TargetManager.TargetManager.instance().primaryPageTarget())
                  return {UI, inspector, registry};
              } catch {}
              await new Promise(resolve => setTimeout(resolve, 100));
            }
            return null;
          })();
          const show = async panel => {
            const found = await ready;
            if (!found) return false;
            const search = found.registry.getAction('elements.toggle-element-search');
            await found.UI.ViewManager.ViewManager.instance().showView(panel);
            if ((panel === 'elements') !== search.toggled()) await search.execute();
            return true;
          };
          // Showing `panel` already, says so for Rise to put them away; otherwise shows it.
          const toggle = async panel => {
            const found = await ready;
            if (!found) return 'missing';
            if (found.inspector.tabbedPane.selectedTabId === panel) return 'shown';
            await show(panel);
            return 'switched';
          };
          globalThis.riseDevTools = {show, toggle};
          const report = panel => { try { riseHandlers.\(handler).postMessage(panel ?? ''); } catch {} };
          (async () => {
            const found = await ready;
            if (!found) return;
            const opening = \(opening.map { "'\($0.rawValue)'" } ?? "null");
            if (opening) await show(opening);
            const pane = found.inspector.tabbedPane;
            pane.addEventListener('TabSelected', event => report(event.data.tabId));
            report(pane.selectedTabId);
          })();
        })();
        """
    }
    static let handler = "riseDevToolsPanel"
    /// Rise's DevTools are undocked, filling their panel (docked, they keep room beside themselves
    /// for a page Chrome lays under them), but can dock, which gives them device mode. Undocked,
    /// they'd hide their close button and offer places to dock in their menu: they keep the
    /// button, as Chrome's docked DevTools have it, and stay where Rise shows them.
    static let undocked = """
    import('./ui/legacy/legacy.js').then(UI => {
      const Dock = UI.DockController.DockController, set = Dock.prototype.setDockSide;
      Dock.prototype.setDockSide = function (side) { set.call(this, side); this.closeButton.setVisible(true); };
      Dock.prototype.canDock = () => false;
      Dock.prototype.toggleDockSide = () => {};
    });
    """
    /// The springs the docked sidebar opens and collapses with.
    fileprivate func configureOpen() { slide.configure(response: 0.185, bounce: 0.2) }
    fileprivate func configureCollapse() { slide.configure(response: 0.17, bounce: 0.15) }
}

/// What ⌥⌘J and ⌥⌘K open DevTools to.
enum DevToolsTool: String {
    /// The Elements panel, picking an element in the page.
    case elements
    case console
}

@MainActor extension BrowserController {
    /// DevTools slide in and out unless turned off in the site controls' More menu.
    var animatesDevTools: Bool { preferences.object(forKey: DevToolsPanel.animatesKey) as? Bool ?? true }
    func setAnimatesDevTools(_ value: Bool) { preferences.set(value, forKey: DevToolsPanel.animatesKey) }

    func installDevTools() {
        let panel = devTools
        panel.events.onContextMenu = { [weak self] menu, view in self?.showDevToolsMenu(menu, in: view) }
        panel.events.onPanel = { [weak self] view, name in
            guard let self, view === self.devTools.frontend else { return }
            self.devTools.shownPanel = name.isEmpty ? nil : name
        }
        panel.events.onClose = { [weak self] view in
            guard let self, view === self.devTools.frontend else { return }
            self.closeDevTools()
        }
        panel.events.onPopup = { [weak self] opener, popup, url in
            guard let self, opener === self.devTools.frontend, url.lastPathComponent == "device_mode_emulation_frame.html" else { return false }
            self.adoptDevToolsToolbox(popup)
            return true
        }
        panel.events.onInspectedBounds = { [weak self] view, bounds in
            guard let self, view === self.devTools.frontend, self.devTools.inspectedBounds != bounds else { return }
            self.devTools.inspectedBounds = bounds
            self.layoutDevToolsMotion()
        }
        // Their screenshots and saved files go where a page's downloads do, and they choose files
        // as a page does.
        panel.events.onDownload = { [weak self] download, name in self?.beginChromiumDownload(download, suggestedName: name) }
        panel.events.onChooseFiles = { [weak self] mode, path, finish in
            guard let self else { finish(nil); return }
            self.chooseFiles(mode, defaultPath: path, finish: finish)
        }
        root.addSubview(panel.shadow, positioned: .above, relativeTo: pageShadow)
        root.addSubview(panel.handle, positioned: .above, relativeTo: panel.shadow)
        panel.shadow.shadow = chromeShadow(opacity: PageAppearance.shadowOpacity, blur: PageAppearance.shadowBlur, offset: PageAppearance.shadowOffset)
        if let width = preferences.object(forKey: DevToolsPanel.widthKey) as? Double { panel.chosenWidth = CGFloat(width) }
        // Dragged, as the split is: left widens DevTools, right gives the page room back.
        var start: CGFloat?
        panel.handle.onDrag = { [weak self] distance in
            guard let self else { return }
            let from = start ?? panel.shadow.frame.width; start = from
            panel.chosenWidth = max(DevToolsPanel.minimumWidth, from-distance)
            self.layoutDevToolsMotion()
        }
        panel.handle.onDragEnd = { [weak self] in
            start = nil
            // Kept as shown, inside the limits of the window it was dragged in.
            panel.chosenWidth = panel.shadow.frame.width
            self?.preferences.set(Double(panel.shadow.frame.width), forKey: DevToolsPanel.widthKey)
        }
        // A double click, as on the split, goes back to the standard width.
        panel.handle.onReset = { [weak self] in
            panel.chosenWidth = nil
            self?.preferences.removeObject(forKey: DevToolsPanel.widthKey)
            self?.layoutDevToolsMotion()
        }
    }

    /// ⌘,: Chrome's settings, as rise://settings, in the tab already showing them or a new one.
    @objc func showSettings() {
        if let tab = tabs.first(where: { $0.page.url?.scheme == "rise" && $0.page.url?.host == "settings" }) { select(tab.id); return }
        addTab(url: RisePages.settings)
    }

    /// ⌥⌘J: the selected tab's DevTools, on Elements picking an element; on Elements already,
    /// puts them away.
    @objc func toggleDevTools() { switchDevTools(to: .elements) }
    /// ⌥⌘K: the selected tab's DevTools, on the console; on the console already, puts them away.
    @objc func toggleDevToolsConsole() { switchDevTools(to: .console) }
    /// Opens the DevTools to `tool`, switches them to it from another panel, or, showing it
    /// already, closes them.
    func switchDevTools(to tool: DevToolsTool) {
        guard let tab = selectedTab else { return }
        let panel = devTools
        guard let page = tab.page as? ChromiumPage else { if panel.isOpen, panel.tabID == tab.id { closeDevTools() } else { NSSound.beep() }; return }
        if panel.isOpen, panel.tabID == tab.id, let frontend = panel.frontend as? RCBrowserView {
            // DevTools know best which panel they show, whatever was clicked in them since.
            frontend.evaluateFunctionBody("return await globalThis.riseDevTools?.toggle(panel) ?? 'missing';", arguments: ["panel": tool.rawValue],
                                          frame: nil, world: nil) { [weak self, weak frontend] result, _ in
                guard let self, let frontend, self.devTools.frontend === frontend, self.devTools.isOpen else { return }
                switch result as? String {
                case "switched": self.devTools.shownPanel = tool.rawValue
                case "shown": self.closeDevTools()
                // Not ready to say, as Rise last heard.
                default: if self.devTools.shownPanel == tool.rawValue { self.closeDevTools() }
                }
            }
            window?.makeFirstResponder(frontend)
            return
        }
        if panel.tabID != tab.id || panel.frontend == nil { showDevTools(for: tab, page: page, opening: tool) }
        // Opened again before they'd gone.
        else if let frontend = panel.frontend as? RCBrowserView {
            frontend.evaluateFunctionBody("return await globalThis.riseDevTools?.show(panel) ?? false;", arguments: ["panel": tool.rawValue],
                                          frame: nil, world: nil) { _, _ in }
            panel.shownPanel = tool.rawValue
        }
        openDevTools()
    }
    private func openDevTools() {
        let panel = devTools
        panel.configureOpen(); panel.slide.target = 1
        animateDevTools()
        if let frontend = panel.frontend { window?.makeFirstResponder(frontend) }
    }
    /// "Inspect Element": the page's DevTools, open on the element right-clicked.
    func inspectElement(_ info: RCContextMenu, in page: ChromiumPage) {
        guard let tab = tabs.first(where: { $0.page === page }) else { return }
        if tab.id != selectedID { select(tab.id) }
        let panel = devTools
        if panel.tabID != tab.id || panel.frontend == nil { showDevTools(for: tab, page: page, opening: nil) }
        info.inspect()
        openDevTools()
    }
    func closeDevTools() {
        let panel = devTools
        guard panel.isOpen else { return }
        panel.configureCollapse(); panel.slide.target = 0
        if let frontend = panel.frontend, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: frontend),
           let page = selectedTab?.page.view {
            window?.makeFirstResponder(page)
        }
        animateDevTools()
    }

    /// DevTools for `tab`, on `opening` once they're ready, or as they open (Elements).
    private func showDevTools(for tab: BrowserTab, page: ChromiumPage, opening: DevToolsTool?) {
        let panel = devTools
        tearDownDevTools()
        let frontend = page.browserView.makeDevTools()
        // DevTools follows Rise's light or dark, as pages do.
        frontend.prefersDark = NSNumber(value: theme == .dark)
        frontend.pageBackgroundColor = theme.page
        // DevTools paint the page's size on it as it's resized, which Rise's slide does on every frame.
        frontend.addUserScript(DevToolsPanel.quietResizes, world: nil, mainFrameOnly: true, handlers: [])
        frontend.addUserScript(DevToolsPanel.undocked, world: nil, mainFrameOnly: true, handlers: [])
        frontend.delegate = panel.events
        // They open ready to pick an element in the page, or on the console, unless an element
        // was picked to open them; and say which panel they show from then on.
        frontend.addMessageHandler(DevToolsPanel.handler, world: nil, replies: false)
        frontend.addUserScript(DevToolsPanel.panels(opening: opening), world: nil, mainFrameOnly: true, handlers: [DevToolsPanel.handler])
        frontend.frame = panel.clip.bounds
        panel.clip.addSubview(frontend)
        panel.tabID = tab.id; panel.frontend = frontend; panel.shownPanel = opening?.rawValue ?? DevToolsTool.elements.rawValue
        panel.close = { [weak frontend] in frontend?.close() }
    }
    /// A menu DevTools show: the » past their tabs, a toolbar's menu, a node's or a request's
    /// right-click. They give its entries, as they do Chrome, and hear which was chosen.
    private func showDevToolsMenu(_ info: RCContextMenu, in view: RCBrowserView) {
        defer { DispatchQueue.main.async { info.closed() } }
        guard view.window != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        info.customItems.map(extensionMenuItem).forEach(menu.addItem)
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = menuItem(title, action: action); item.isEnabled = enabled
            menu.addItem(item)
        }
        func group() { if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) } }
        // A text field's, or the selection's, as after DevTools' own entries in Chrome.
        if info.editable {
            group()
            add("Cut", enabled: info.editFlags.contains(.canCut)) { info.perform(.cut) }
            add("Copy", enabled: info.editFlags.contains(.canCopy)) { info.perform(.copy) }
            add("Paste", enabled: info.editFlags.contains(.canPaste)) { info.perform(.paste) }
            add("Select All", enabled: info.editFlags.contains(.canSelectAll)) { info.perform(.selectAll) }
        } else if !info.selectionText.isEmpty {
            group()
            add("Copy") { info.perform(.copy) }
        }
        guard !menu.items.isEmpty else { return }
        let point = NSPoint(x: info.point.x, y: view.isFlipped ? info.point.y : view.bounds.height-info.point.y)
        presentContextMenu(menu, point, view)
    }

    /// DevTools' toolbox, opened as they start: under the page, in its place.
    private func adoptDevToolsToolbox(_ toolbox: RCBrowserView) {
        let panel = devTools
        panel.toolbox?.delegate = nil; panel.toolbox?.close(); panel.toolbox?.removeFromSuperview()
        toolbox.delegate = panel.events
        toolbox.prefersDark = NSNumber(value: theme == .dark)
        toolbox.pageBackgroundColor = theme.page
        toolbox.isHidden = true
        panel.toolbox = toolbox; panel.inspectedBounds = nil
        layoutDevToolsMotion()
    }

    /// DevTools' toolbox in the selected page's place, `body`, under it, while their tab's
    /// DevTools show; in device mode, the page on the screen they lay out for it there.
    func layoutDevToolsToolbox(body: NSRect?) {
        let panel = devTools
        guard let toolbox = panel.toolbox else { return }
        guard let body, panel.tabID == selectedID, panel.progress > 0, let tab = selectedTab,
              !pictureInPicture.owns(tab), !tab.isInNativeFullscreen, let container = tab.page.view.superview else {
            toolbox.isHidden = true; return
        }
        let page = tab.page.view
        if toolbox.superview !== container || container.subviews.firstIndex(of: toolbox) != container.subviews.firstIndex(of: page).map({ $0-1 }) {
            container.addSubview(toolbox, positioned: .below, relativeTo: page)
        }
        toolbox.frame = body; toolbox.isHidden = false
        if toolbox.prefersDark?.boolValue != (theme == .dark) { toolbox.prefersDark = NSNumber(value: theme == .dark) }
        guard panel.isInDeviceMode, let screen = panel.inspectedBounds else { return }
        page.frame = NSRect(x: body.minX+screen.minX, y: container.isFlipped ? body.minY+screen.minY : body.maxY-screen.maxY,
                            width: screen.width, height: screen.height)
    }

    /// Lets the DevTools go: their tab closed, or they slid away.
    private func tearDownDevTools() {
        let panel = devTools
        (panel.frontend as? RCBrowserView)?.delegate = nil
        panel.toolbox?.delegate = nil; panel.toolbox?.close(); panel.toolbox?.removeFromSuperview()
        panel.toolbox = nil; panel.inspectedBounds = nil
        panel.close?(); panel.frontend?.removeFromSuperview()
        panel.frontend = nil; panel.close = nil; panel.tabID = nil; panel.shownPanel = nil
    }

    /// Places the DevTools in `bounds`, and returns how much of the window's right side they take
    /// from the page.
    func layoutDevTools(in bounds: NSRect, pageLeft: CGFloat) -> CGFloat {
        let panel = devTools
        // DevTools go with their tab: away from it they're out of sight, and they're let go with it.
        if let id = panel.tabID, !tabs.contains(where: { $0.id == id }) {
            panel.link?.invalidate(); panel.link = nil
            panel.slide.target = 0; panel.slide.settle(); tearDownDevTools()
        }
        let shown = panel.tabID != nil && panel.tabID == selectedID
        let progress = shown ? panel.progress : 0
        panel.shadow.isHidden = progress <= 0
        guard progress > 0 else { panel.handle.isHidden = true; return 0 }
        let inset = PageAppearance.inset, width = panel.width(in: bounds, room: bounds.width-pageLeft-inset)
        // Never further out than the window's edge, nor the page past its own.
        let room = width+inset
        let docked = NSRect(x: bounds.maxX-inset-width, y: bounds.minY+inset, width: width, height: max(0, bounds.height-2*inset))
        panel.shadow.frame = docked.offsetBy(dx: room*(1-progress), dy: 0)
        panel.shadow.fill = theme.page; panel.clip.fill = theme.page
        if let frontend = panel.frontend as? RCBrowserView, frontend.prefersDark?.boolValue != (theme == .dark) {
            frontend.prefersDark = NSNumber(value: theme == .dark)
        }
        panel.shadow.refreshOutline()
        panel.clip.frame = panel.shadow.bounds
        panel.frontend?.frame = panel.clip.bounds
        // In the gap between the page and DevTools, moving with them.
        panel.handle.frame = NSRect(x: panel.shadow.frame.minX-inset, y: panel.shadow.frame.minY, width: inset, height: panel.shadow.frame.height)
        if panel.handle.isHidden { panel.handle.isHidden = false; panel.handle.refreshHover() }
        return max(0, room*progress)
    }

    private func animateDevTools() {
        let panel = devTools
        guard window?.isVisible == true, animatesDevTools, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.link?.invalidate(); panel.link = nil
            panel.slide.settle(); finishDevToolsMotion(); return
        }
        guard panel.link == nil else { return }
        panel.lastTick = CACurrentMediaTime()
        let link = root.displayLink(target: self, selector: #selector(tickDevTools(_:)))
        link.add(to: .main, forMode: .common); panel.link = link
        layoutDevToolsMotion()
    }
    @objc private func tickDevTools(_ link: CADisplayLink) {
        let panel = devTools
        let now = CACurrentMediaTime(), dt = min(0.05, now-(panel.lastTick ?? now)); panel.lastTick = now
        panel.slide.step(dt)
        if panel.slide.isResting(within: 0.001) {
            panel.slide.settle(); link.invalidate(); panel.link = nil
            finishDevToolsMotion(); return
        }
        layoutDevToolsMotion()
    }
    /// Closed, the DevTools stop inspecting the page.
    private func finishDevToolsMotion() {
        if !devTools.isOpen { tearDownDevTools() }
        layoutDevToolsMotion()
    }
    fileprivate func layoutDevToolsMotion() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChrome(); root.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
}

/// The DevTools page's delegate: what it asks of Rise.
@MainActor final class DevToolsEvents: NSObject, RCBrowserViewDelegate {
    var onContextMenu: ((RCContextMenu, RCBrowserView) -> Void)?
    var onClose: ((RCBrowserView) -> Void)?
    /// The panel they show, as they change it.
    var onPanel: ((RCBrowserView, String) -> Void)?
    var onPopup: ((_ opener: RCBrowserView, _ popup: RCBrowserView, URL) -> Bool)?
    var onInspectedBounds: ((RCBrowserView, NSRect) -> Void)?
    var onDownload: ((RCDownload, _ suggestedName: String) -> URL?)?
    var onChooseFiles: ((RCFileChooserMode, _ defaultPath: String, _ finish: @escaping ([URL]?) -> Void) -> Void)?
    /// Their toolbox, opened as they start.
    nonisolated func browserView(_ browserView: RCBrowserView, adoptPopup popup: RCBrowserView, url: URL, userGesture: Bool) -> Bool {
        MainActor.assumeIsolated { onPopup?(browserView, popup, url) ?? false }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, setInspectedPageBounds bounds: NSRect) {
        MainActor.assumeIsolated { onInspectedBounds?(browserView, bounds) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, destinationFor download: RCDownload, suggestedName: String) -> URL? {
        MainActor.assumeIsolated { onDownload?(download, suggestedName) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, chooseFiles mode: RCFileChooserMode, title: String, defaultPath: String,
                                 extensions: [String], completion: @escaping ([URL]?) -> Void) {
        MainActor.assumeIsolated {
            guard let onChooseFiles else { completion(nil); return }
            onChooseFiles(mode, defaultPath, completion)
        }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, didReceiveMessage body: Any, handler: String, frame: RCFrame,
                                 reply: ((Any?, String?) -> Void)?) {
        MainActor.assumeIsolated {
            if handler == DevToolsPanel.handler, let name = body as? String { onPanel?(browserView, name) }
            reply?(nil, nil)
        }
    }
    nonisolated func browserViewDidChange(_ browserView: RCBrowserView) {}
    nonisolated func browserView(_ browserView: RCBrowserView, showContextMenu menu: RCContextMenu) {
        MainActor.assumeIsolated { onContextMenu?(menu, browserView) }
    }
    /// Their close button.
    nonisolated func browserViewDidRequestClose(_ browserView: RCBrowserView) {
        MainActor.assumeIsolated { onClose?(browserView) }
    }
}
