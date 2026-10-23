import AppKit
import RiseCore

@MainActor final class MenuAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
@MainActor extension BrowserController {
    func menuItem(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        let handler = MenuAction(action); item.target = handler; item.representedObject = handler
        item.state = checked ? .on : .off; return item
    }
    func makeThemeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Theme")
        for (title, choice) in [("Light", RiseTheme.neutral), ("Dark", .dark)] {
            submenu.addItem(menuItem(title, checked: !automaticTheme && theme == choice) { [weak self] in self?.chooseTheme(choice) })
        }
        submenu.addItem(.separator())
        submenu.addItem(menuItem("Automatic", checked: automaticTheme) { [weak self] in self?.chooseTheme(nil) })
        item.submenu = submenu
        return item
    }
    func siteMenu() {
        if siteControlsPopover.isShown { siteControlsPopover.close(); return }
        guard selectedTab != nil else { return }
        permissionCoordinator.cancel(); siteInfoPopover.close(); historySwipe.cancel()
        let controller = SiteControlsController(browser: self)
        siteControlsPopover.appearance = theme.appearance
        siteControlsPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        siteControlsPopover.contentViewController = controller
        siteControlsPopover.contentSize = controller.view.frame.size
        siteControlsPopover.show(relativeTo: selectedBar.settingsButton.bounds, of: selectedBar.settingsButton, preferredEdge: .maxY)
    }
    func makeSiteMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Copy URL") { [weak self] in self?.copyURL() })
        menu.addItem(menuItem("Site Information") { [weak self] in self?.siteInformation() })
        menu.addItem(menuItem("Save Page Screenshot…") { [weak self] in self?.capturePage() })
        menu.addItem(menuItem("Split View", checked: splitTab != nil) { [weak self] in self?.toggleSplit() })
        return menu
    }
    func archiveMenu() {
        let menu = NSMenu()
        if closedTabs.isEmpty { let item = NSMenuItem(title: "No recently closed tabs", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        for saved in closedTabs.suffix(15).reversed() {
            menu.addItem(menuItem(saved.title) { [weak self] in self?.reopenClosedTab(saved.id) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: sidebar.bounds.height-42), in: sidebar)
    }
    /// For now only the title's shimmer, standing in for the rename to come.
    func smartRename(_ id: UUID) { sidebar.rows[id]?.shimmerTitle() }
    /// ⌃R over a tab in the sidebar, an easy reach for the left hand. With no tab under the
    /// pointer, the keys go on to the page.
    func handleSmartRenameKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control,
              event.charactersIgnoringModifiers?.lowercased() == "r", let id = hoveredSidebarTabID else { return false }
        smartRename(id); return true
    }
    var hoveredSidebarTabID: UUID? {
        sidebar.rows.first { $0.value.isHovered && !$0.value.isHiddenOrHasHiddenAncestor && $0.value.window != nil }?.key
            ?? sidebar.pinnedView.tiles.values.first { $0.isHovered && $0.window != nil }?.tabID
    }
    func tabMenu(_ id: UUID, event: NSEvent) {
        guard let menu = makeTabMenu(id), let row = sidebar.anchor(for: id) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: row)
    }
    func makeTabMenu(_ id: UUID) -> NSMenu? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        let pin = menuItem(tab.pinned ? "Unpin Tab" : "Pin Tab") { [weak self] in self?.togglePin(id) }
        pin.isEnabled = tab.pinned || canPinTab && !splitGroups.contains { $0.contains(id) }
        menu.addItem(pin)
        menu.addItem(menuItem("Duplicate Tab") { [weak self, weak tab] in if let url = tab?.url { self?.addTab(url: url) } })
        menu.addItem(menuItem("Smart Rename") { [weak self] in self?.smartRename(id) })
        menu.addItem(menuItem("Open in Split View") { [weak self, weak tab] in if let tab { self?.showSplit(tab) } })
        menu.addItem(menuItem("Developer Mode", checked: tab.developer) { [weak self, weak tab] in
            if let tab { self?.toggleDeveloperMode(for: tab) }
        })
        menu.addItem(.separator())
        if splitGroups.contains(where: { $0.contains(id) }) {
            menu.addItem(menuItem("Separate Tabs") { [weak self] in self?.separateSplit(containing: id) })
        }
        menu.addItem(menuItem("Close Tab") { [weak self] in self?.closeTab(id) })
        return menu
    }
    @objc func peekCurrentPage() { if let url = selectedTab?.url { showPeek(url: url) } }
    /// `existing` brings back a page that was a Peek before, as ⌘Z does, without loading it again,
    /// shrinking it out of `standIn`, the page it had become, when given.
    func showPeek(url: URL, from source: NSView? = nil, opensNewTab: Bool = false, existing: BrowserTab? = nil, standIn: PeekOrigin? = nil, animated: Bool = true) {
        // One Peek at a time: a Peek link inside the Peek shakes the pill's "Cannot open … in Peek".
        if source != nil, source === peekTab?.page.view { refusePeek(url); return }
        if existing == nil { discardPeekUndo() }
        let sourcePage = page(showing: source)
        let sourceID = tabs.first { $0.page.view === source }?.id ?? peekSourceTabID ?? selectedID
        cancelTabSwitch()
        closePeek(replacing: true); hideLinkStatus()
        peekSourceTabID = sourceID; peekOpensNewTab = opensNewTab
        let reveal = animated ? beginPeekReveal(from: sourcePage, standIn: standIn) : nil
        // A page already rendering from a Shift-hover shows from the first frame.
        let standby = existing == nil ? takePeekStandby(for: url) : nil
        let tab = existing ?? standby ?? configure(BrowserTab()); peekTab = tab
        selectedFindBar.removeFromSuperview()
        let backdrop = PeekBackdrop(color: theme.background.withAlphaComponent(0.72));
        backdrop.dismiss = { [weak self] in self?.closePeek(animated: true) }; backdrop.frame = pageClip.bounds
        // Dimming lives inside the page so it recedes with it and never covers the page's shadow.
        pageClip.addSubview(backdrop); peekBackdrop = backdrop
        // Smoothed corners, as the page's, so it's one shape as it becomes a tab or a split's half.
        let card = PageSurface(color: theme.page, radius: 8); card.layer?.masksToBounds = false; card.layer?.cornerCurve = .continuous
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.25
        card.layer?.shadowRadius = 8; card.layer?.shadowOffset = NSSize(width: 0, height: -2)
        let clip = PageSurface(color: theme.page, radius: 8); clip.layer?.masksToBounds = true; clip.clipsToBounds = true; clip.layer?.cornerCurve = .continuous; clip.autoresizingMask = [.width, .height]
        card.addSubview(clip); clip.addSubview(tab.page.view)
        root.addSubview(card, positioned: .below, relativeTo: dismissArea); peekCard = card
        for (glyph, title, action) in [
            (PeekControl.Glyph.cross, "Close Peek", { [weak self] in self?.closePeek(animated: true) }),
            (.arrows, "Expand Peek to tab", { [weak self] in self?.expandPeek() }),
            (.split, "Open Peek in split view", { [weak self] in self?.splitPeek() })
        ] as [(PeekControl.Glyph, String, () -> Void)] {
            let button = PeekControl(glyph: glyph, title: title); button.action = action; button.applyTheme(theme)
            root.addSubview(button, positioned: .below, relativeTo: dismissArea); peekControls.append(button)
        }
        layoutPeek(); if standby == nil, existing == nil { tab.load(url) }; window?.makeFirstResponder(tab.page.view)
        updatePeekCovers()
        revealPeek(reveal)
        if !animated { recedePage(true, along: nil) }
        update()
        findBars[tab.id]?.reattached()
    }
    var peekCardFrame: NSRect {
        let page = pageShadow.frame; let margin = min(120, page.width*0.1)
        return NSRect(x: page.minX+margin, y: 12, width: page.width-margin*2, height: root.bounds.height-24)
    }
    func layoutPeek() {
        layoutPeekStandby()
        // The card is mid-way through a live resize, which places it every frame.
        guard let peekCard, let peekTab, peekLiveMotion?.isRunning != true else { return }
        peekBackdrop?.frame = pageClip.bounds
        peekCard.frame = peekCardFrame
        // Keep a settled, receded page centered after the window resizes.
        if let layer = pageShadow.layer, layer.animation(forKey: "peek.recede") == nil, !CATransform3DIsIdentity(layer.transform) {
            recedePage(true, along: nil)
        }
        (peekCard as? PageSurface)?.refreshOutline()
        peekCard.subviews.first?.frame = peekCard.bounds
        peekTab.page.view.frame = peekCard.bounds
        layoutPeekFindBar()
        for (i, button) in peekControls.enumerated() { button.frame = PeekControl.frame(cardMaxX: peekCard.frame.maxX, top: 20+CGFloat(i)*44) }
        if peekSwipePull > 0 { applyPeekSwipeTransform() }
    }
    /// Animated closes spring the Peek back into its link, reversing one that is still
    /// growing. State clears immediately either way. Replacing a Peek keeps the page
    /// receded and lets the old dimming fade under the new one.
    func closePeek(animated: Bool = false, replacing: Bool = false) {
        if let page = peekTab?.page { historySwipe.cancel(for: page) }
        // An interrupted live resize leaves the pages for layout to put back.
        let interrupted = peekLiveMotion?.isRunning == true
        // A hold of the pages' layout is a motion's, let go with it; ⌘Z's for a split holds the
        // page behind on through the Peek it reopens (`restorePeek`).
        if interrupted || isPromotingPeek { pageLayoutHeld = false }
        peekLiveMotion?.stop(); peekLiveMotion = nil; isPromotingPeek = false
        let card = peekCard, backdrop = peekBackdrop, web = peekTab?.page, origin = peekOrigin
        peekSourceTabID = nil; peekOpensNewTab = false; peekSwipePull = 0
        let motion = animated && peekMotionAllowed, growing = peekGhosts.first { $0.phase == .opening }
        // Pending lookups and snapshots no longer apply; cards already shrinking finish on their own.
        peekMotionToken = nil; peekLeftovers.forEach { $0.removeFromSuperview() }; peekLeftovers = []
        if !motion { growing?.dismantle() }
        peekOrigin = nil
        if let peekTab { permissionCoordinator.cancel(for: peekTab.page.view) }
        if let peekTab, hoveredWebView === peekTab.page.view { hideLinkStatus() }
        if let peekTab { findBars.removeValue(forKey: peekTab.id)?.discard() }
        peekTab?.cancelLoad(); peekTab = nil
        peekBackdrop = nil; peekCard = nil
        swapFindBar(from: nil)
        if motion, let card {
            recedePage(false, along: Self.peekPageReturnSpring)
            if let growing { shrinkPeek(growing, into: peekFrame(of: origin), backdrop: backdrop); retire(card, behind: growing) }
            else if card.alphaValue == 1, let web {
                dismissPeek(card: card, backdrop: backdrop, page: web, origin: origin, hold: peekControls.isEmpty ? 0 : Self.peekCloseHold)
            }
            else { backdrop?.removeFromSuperview(); card.removeFromSuperview() }
        } else {
            card?.removeFromSuperview()
            if replacing, peekMotionAllowed, let backdrop, backdrop.alphaValue > 0 {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; backdrop.animator().alphaValue = 0 },
                    completionHandler: { backdrop.removeFromSuperview() })
            } else { backdrop?.removeFromSuperview() }
            if !replacing, !peekGhosts.contains(where: { $0.phase == .closing }) { recedePage(false, along: nil) }
        }
        let controls = peekControls; peekControls = []
        tuckPeekControls(controls, animated: motion && card != nil)
        window?.makeFirstResponder(selectedTab?.page.view)
        updatePeekCovers(); update()
        if interrupted { layoutChrome() }
    }
    func showMessage(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }
    func siteInformation() {
        if siteInfoPopover.isShown { siteInfoPopover.performClose(nil); return }
        guard let url = selectedTab?.url else { return }
        let content = SiteInformationController(url: url)
        content.view.appearance = theme.appearance
        siteInfoPopover.contentViewController = content
        siteInfoPopover.contentSize = content.view.fittingSize
        let anchor: NSView = selectedTab?.developer == true ? devButtons[4] : selectedBar.settingsButton
        let rect = anchor.bounds
        siteInfoPopover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
    func navigateDeveloperAddress(_ text: String) {
        guard let url = AddressResolver.resolve(text, search: searchProvider.searchURL), let tab = selectedTab else { return }
        errorWebView = nil; tab.load(url); update()
        window?.makeFirstResponder(tab.page.view)
    }
    func capturePage() {
        guard let page = selectedTab?.page else { return }
        Task { [weak self] in
            let image = await page.snapshot(width: nil)
            guard let self else { return }
            guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else {
                self.showMessage("Screenshot failed", "No page image available."); return
            }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Rise Screenshot.png"
            guard let window = self.window else { return }
            panel.beginSheetModal(for: window) { result in
                if result == .OK, let url = panel.url { do { try data.write(to: url) } catch { self.showMessage("Couldn’t save screenshot", error.localizedDescription) } }
            }
        }
    }
    @objc func javascriptConsole() {
        guard let tab = selectedTab, let window else { return }
        let alert = NSAlert(); alert.messageText = "JavaScript Console"
        alert.informativeText = "Evaluate JavaScript in the current page. The full DevTools open with ⌥⌘J."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 28)); input.font = .monospacedSystemFont(ofSize: 12, weight: .regular); input.placeholderString = "document.title"
        alert.accessoryView = input; alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            let show = { (value: Any?, error: String?) in self?.showMessage("JavaScript Result", error ?? value.map { String(describing: $0) } ?? "undefined") }
            guard let chromium = tab.page as? ChromiumPage else { return }
            chromium.browserView.evaluateConsoleExpression(input.stringValue) { value, error in MainActor.assumeIsolated { show(value, error) } }
        }; window.makeFirstResponder(input)
    }
    /// The source as the server sent it, in a tab of its own.
    func viewSource() {
        guard let tab = selectedTab, let url = tab.page.url, ["http", "https", "file"].contains(url.scheme ?? ""),
              let source = URL(string: "view-source:" + url.absoluteString) else { return }
        addTab(url: source, opener: tab.id).returnsTo = tab.id
    }
}
