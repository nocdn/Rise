import AppKit
import WebKit
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
    func themeMenu() {
        let menu = NSMenu()
        menu.addItem(menuItem("Light", checked: theme == .neutral) { [weak self] in self?.theme = .neutral; self?.update() })
        menu.addItem(menuItem("Rose", checked: theme == .rose) { [weak self] in self?.theme = .rose; self?.update() })
        menu.addItem(menuItem("Dark", checked: theme == .dark) { [weak self] in self?.theme = .dark; self?.update() })
        menu.popUp(positioning: nil, at: NSPoint(x: 80, y: sidebar.bounds.height-42), in: sidebar)
    }
    func siteMenu() {
        let menu = makeSiteMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: sidebarWidth-40, y: 86), in: sidebar)
    }
    func makeSiteMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Copy URL") { [weak self] in self?.copyURL() })
        menu.addItem(menuItem("Developer Mode", checked: selectedTab?.developer == true) { [weak self] in self?.toggleDeveloper() })
        menu.addItem(menuItem("Site Information") { [weak self] in self?.siteInformation() })
        menu.addItem(menuItem("Save Page Screenshot…") { [weak self] in self?.capturePage() })
        menu.addItem(menuItem("Split View", checked: splitTab != nil) { [weak self] in self?.toggleSplit() })
        menu.addItem(.separator())
        let preload = menuItem("Preload Links (Experimental)", checked: linkPreloader.enabled) { [weak self] in
            guard let self else { return }
            self.linkPreloader.setEnabled(!self.linkPreloader.enabled)
        }
        preload.toolTip = "Hover over a link for 150 ms to warm its page in WebKit’s cache. Uses additional bandwidth."
        menu.addItem(preload)
        return menu
    }
    func archiveMenu() {
        let menu = NSMenu()
        if closedTabs.isEmpty { let item = NSMenuItem(title: "No recently closed tabs", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        for saved in closedTabs.suffix(15).reversed() {
            menu.addItem(menuItem(saved.title) { [weak self] in
                guard let self else { return }; self.closedTabs.removeAll { $0.id == saved.id }
                let tab = self.configure(BrowserTab(saved: saved)); self.tabs.append(tab); self.select(tab.id)
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: sidebar.bounds.height-42), in: sidebar)
    }
    func tabMenu(_ id: UUID, event: NSEvent) {
        guard let tab = tabs.first(where: { $0.id == id }), let row = sidebar.rows[id] else { return }
        let menu = NSMenu()
        menu.addItem(menuItem(tab.pinned ? "Unpin Tab" : "Pin Tab") { [weak self, weak tab] in tab?.pinned.toggle(); self?.update() })
        menu.addItem(menuItem("Duplicate Tab") { [weak self, weak tab] in if let url = tab?.url { self?.addTab(url: url) } })
        menu.addItem(menuItem("Open in Split View") { [weak self, weak tab] in if let tab { self?.showSplit(tab) } })
        if splitGroups.contains(where: { $0.contains(id) }) {
            menu.addItem(menuItem("Separate Split Tabs") { [weak self] in self?.separateSplit(containing: id) })
        }
        menu.addItem(menuItem("Developer Mode", checked: tab.developer) { [weak self, weak tab] in tab?.developer.toggle(); self?.update() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Close Tab") { [weak self] in self?.closeTab(id) })
        NSMenu.popUpContextMenu(menu, with: event, for: row)
    }
    @objc func peekCurrentPage() { if let url = selectedTab?.url { showPeek(url: url) } }
    func showPeek(url: URL) {
        cancelTabSwitch()
        closePeek()
        let tab = configure(BrowserTab()); peekTab = tab
        let backdrop = PeekBackdrop(color: theme.background.withAlphaComponent(0.72));
        backdrop.dismiss = { [weak self] in self?.closePeek() }; backdrop.frame = pageClip.bounds
        root.addSubview(backdrop, positioned: .below, relativeTo: dismissArea); peekBackdrop = backdrop
        let card = Surface(color: theme.page, radius: 8); card.layer?.masksToBounds = false
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.25
        card.layer?.shadowRadius = 8; card.layer?.shadowOffset = NSSize(width: 0, height: -2)
        let clip = Surface(color: theme.page, radius: 8); clip.layer?.masksToBounds = true; clip.clipsToBounds = true; clip.autoresizingMask = [.width, .height]
        card.addSubview(clip); clip.addSubview(tab.webView)
        root.addSubview(card, positioned: .below, relativeTo: dismissArea); peekCard = card
        for (symbol, title, action) in [
            ("xmark", "Close Peek", { [weak self] in self?.closePeek() }),
            ("arrow.up.left.and.arrow.down.right", "Expand Peek to tab", { [weak self] in self?.expandPeek() }),
            ("rectangle.split.2x1", "Open Peek in split view", { [weak self] in self?.splitPeek() })
        ] as [(String, String, () -> Void)] {
            let button = ChromeButton(symbol: symbol, size: 16, title: title, action: action)
            button.baseColor = theme.popup; button.clipsToBounds = false; button.wantsLayer = true; button.layer?.backgroundColor = theme.popup.cgColor; button.layer?.cornerRadius = 17
            button.layer?.shadowColor = NSColor.black.cgColor; button.layer?.shadowOpacity = 0.12; button.layer?.shadowRadius = 3
            button.contentTintColor = NSColor(hex: 0xE87088)
            root.addSubview(button, positioned: .below, relativeTo: dismissArea); peekControls.append(button)
        }
        layoutPeek(); tab.load(url); window?.makeFirstResponder(tab.webView)
    }
    func layoutPeek() {
        guard let peekCard, let peekTab else { return }
        peekBackdrop?.frame = pageShadow.frame
        let page = pageShadow.frame; let margin = min(120, page.width*0.1)
        peekCard.frame = NSRect(x: page.minX+margin, y: 12, width: page.width-margin*2, height: root.bounds.height-24)
        peekCard.layer?.shadowPath = CGPath(roundedRect: peekCard.bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        peekCard.subviews.first?.frame = peekCard.bounds; peekTab.webView.frame = peekCard.bounds
        for (i, button) in peekControls.enumerated() { button.frame = NSRect(x: peekCard.frame.maxX+12, y: 20+CGFloat(i)*44, width: 34, height: 34) }
    }
    func closePeek() {
        if let peekTab, hoveredWebView === peekTab.webView { hideLinkStatus() }
        peekTab?.webView.stopLoading(); peekTab = nil
        peekBackdrop?.removeFromSuperview(); peekBackdrop = nil
        peekCard?.removeFromSuperview(); peekCard = nil
        peekControls.forEach { $0.removeFromSuperview() }; peekControls = []
        window?.makeFirstResponder(selectedTab?.webView)
    }
    func expandPeek() {
        guard let tab = peekTab else { return }; tab.webView.removeFromSuperview()
        peekTab = nil; closePeek(); tabs.append(tab); select(tab.id)
    }
    func splitPeek() {
        guard let tab = peekTab else { return }; tab.webView.removeFromSuperview()
        peekTab = nil; closePeek(); tabs.append(tab); showSplit(tab)
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
        let anchor: NSView = selectedTab?.developer == true ? devButtons[4] : sidebarVisible ? sidebar.settingsButton : pageClip
        let rect = anchor === pageClip ? NSRect(x: 16, y: 8, width: 1, height: 1) : anchor.bounds
        siteInfoPopover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
    func navigateDeveloperAddress(_ text: String) {
        guard let url = AddressResolver.resolve(text), let tab = selectedTab else { return }
        errorWebView = nil; tab.load(url); update()
        window?.makeFirstResponder(tab.webView)
    }
    func capturePage() {
        guard let webView = selectedTab?.webView else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, error in
            guard let self, let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { if let error { self?.showMessage("Screenshot failed", error.localizedDescription) }; return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Rise Screenshot.png"
            guard let window = self.window else { return }
            panel.beginSheetModal(for: window) { result in
                if result == .OK, let url = panel.url { do { try data.write(to: url) } catch { self.showMessage("Couldn’t save screenshot", error.localizedDescription) } }
            }
        }
    }
    @objc func javascriptConsole() {
        guard let webView = selectedTab?.webView, let window else { return }
        let alert = NSAlert(); alert.messageText = "JavaScript Console"
        alert.informativeText = "Evaluate JavaScript in the current page. Full Web Inspector is available from Safari’s Develop menu while Developer Mode is enabled."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 28)); input.font = .monospacedSystemFont(ofSize: 12, weight: .regular); input.placeholderString = "document.title"
        alert.accessoryView = input; alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            webView.evaluateJavaScript(input.stringValue) { value, error in self?.showMessage("JavaScript Result", error?.localizedDescription ?? value.map { String(describing: $0) } ?? "undefined") }
        }; window.makeFirstResponder(input)
    }
    func viewSource() {
        guard let webView = selectedTab?.webView else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, error in
            guard let self, let html = value as? String else { return }
            let source = self.addTab(); source.title = "Page Source"
            let escaped = html.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let background = self.theme == .dark ? "1c1c1c" : "fdfcfc"
            let foreground = self.theme == .dark ? "d1d1d1" : "343434"
            source.webView.loadHTMLString("<meta charset='utf-8'><style>body{margin:24px;background:#\(background);color:#\(foreground)}pre{font:12px Menlo;white-space:pre-wrap;word-break:break-word}</style><pre>\(escaped)</pre>", baseURL: nil)
        }
    }
}
