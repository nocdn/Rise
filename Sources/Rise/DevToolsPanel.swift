import AppKit
#if RISE_CHROMIUM
import RiseChromium
#endif

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
    /// Turns on "Select an element", as ⌘⇧C does, once DevTools are ready, unless it's on already.
    static let pickElement = """
    const pick = async () => {
      for (let tries = 0; tries < 150; tries++) {
        try {
          const [UI, SDK] = await Promise.all([import('./ui/legacy/legacy.js'), import('./core/sdk/sdk.js')]);
          const registry = UI.ActionRegistry.ActionRegistry.instance(), id = 'elements.toggle-element-search';
          if (registry.hasAction(id) && SDK.TargetManager.TargetManager.instance().primaryPageTarget()) {
            const action = registry.getAction(id);
            if (!action.toggled()) await action.execute();
            return action.toggled();
          }
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      return false;
    };
    """
    /// The springs the docked sidebar opens and collapses with.
    fileprivate func configureOpen() { slide.configure(response: 0.185, bounce: 0.2) }
    fileprivate func configureCollapse() { slide.configure(response: 0.17, bounce: 0.15) }
}

@MainActor extension BrowserController {
    /// DevTools slide in and out unless turned off in the site controls' More menu.
    var animatesDevTools: Bool { preferences.object(forKey: DevToolsPanel.animatesKey) as? Bool ?? true }
    func setAnimatesDevTools(_ value: Bool) { preferences.set(value, forKey: DevToolsPanel.animatesKey) }

    func installDevTools() {
        let panel = devTools
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

    /// ⌥⌘J: opens the selected tab's DevTools, or closes them.
    @objc func toggleDevTools() {
        guard let tab = selectedTab else { return }
        let panel = devTools
        if panel.isOpen, panel.tabID == tab.id { closeDevTools(); return }
        #if RISE_CHROMIUM
        guard let page = tab.page as? ChromiumPage else { NSSound.beep(); return }
        if panel.tabID != tab.id || panel.frontend == nil { showDevTools(for: tab, page: page, picking: true) }
        // Opened again before they'd gone, they're ready to pick an element again too.
        else if let frontend = panel.frontend as? RCBrowserView {
            frontend.evaluateFunctionBody(DevToolsPanel.pickElement + "return await pick();", arguments: [:], frame: nil, world: nil) { _, _ in }
        }
        openDevTools()
        #else
        NSSound.beep()
        #endif
    }
    private func openDevTools() {
        let panel = devTools
        panel.configureOpen(); panel.slide.target = 1
        animateDevTools()
        if let frontend = panel.frontend { window?.makeFirstResponder(frontend) }
    }
    #if RISE_CHROMIUM
    /// "Inspect Element": the page's DevTools, open on the element right-clicked.
    func inspectElement(_ info: RCContextMenu, in page: ChromiumPage) {
        guard let tab = tabs.first(where: { $0.page === page }) else { return }
        if tab.id != selectedID { select(tab.id) }
        let panel = devTools
        if panel.tabID != tab.id || panel.frontend == nil { showDevTools(for: tab, page: page, picking: false) }
        info.inspect()
        openDevTools()
    }
    #endif
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

    #if RISE_CHROMIUM
    private func showDevTools(for tab: BrowserTab, page: ChromiumPage, picking: Bool) {
        let panel = devTools
        tearDownDevTools()
        let frontend = page.browserView.makeDevTools()
        // DevTools follows Rise's light or dark, as pages do.
        frontend.prefersDark = NSNumber(value: theme == .dark)
        frontend.pageBackgroundColor = theme.page
        // DevTools paint the page's size on it as it's resized, which Rise's slide does on every frame.
        frontend.addUserScript(DevToolsPanel.quietResizes, world: nil, mainFrameOnly: true, handlers: [])
        // They open ready to pick an element in the page, unless one was picked to open them.
        if picking {
            frontend.addUserScript(DevToolsPanel.pickElement + "if (document.readyState === 'complete') pick(); else addEventListener('load', pick);",
                                   world: nil, mainFrameOnly: true, handlers: [])
        }
        frontend.frame = panel.clip.bounds
        panel.clip.addSubview(frontend)
        panel.tabID = tab.id; panel.frontend = frontend
        panel.close = { [weak frontend] in frontend?.close() }
    }
    #endif
    /// Lets the DevTools go: their tab closed, or they slid away.
    private func tearDownDevTools() {
        let panel = devTools
        panel.close?(); panel.frontend?.removeFromSuperview()
        panel.frontend = nil; panel.close = nil; panel.tabID = nil
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
        #if RISE_CHROMIUM
        if let frontend = panel.frontend as? RCBrowserView, frontend.prefersDark?.boolValue != (theme == .dark) {
            frontend.prefersDark = NSNumber(value: theme == .dark)
        }
        #endif
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
