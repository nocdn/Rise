import AppKit
import WebKit
import RiseCore

@MainActor final class BrowserController: NSWindowController, NSWindowDelegate {
    let root = Surface()
    let pageShadow = Surface(color: NSColor(hex: 0xFDFCFC), radius: 7)
    let pageClip = Surface(color: NSColor(hex: 0xFDFCFC), radius: 7)
    let emptyPage = Surface(color: NSColor(hex: 0xFDFCFC))
    let linkStatus = LinkStatusPill()
    weak var hoveredWebView: WKWebView?
    let developerBar = DeveloperHeader(color: NSColor(hex: 0xFCF6F7))
    let developerAddress = DeveloperAddressField(frame: .zero)
    let siteInfoPopover = NSPopover()
    let errorSurface = Surface(color: NSColor(hex: 0xFDFCFC))
    let errorTitle = label("This page couldn’t be opened", size: 23, weight: .semibold)
    let errorMessage = label("", size: 13, color: .secondaryLabelColor)
    var retryButton: NSButton!
    let dismissArea = DismissView()
    let palette = AddressPalette()
    let grip = SidebarGrip()
    let findBar = FindBar()
    var sidebar: SidebarView!
    let toolbarHost = NativeTitlebarControls()
    let toolbarAccessory = NSTitlebarAccessoryViewController()
    var trafficLights: NativeTrafficLights!
    var toolbarButtons: [ChromeButton] = []
    var devButtons: [ChromeButton] = []
    lazy var historySwipe = HistorySwipeController(window: window as! BrowserWindow, pageAt: { [weak self] event in
        self?.historyPage(at: event)
    }, feedback: { [weak self] direction, pull, armed, release in
        guard let self, let direction, let arrow = self.toolbarButtons[direction == .back ? 1 : 2] as? HistoryArrowButton else { return }
        if let committed = release { arrow.release(committed: committed) }
        else { arrow.drag(pull: pull, armed: armed) }
    })
    var tabs: [BrowserTab] = []
    var selectedID: UUID?
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var closedTabs: [SavedTab] = []
    var history: [SavedTab] = []
    var theme: RiseTheme = .neutral
    var sidebarWidth: CGFloat = 228
    var sidebarVisible = true
    var paletteCreatesTab = false
    var splitGroups: [SplitTabGroup] = []
    var peekTab: BrowserTab?
    var peekBackdrop: Surface?
    var peekCard: Surface?
    var peekControls: [ChromeButton] = []
    var saveWork: DispatchWorkItem?
    let sessionURL: URL
    var lastSaved: BrowserSession?
    var errorWebView: WKWebView?
    let linkPreloader: LinkPreloader
    let tabSwitcher = TabSwitcherView()
    let tabSwitchBackdrop = PeekBackdrop(color: NSColor.black.withAlphaComponent(0.08))
    var recentTabIDs: [UUID] = []
    var tabSwitchOrder: [UUID] = []
    var tabSwitchIndex = 0
    var tabSwitchWork: DispatchWorkItem?
    var tabSwitchGeneration = 0
    var pendingMiddleTabID: UUID?

    init(sessionURL: URL? = nil, restore: Bool = true, preferences: UserDefaults = .standard) {
        linkPreloader = LinkPreloader(preferences: preferences)
        self.sessionURL = sessionURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rise/session.json")
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1496, height: 944), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.tabSwitchEvent = { [weak self] event in self?.handleTabSwitchEvent(event) ?? false }
        window.pageMouseDown = { [weak self] event in self?.focusSplitPage(at: event) }
        window.historyScrollEvent = { [weak self] event in self?.historySwipe.handle(event) ?? false }
        window.otherMouseEvent = { [weak self] event in self?.handleMiddleTabClick(event) ?? false }
        tabSwitcher.choose = { [weak self] id in self?.commitTabSwitch(id) }
        tabSwitchBackdrop.dismiss = { [weak self] in self?.cancelTabSwitch() }
        tabSwitchBackdrop.isHidden = true
        linkPreloader.onHover = { [weak self] url, webView in self?.showHoveredLink(url, in: webView) }
        linkPreloader.onComplete = { [weak self] url in
            guard let self, let hovered = self.linkStatus.url,
                  LinkPreloader.cacheKey(hovered) == url else { return }
            self.linkStatus.markReady(hovered)
        }
        window.title = "Rise"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false; window.minSize = NSSize(width: 720, height: 480)
        window.appearance = NSAppearance(named: .aqua); window.delegate = self
        window.contentView = root; window.setFrameAutosaveName("RiseBrowser")
        if !window.setFrameUsingName("RiseBrowser") { window.center() }
        window.escapeAction = { [weak self] in
            guard let self else { return false }
            if self.isSwitchingTabs { self.cancelTabSwitch(); return true }
            if !self.palette.isHidden { self.hidePalette(); return true }
            if !self.findBar.isHidden { self.hideFind(); return true }
            if self.peekTab != nil { self.closePeek(); return true }
            return false
        }
        buildChrome()
        if restore, let saved = SessionStorage.read(from: self.sessionURL) {
            theme = RiseTheme(rawValue: saved.theme) ?? .neutral
            sidebarWidth = min(360, max(200, saved.sidebarWidth))
            tabs = saved.tabs.map { configure(BrowserTab(saved: $0)) }
            splitGroups = saved.splitGroups
            selectedID = saved.selectedID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
        }
        if let selectedID { select(selectedID) }
        update(); layoutChrome()
    }
    required init?(coder: NSCoder) { fatalError() }
    func buildChrome() {
        sidebar = SidebarView(copy: { [weak self] in self?.copyURL() }, settings: { [weak self] in self?.siteMenu() }, archive: { [weak self] in self?.archiveMenu() }, theme: { [weak self] in self?.themeMenu() }, clear: { [weak self] in self?.clearTabs() })
        sidebar.onAddress = { [weak self] in self?.focusAddress() }
        sidebar.onNewTab = { [weak self] in self?.newTab() }
        sidebar.onSelect = { [weak self] id in self?.select(id) }
        sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        sidebar.onTabMenu = { [weak self] id, event in self?.tabMenu(id, event: event) }
        pageShadow.shadow = chromeShadow(opacity: 0.10, blur: 4, offset: -1)
        pageClip.layer?.masksToBounds = true; pageClip.clipsToBounds = true
        root.addSubview(sidebar); root.addSubview(pageShadow); pageShadow.addSubview(pageClip)
        pageClip.addSubview(emptyPage); pageClip.addSubview(developerBar)
        root.addSubview(grip)
        grip.resize = { [weak self] width in self?.sidebarWidth = min(360, max(200, width)); self?.layoutChrome(); self?.scheduleSave() }
        let actions: [(String, String, () -> Void)] = [
            ("sidebar.left", "Toggle Sidebar (⌘B)", { [weak self] in self?.toggleSidebar() }),
            ("arrow.left", "Back (⌘[)", { [weak self] in self?.goBack() }),
            ("arrow.right", "Forward (⌘])", { [weak self] in self?.goForward() }),
            ("arrow.clockwise", "Reload (⌘R)", { [weak self] in self?.reload() })
        ]
        for (symbol, title, action) in actions {
            let button: ChromeButton
            if symbol == "arrow.left" || symbol == "arrow.right" {
                button = HistoryArrowButton(direction: symbol == "arrow.left" ? .back : .forward, title: title, action: action)
            } else { button = ChromeButton(symbol: symbol, size: 16, title: title, action: action) }
            toolbarHost.addSubview(button); toolbarButtons.append(button)
        }
        developerAddress.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        developerAddress.textColor = NSColor(hex: 0x393134); developerBar.addSubview(developerAddress)
        developerAddress.onSubmit = { [weak self] text in self?.navigateDeveloperAddress(text) }
        developerAddress.onCancel = { [weak self] in self?.window?.makeFirstResponder(self?.selectedTab?.webView) }
        siteInfoPopover.behavior = .transient
        let devActions: [(String, String, () -> Void)] = [
            ("link", "Copy URL", { [weak self] in self?.copyURL() }),
            ("camera", "Save page screenshot", { [weak self] in self?.capturePage() }),
            ("terminal", "JavaScript Console", { [weak self] in self?.javascriptConsole() }),
            ("doc.text", "View page source", { [weak self] in self?.viewSource() }),
            ("info.circle", "Site information", { [weak self] in self?.siteInformation() }),
            ("rectangle.split.2x1", "Split view", { [weak self] in self?.toggleSplit() })
        ]
        for (symbol, title, action) in devActions {
            let button = ChromeButton(symbol: symbol, size: 15, title: title, action: action)
            button.contentTintColor = NSColor(hex: 0xDE3453); developerBar.addSubview(button); devButtons.append(button)
        }
        errorTitle.alignment = .center; errorMessage.alignment = .center
        errorMessage.maximumNumberOfLines = 3
        retryButton = NSButton(title: "Try Again", target: self, action: #selector(retry))
        retryButton.bezelStyle = .rounded
        [errorTitle, errorMessage, retryButton].forEach(errorSurface.addSubview); errorSurface.isHidden = true
        pageClip.addSubview(errorSurface)
        dismissArea.dismiss = { [weak self] in self?.hidePalette() }; dismissArea.isHidden = true
        root.addSubview(findBar)
        findBar.search = { [weak self] text, backwards in
            let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true
            self?.selectedTab?.webView.find(text, configuration: config) { [weak self] result in
                self?.findBar.input.textColor = text.isEmpty || result.matchFound ? .labelColor : .systemRed
            }
        }
        findBar.dismiss = { [weak self] in self?.hideFind() }
        root.addSubview(linkStatus); root.addSubview(dismissArea); root.addSubview(palette)
        palette.dismiss = { [weak self] in self?.hidePalette() }
        palette.queryChanged = { [weak self] text in self?.suggestions(for: text) ?? [] }
        palette.submit = { [weak self] text, suggestion in self?.submitAddress(text, suggestion: suggestion) }
        // Keep system controls in their original titlebar hierarchy. AppKit owns
        // their size, grouping, Liquid Glass rendering, and fullscreen behavior.
        let toolbar = NSToolbar(identifier: "Rise.Toolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbarStyle = .unified
        window?.toolbar = toolbar
        window?.titlebarSeparatorStyle = .none
        toolbarHost.buttons = toolbarButtons
        toolbarHost.frame = NSRect(x: 0, y: 0, width: 144, height: 48)
        toolbarAccessory.view = toolbarHost
        toolbarAccessory.layoutAttribute = .left
        window?.addTitlebarAccessoryViewController(toolbarAccessory)
        if let window { trafficLights = NativeTrafficLights(window: window) }
    }
    func layoutChrome() {
        guard let window else { return }; let b = root.bounds
        root.fill = theme.background; root.gradientColors = theme.backgroundGradient; window.backgroundColor = theme.background
        let sw = sidebarVisible ? sidebarWidth : 0
        sidebar.isHidden = !sidebarVisible; sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: b.height)
        // Keep the native titlebar hierarchy intact, but hide all of its chrome
        // for the edge-to-edge reading layout. No animator proxies are involved.
        if toolbarAccessory.isHidden == sidebarVisible { toolbarAccessory.isHidden = !sidebarVisible }
        if window.toolbar?.isVisible != sidebarVisible { window.toolbar?.isVisible = sidebarVisible }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !sidebarVisible
        }
        toolbarHost.isHidden = !sidebarVisible
        toolbarButtons.forEach { $0.isHidden = !sidebarVisible }
        let toolbarX = toolbarHost.convert(toolbarHost.bounds, to: root).minX
        toolbarHost.frame.size.width = sidebarVisible ? max(112, sidebarWidth-toolbarX-8) : 28
        toolbarHost.layout()
        trafficLights.update(visible: sidebarVisible, theme: theme)
        let pageX = sidebarVisible ? sw : 7
        let pageY: CGFloat = 7
        pageShadow.frame = NSRect(x: pageX, y: pageY, width: b.width-pageX-7, height: b.height-pageY-7)
        pageShadow.layer?.shadowPath = CGPath(roundedRect: pageShadow.bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        pageClip.frame = pageShadow.bounds
        grip.frame = NSRect(x: sw-3, y: 44, width: 6, height: b.height-88); grip.isHidden = !sidebarVisible
        let cb = pageClip.bounds; let devHeight: CGFloat = selectedTab?.developer == true ? 40 : 0
        developerBar.frame = NSRect(x: 0, y: 0, width: cb.width, height: devHeight)
        developerBar.isHidden = devHeight == 0
        let addressHeight = developerAddress.intrinsicContentSize.height
        developerAddress.frame = NSRect(x: 18, y: (devHeight-addressHeight)/2, width: max(100, cb.width-270), height: addressHeight)
        devButtons.enumerated().forEach { i, button in button.frame = NSRect(x: cb.width-240+CGFloat(i)*38, y: 6, width: 30, height: 28) }
        let body = NSRect(x: 0, y: devHeight, width: cb.width, height: cb.height-devHeight)
        emptyPage.frame = body
        if let group = activeSplitGroup {
            tabs.first { $0.id == group.leftID }?.webView.frame = NSRect(x: 0, y: devHeight, width: (body.width-6)/2, height: body.height)
            tabs.first { $0.id == group.rightID }?.webView.frame = NSRect(x: (body.width+6)/2, y: devHeight, width: (body.width-6)/2, height: body.height)
        } else { selectedTab?.webView.frame = body }
        errorSurface.frame = body
        errorTitle.frame = NSRect(x: 40, y: body.height/2-60, width: body.width-80, height: 34)
        errorMessage.frame = NSRect(x: 60, y: body.height/2-12, width: body.width-120, height: 56)
        retryButton.frame = NSRect(x: body.width/2-55, y: body.height/2+55, width: 110, height: 32)
        findBar.frame = NSRect(x: pageShadow.frame.maxX-354, y: pageShadow.frame.minY+devHeight+8, width: 340, height: 42)
        dismissArea.frame = b
        palette.place(at: NSPoint(x: 8, y: 50), width: paletteCreatesTab ? 400 : 350)
        layoutPeek()
        layoutLinkStatus()
        tabSwitchBackdrop.frame = b
        if !tabSwitcher.isHidden { tabSwitcher.place(in: b) }
    }
    func windowDidResize(_ notification: Notification) { layoutChrome() }
    func windowWillClose(_ notification: Notification) { historySwipe.cancel(); trafficLights.detach(); siteInfoPopover.close(); cancelTabSwitch(); saveNow() }
    func windowDidBecomeKey(_ notification: Notification) { trafficLights?.update(visible: sidebarVisible, theme: theme) }
    func windowDidResignKey(_ notification: Notification) { trafficLights?.update(visible: sidebarVisible, theme: theme); pendingMiddleTabID = nil; historySwipe.cancel(); cancelTabSwitch() }
    func configure(_ tab: BrowserTab) -> BrowserTab {
        tab.webView.navigationDelegate = self; tab.webView.uiDelegate = self
        tab.webView.appearance = theme.appearance; tab.webView.underPageBackgroundColor = theme.page
        linkPreloader.install(on: tab.webView)
        tab.onChange = { [weak self] in self?.update() }
        tab.onThumbnailChange = { [weak self] in self?.refreshTabSwitcher() }
        return tab
    }
    @discardableResult func addTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = configure(BrowserTab(configuration: configuration)); tabs.append(tab); select(tab.id)
        if let url { tab.load(url) }; return tab
    }
    func select(_ id: UUID) {
        historySwipe.cancel()
        cancelTabSwitch()
        siteInfoPopover.close()
        if selectedID != id { selectedTab?.captureThumbnail() }
        hideLinkStatus()
        hidePalette(); closePeek()
        selectedID = id
        attachVisiblePages()
        recentTabIDs.removeAll { $0 == id }; recentTabIDs.insert(id, at: 0)
        if let tab = selectedTab {
            window?.makeFirstResponder(tab.webView)
        }
        update(); layoutChrome()
    }
    func update() {
        applyTheme()
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: splitGroups)
        window?.title = (selectedTab?.title).map { "\($0) — Rise" } ?? "Rise"
        toolbarButtons[1].isEnabled = selectedTab?.webView.canGoBack ?? false
        toolbarButtons[2].isEnabled = selectedTab?.webView.canGoForward ?? false
        toolbarButtons[3].image = NSImage(systemSymbolName: selectedTab?.webView.isLoading == true ? "xmark" : "arrow.clockwise", accessibilityDescription: "Reload or stop")
        developerAddress.updateURL(selectedTab?.url?.absoluteString ?? "")
        errorSurface.isHidden = errorWebView == nil || errorWebView !== selectedTab?.webView
        layoutChrome(); refreshTabSwitcher(); scheduleSave()
    }
    @objc func newTab() { paletteCreatesTab = true; showPalette(text: "") }
    @objc func focusAddress() { paletteCreatesTab = false; showPalette(text: selectedTab?.url?.absoluteString == "about:blank" ? "" : selectedTab?.url?.absoluteString ?? "") }
    func showPalette(text: String) { historySwipe.cancel(); cancelTabSwitch(); hideLinkStatus(); dismissArea.isHidden = false; palette.show(text: text, theme: theme); layoutChrome() }
    func hidePalette() { guard palette.isPresented else { return }; palette.hide(); dismissArea.isHidden = true; window?.makeFirstResponder(selectedTab?.webView) }
    func suggestions(for text: String) -> [AddressSuggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [AddressSuggestion] = []
        if !query.isEmpty, let url = AddressResolver.resolve(query) {
            result.append(AddressSuggestion(title: url.host == "www.google.com" && url.path == "/search" ? "Search Google for “\(query)”" : AddressResolver.displayHost(url), subtitle: "", symbol: "magnifyingglass", url: url, tabID: nil, command: nil))
        }
        let matchingTabs = tabs.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false) }
        result += matchingTabs.prefix(3).map { AddressSuggestion(title: $0.title, subtitle: "Switch to tab", symbol: "globe", url: nil, tabID: $0.id, command: nil) }
        if query.isEmpty {
            for (name, url) in [("Hacker News", "https://news.ycombinator.com"), ("Wikipedia", "https://en.wikipedia.org"), ("GitHub", "https://github.com")] {
                result.append(AddressSuggestion(title: name, subtitle: url, symbol: "globe", url: URL(string: url), tabID: nil, command: nil))
            }
        } else {
            for entry in history.reversed() where entry.title.localizedCaseInsensitiveContains(query) || entry.url.localizedCaseInsensitiveContains(query) {
                if !result.contains(where: { $0.url?.absoluteString == entry.url }) { result.append(AddressSuggestion(title: entry.title, subtitle: entry.url, symbol: "clock", url: URL(string: entry.url), tabID: nil, command: nil)) }
                if result.count >= 5 { break }
            }
            for (name, symbol) in [("Toggle Developer Mode", "hammer"), ("Change Theme", "paintpalette"), ("Toggle Sidebar", "sidebar.left"), ("Split View", "rectangle.split.2x1")] where name.localizedCaseInsensitiveContains(query) {
                result.insert(AddressSuggestion(title: name, subtitle: "", symbol: symbol, url: nil, tabID: nil, command: name), at: 0)
            }
        }
        return Array(result.prefix(5))
    }
    func submitAddress(_ text: String, suggestion: AddressSuggestion?) {
        hidePalette()
        if let id = suggestion?.tabID { select(id); return }
        if let command = suggestion?.command {
            switch command {
            case "Toggle Developer Mode": toggleDeveloper()
            case "Change Theme": toggleTheme()
            case "Toggle Sidebar": toggleSidebar()
            case "Split View": toggleSplit()
            default: break
            }; return
        }
        guard let url = suggestion?.url ?? AddressResolver.resolve(text) else { return }
        if paletteCreatesTab || selectedTab == nil { addTab(url: url) }
        else { errorWebView = nil; selectedTab?.load(url) }
    }
    @objc func closeCurrentTab() { if let id = selectedID { closeTab(id) } }
    func closeTab(_ id: UUID) {
        historySwipe.cancel()
        cancelTabSwitch()
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let partner = splitGroups.first { $0.contains(id) }.map { $0.leftID == id ? $0.rightID : $0.leftID }
        splitGroups.removeAll { $0.contains(id) }
        let tab = tabs.remove(at: index); closedTabs.append(tab.saved)
        recentTabIDs.removeAll { $0 == id }
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        tab.webView.stopLoading(); tab.webView.removeFromSuperview()
        if selectedID == id {
            selectedID = nil
            if let partner, tabs.contains(where: { $0.id == partner }) { select(partner) }
            else if !tabs.isEmpty { select(tabs[min(index, tabs.count-1)].id) }
        }
        attachVisiblePages(); update()
    }
    @objc func reopenTab() { guard let saved = closedTabs.popLast() else { return }; let tab = configure(BrowserTab(saved: saved)); tabs.append(tab); select(tab.id) }
    func clearTabs() { for id in tabs.filter({ !$0.pinned }).map(\.id) { closeTab(id) } }
    @objc func goBack() { historySwipe.cancel(); errorWebView = nil; selectedTab?.webView.goBack(); update() }
    @objc func goForward() { historySwipe.cancel(); errorWebView = nil; selectedTab?.webView.goForward(); update() }
    @objc func reload() { historySwipe.cancel(); errorWebView = nil; if selectedTab?.webView.isLoading == true { selectedTab?.webView.stopLoading() } else { selectedTab?.webView.reload() }; update() }
    @objc func retry() { errorWebView = nil; if let url = selectedTab?.url { selectedTab?.load(url) }; update() }
    @objc func toggleSidebar() {
        sidebarVisible.toggle()
        if !sidebarVisible { sidebar.newTab.resetHover() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChrome(); root.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
    @objc func toggleDeveloper() { window?.makeFirstResponder(selectedTab?.webView); siteInfoPopover.close(); selectedTab?.developer.toggle(); update() }
    @objc func toggleTheme() {
        let themes = RiseTheme.allCases
        theme = themes[((themes.firstIndex(of: theme) ?? 0) + 1) % themes.count]; update()
    }
    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    func cycleTab(_ direction: Int) { guard !tabs.isEmpty else { return }; let index = tabs.firstIndex { $0.id == selectedID } ?? 0; select(tabs[(index+direction+tabs.count)%tabs.count].id) }
    @objc func copyURL() { guard let url = selectedTab?.url else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
    @objc func zoomIn() { selectedTab?.webView.pageZoom = min(3, (selectedTab?.webView.pageZoom ?? 1)+0.1) }
    @objc func zoomOut() { selectedTab?.webView.pageZoom = max(0.3, (selectedTab?.webView.pageZoom ?? 1)-0.1) }
    @objc func actualSize() { selectedTab?.webView.pageZoom = 1 }
    func scheduleSave() {
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.saveNow() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: work)
    }
    func saveNow() {
        let state = BrowserSession(tabs: tabs.map(\.saved), selectedID: selectedID, theme: theme.rawValue, sidebarWidth: sidebarWidth, splitGroups: splitGroups)
        guard state != lastSaved else { return }
        do { try SessionStorage.write(state, to: sessionURL); lastSaved = state }
        catch { NSLog("Rise session save failed: %@", error.localizedDescription) }
    }
}
