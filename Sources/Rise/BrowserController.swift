import AppKit
import WebKit
import RiseCore

@MainActor final class BrowserController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    let root = Surface()
    let pageShadow = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let pageClip = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let emptyPage = Surface(color: NSColor(hex: 0xFDFCFC))
    let linkStatus = LinkStatusPill()
    weak var hoveredWebView: WKWebView?
    let developerBar = DeveloperHeader(color: NSColor(hex: 0xFCF6F7))
    let developerAddress = DeveloperAddressField(frame: .zero)
    lazy var developerMotion = DeveloperModeMotion { [weak self] in self?.layoutChrome() }
    let siteInfoPopover = NSPopover()
    let siteControlsPopover = NSPopover()
    let copiedLinkPopover = NSPopover()
    var linkPasteboard: NSPasteboard = .general
    var airDropService: NSSharingService?
    var airDropHandler: ((URL) -> Void)?
    let sitePermissions: SitePermissions
    lazy var permissionCoordinator = PermissionCoordinator(browser: self)
    var sharingPicker: NSSharingServicePicker?
    let errorSurface = Surface(color: NSColor(hex: 0xFDFCFC))
    let errorTitle = label("This page couldn’t be opened", size: 23, weight: .semibold)
    let errorMessage = label("", size: 13, color: .secondaryLabelColor)
    var retryButton: NSButton!
    let dismissArea = DismissView()
    let palette = AddressPalette()
    let grip = SidebarGrip()
    /// One find bar per tab, so a search or question stays with the page it was made on.
    var findBars: [UUID: FindBar] = [:]
    /// Stands in while no tab is selected.
    let tablessFindBar = FindBar()
    var sidebar: SidebarView!
    let toolbarHost = NativeTitlebarControls()
    let toolbarAccessory = NSTitlebarAccessoryViewController()
    var toolbarButtons: [ChromeButton] = []
    var devButtons: [ChromeButton] = []
    lazy var pageCloth: PageClothTransition = {
        let transition = PageClothTransition(theme: { [weak self] in self?.theme ?? .neutral })
        transition.updateFrame = { [weak self] web, pull, forward in self?.updateClothFrame(for: web, pull: pull, forward: forward) }
        transition.resetFrame = { [weak self] in self?.resetClothFrame() }
        return transition
    }()
    lazy var historySwipe: HistorySwipeController = {
        let controller = HistorySwipeController(window: window as! BrowserWindow, pageAt: { [weak self] event in
            self?.historyPage(at: event)
        }, feedback: { [weak self] direction, pull, armed, release in
            guard let self, let direction, let arrow = self.toolbarButtons[direction == .back ? 1 : 2] as? HistoryArrowButton else { return }
            if let committed = release { arrow.release(committed: committed) }
            else { arrow.drag(pull: pull, armed: armed) }
        })
        controller.prepareCloth = { [weak self] web in
            guard let self else { return }
            self.developerMotion.cancel(); self.layoutChrome()
            self.pageCloth.prepare(web)
        }
        controller.dragCloth = { [weak self] web, direction, distance in
            self?.hideLinkStatus(); self?.pageCloth.drag(web, direction: direction, distance: distance)
        }
        controller.releaseCloth = { [weak self] distance, committed, cancelled in
            self?.pageCloth.release(distance: distance, committed: committed, cancelled: cancelled)
        }
        controller.cancelCloth = { [weak self] in self?.pageCloth.cancel() }
        controller.isPeekPage = { [weak self] web in self?.peekTab?.webView === web }
        controller.dragPeek = { [weak self] pull in self?.dragPeek(pull: pull) }
        controller.releasePeek = { [weak self] committed in
            if committed { self?.closePeek(animated: true) } else { self?.returnPeekFromSwipe() }
        }
        controller.cancelPeek = { [weak self] in self?.returnPeekFromSwipe() }
        return controller
    }()
    var tabs: [BrowserTab] = []
    var selectedID: UUID?
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var closedTabs: [SavedTab] = []
    let browsingHistory: BrowsingHistory
    let suggestionFavicons: SuggestionFavicons
    let googleSearchSuggestions: GoogleSearchSuggestions
    var theme: RiseTheme = .neutral
    var sidebarWidth = SidebarWidth.ideal
    var sidebarVisible = true
    let sidebarPeek = SidebarPeek()
    var paletteCreatesTab = false
    var splitGroups: [SplitTabGroup] = []
    var peekSourceTabID: UUID?
    var peekOpensNewTab = false
    var peekSwipePull: Double = 0
    var peekTab: BrowserTab?
    var peekBackdrop: Surface?
    var peekCard: Surface?
    var peekControls: [ChromeButton] = []
    var peekOrigin: PeekOrigin?
    var peekMotionToken: UUID?
    var peekLeftovers: [NSView] = []
    var peekStandby: (url: URL, tab: BrowserTab)?
    let peekStandbyView = PeekStandbyView()
    var peekStandbyWork: DispatchWorkItem?
    var peekStandbyExpiry: DispatchWorkItem?
    var downloadFlight: DownloadFlightView?
    /// Downloads save here without asking; tests point it elsewhere.
    var downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var pendingDownloads: [ObjectIdentifier: WKDownload] = [:]
    lazy var downloads = DownloadList(storeURL: sessionURL.deletingLastPathComponent().appendingPathComponent("downloads.json"))
    let downloadsPopover = NSPopover()
    /// The download Quick Look is showing, while Rise controls the preview panel.
    var quickLookURL: URL?
    /// The row to restore when the download's Quick Look panel closes.
    var quickLookDownloadID: UUID?
    var saveWork: DispatchWorkItem?
    let sessionURL: URL
    let preferences: UserDefaults
    var lastSaved: BrowserSession?
    var errorWebView: WKWebView?
    let adBlocker: AdBlocker
    var blockingChangeGeneration = 0
    let linkPreloader: LinkPreloader
    let tabSwitcher = TabSwitcherView()
    let tabSwitchBackdrop = PeekBackdrop(color: NSColor.black.withAlphaComponent(0.08))
    var recentTabIDs: [UUID] = []
    var tabSwitchOrder: [UUID] = []
    var tabSwitchIndex = 0
    var tabSwitchWork: DispatchWorkItem?
    var tabSwitchGeneration = 0
    var pendingMiddleTabID: UUID?

    init(sessionURL: URL? = nil, restore: Bool = true, preferences: UserDefaults = .standard, searchSuggestions: GoogleSearchSuggestions? = nil) {
        self.preferences = preferences
        googleSearchSuggestions = searchSuggestions ?? GoogleSearchSuggestions()
        sitePermissions = SitePermissions(preferences: preferences)
        adBlocker = AdBlocker(preferences: preferences)
        linkPreloader = LinkPreloader(preferences: preferences)
        let sessionURL = sessionURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rise/session.json")
        self.sessionURL = sessionURL
        browsingHistory = BrowsingHistory(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("history.json"))
        suggestionFavicons = SuggestionFavicons(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("suggestion-icons.json"))
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1496, height: 944), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        googleSearchSuggestions.onLoad = { [weak self] query in
            guard let self, self.palette.isPresented, self.palette.query.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                  (self.palette.input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            self.palette.replaceSuggestions(self.suggestions(for: query))
        }
        suggestionFavicons.onVariantLoad = { [weak self] origin, image, dark in
            guard let self else { return }
            for tab in self.tabs where SitePermissions.origin(tab.url) == origin {
                if dark { tab.darkFavicon = image }
                else { tab.iconTask?.cancel(); tab.iconTask = nil; tab.iconOrigin = origin; tab.favicon = image }
            }
            if let icon = self.suggestionFavicons.image(for: URL(string: origin), fetch: false, dark: self.theme == .dark) {
                self.palette.updateFavicon(icon, origin: origin)
            }
            self.update()
        }
        window.tabSwitchEvent = { [weak self] event in self?.handleTabSwitchEvent(event) ?? false }
        window.addressPaletteEvent = { [weak self] event in self?.palette.handleKeyEquivalent(event) ?? false }
        window.pageMouseDown = { [weak self] event in self?.focusSplitPage(at: event) }
        window.historyScrollEvent = { [weak self] event in self?.historySwipe.handle(event) ?? false }
        window.otherMouseEvent = { [weak self] event in self?.handleMiddleTabClick(event) ?? false }
        window.modifiersChanged = { [weak self] flags in self?.updateHoveredLinkModifiers(flags); self?.sidebarPeekModifiersChanged(flags) }
        window.pointerMoved = { [weak self] event in self?.updateHoveredLinkCursor(event) }
        tabSwitcher.choose = { [weak self] id in self?.commitTabSwitch(id) }
        tabSwitchBackdrop.dismiss = { [weak self] in self?.cancelTabSwitch() }
        tabSwitchBackdrop.isHidden = true
        linkPreloader.prepareWebView = { [weak self] web in self?.adBlocker.install(on: web) }
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
        // Escape belongs to the find bar while open, including key up and repeated key down.
        var swallowingEscape = false
        window.escapeEvent = { [weak self] event in
            guard let self else { return false }
            if event.type == .keyUp { defer { swallowingEscape = false }; return swallowingEscape }
            // Held Escape belongs to the same gesture even after the bar begins closing.
            if swallowingEscape && event.isARepeat { return true }
            guard self.findBar.isPresented, self.palette.isHidden, !self.isSwitchingTabs, self.sidebar.drag == nil else { return false }
            swallowingEscape = true; self.findBar.handleEscape(); return true
        }
        window.escapeAction = { [weak self] in
            guard let self else { return false }
            if self.sidebar.drag != nil { self.sidebar.cancelTabInteractions(); return true }
            if self.isSwitchingTabs { self.cancelTabSwitch(); return true }
            if !self.palette.isHidden { self.hidePalette(); return true }
            if self.findBar.isPresented { self.findBar.handleEscape(); return true }
            if self.peekTab != nil { self.closePeek(animated: true); return true }
            return false
        }
        buildChrome()
        if restore, let saved = SessionStorage.read(from: self.sessionURL) {
            theme = RiseTheme(rawValue: saved.theme) ?? .neutral
            sidebarWidth = min(SidebarWidth.range.upperBound, max(SidebarWidth.range.lowerBound, saved.sidebarWidth))
            tabs = saved.tabs.map { configure(BrowserTab(saved: $0)) }
            // Old sessions can fill their missing icons without loading every page.
            tabs.forEach { $0.updateIcon() }
            splitGroups = saved.splitGroups
            selectedID = saved.selectedID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
        }
        if let selectedID { select(selectedID) }
        update(); layoutChrome()
    }
    required init?(coder: NSCoder) { fatalError() }
    func buildChrome() {
        sidebar = SidebarView(copy: { [weak self] in self?.copyURL() }, settings: { [weak self] in self?.siteMenu() }, archive: { [weak self] in self?.showDownloads() }, theme: { [weak self] in self?.themeMenu() })
        sidebar.onAddress = { [weak self] in self?.focusAddress() }
        // Recently closed tabs stay one right-click away on the downloads button.
        sidebar.archiveButton.secondaryAction = { [weak self] in self?.archiveMenu() }
        sidebar.onNewTab = { [weak self] in self?.newTab() }
        sidebar.onSelect = { [weak self] id in self?.select(id) }
        sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        sidebar.onTabMenu = { [weak self] id, event in self?.tabMenu(id, event: event) }
        sidebar.onReorder = { [weak self] in self?.reorderTabs($0) }
        sidebar.onRename = { [weak self] id, title in self?.renameTab(id, title: title) }
        pageShadow.layer?.cornerCurve = .continuous; pageClip.layer?.cornerCurve = .continuous
        pageShadow.shadow = chromeShadow(opacity: PageAppearance.shadowOpacity, blur: PageAppearance.shadowBlur, offset: PageAppearance.shadowOffset)
        pageClip.layer?.masksToBounds = true; pageClip.clipsToBounds = true
        root.addSubview(sidebar); root.addSubview(pageShadow); pageShadow.addSubview(pageClip)
        pageClip.addSubview(emptyPage); pageClip.addSubview(developerBar)
        root.addSubview(grip)
        grip.resize = { [weak self] x in self?.resizeSidebar(to: x) }
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
            if symbol == "arrow.clockwise" { button.image = NavigationIcon.reload }
            toolbarHost.addSubview(button); toolbarButtons.append(button)
        }
        developerAddress.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        developerAddress.textColor = NSColor(hex: 0x393134); developerBar.addSubview(developerAddress)
        developerAddress.onSubmit = { [weak self] text in self?.navigateDeveloperAddress(text) }
        developerAddress.onCancel = { [weak self] in self?.window?.makeFirstResponder(self?.selectedTab?.webView) }
        siteInfoPopover.behavior = .transient
        downloadsPopover.behavior = .transient
        siteControlsPopover.behavior = .transient
        siteControlsPopover.delegate = self
        copiedLinkPopover.behavior = .transient
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
        dismissArea.protectedView = palette
        dismissArea.dismiss = { [weak self] in self?.hidePalette() }; dismissArea.isHidden = true
        root.addSubview(linkStatus); root.addSubview(dismissArea); root.addSubview(palette)
        palette.dismiss = { [weak self] in self?.hidePalette() }
        palette.queryChanged = { [weak self] text in self?.suggestions(for: text) ?? [] }
        palette.submit = { [weak self] text, suggestion in self?.submitAddress(text, suggestion: suggestion) }
        palette.switchToTab = { [weak self] id in
            guard let self, self.tabs.contains(where: { $0.id == id }) else { return }
            self.hidePalette(); self.select(id)
        }
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
    }
    func layoutChrome() {
        // AppKit can deliver a resize while restoring the window, before its
        // sidebar and titlebar controls have finished being constructed.
        guard let window, let sidebar else { return }; let b = root.bounds
        root.fill = theme.background; root.gradientColors = theme.backgroundGradient; window.backgroundColor = theme.background
        let width = displayedSidebarWidth, sw = sidebarVisible ? width : 0
        sidebar.isHidden = !sidebarVisible; sidebar.frame = NSRect(x: 0, y: 0, width: width, height: b.height)
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
        toolbarHost.frame.size.width = sidebarVisible ? max(112, width-toolbarX-8) : 28
        toolbarHost.layout()
        pageShadow.frame = PageAppearance.frame(in: b, sidebarWidth: sw, sidebarVisible: sidebarVisible)
        pageShadow.refreshOutline()
        pageClip.frame = pageShadow.bounds
        // The peek width is temporary, so it can't be resized.
        grip.frame = NSRect(x: sw-3, y: 44, width: 6, height: b.height-88); grip.isHidden = !sidebarVisible || sidebarPeek.progress > 0
        let cb = pageClip.bounds
        let devHeight = developerMotion.height(for: selectedID, enabled: selectedTab?.developer == true)
        developerBar.frame = NSRect(x: 0, y: devHeight-DeveloperModeMotion.headerHeight, width: cb.width, height: DeveloperModeMotion.headerHeight)
        developerBar.isHidden = devHeight == 0
        let addressHeight = developerAddress.intrinsicContentSize.height
        developerAddress.frame = NSRect(x: 18, y: (DeveloperModeMotion.headerHeight-addressHeight)/2, width: max(100, cb.width-270), height: addressHeight)
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
        findBar.frame = pageShadow.frame; findBar.topInset = devHeight
        dismissArea.frame = b
        let paletteWidth: CGFloat = paletteCreatesTab ? 520 : 600
        if sidebarVisible {
            let paletteOrigin = NSPoint(x: sidebar.address.frame.minX, y: sidebar.address.frame.minY-2)
            palette.place(at: paletteOrigin, width: min(paletteWidth, b.width-paletteOrigin.x-8))
        } else {
            let centeredWidth: CGFloat = paletteCreatesTab ? 640 : paletteWidth
            palette.place(centeredAt: NSPoint(x: b.midX, y: b.midY), width: min(centeredWidth, b.width-16))
        }
        layoutPeek()
        layoutLinkStatus()
        tabSwitchBackdrop.frame = b
        if !tabSwitcher.isHidden { tabSwitcher.place(in: b) }
    }
    func windowDidResize(_ notification: Notification) { layoutChrome() }
    func windowWillClose(_ notification: Notification) { googleSearchSuggestions.cancel(); quickLookDownloadID = nil; developerMotion.cancel(); sidebar.cancelTabInteractions(); historySwipe.cancel(); siteInfoPopover.close(); siteControlsPopover.close(); copiedLinkPopover.close(); permissionCoordinator.cancel(); cancelTabSwitch(); saveNow() }
    func windowDidResignKey(_ notification: Notification) {
        pendingMiddleTabID = nil; historySwipe.cancel(); cancelTabSwitch(); endSidebarPeek()
        sidebar?.cancelTabInteractions()
        DispatchQueue.main.async { [weak self] in
            guard let self, !NSApp.isActive else { return }
            for tab in self.tabs where self.visibleTabIDs.contains(tab.id) { tab.webView.evaluateJavaScript("window.riseSiteControls?.autoPiP()") { _, _ in } }
        }
    }
    func configure(_ tab: BrowserTab) -> BrowserTab {
        tab.webView.navigationDelegate = self; tab.webView.uiDelegate = self
        tab.webView.appearance = theme.appearance; tab.webView.underPageBackgroundColor = theme.page
        adBlocker.install(on: tab.webView)
        tab.prepareForLoad = { [weak self] web in try await self?.adBlocker.prepare(web) }
        tab.onLoadError = { [weak self, weak tab] error in
            if let tab { self?.showNavigationError(error, in: tab.webView) }
        }
        linkPreloader.install(on: tab.webView)
        permissionCoordinator.install(on: tab.webView)
        suggestionFavicons.remember(tab)
        tab.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.suggestionFavicons.remember(tab)
            if !tab.webView.isLoading, let url = tab.webView.url, let title = tab.webView.title {
                self.browsingHistory.updateTitle(title, for: url)
            }
            self.update()
        }
        tab.onThumbnailChange = { [weak self] in self?.refreshTabSwitcher() }
        return tab
    }
    @discardableResult func addTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = configure(BrowserTab(configuration: configuration)); tabs.insert(tab, at: 0); select(tab.id)
        if let url { tab.load(url) }; return tab
    }
    func select(_ id: UUID) {
        historySwipe.cancel()
        cancelTabSwitch()
        siteInfoPopover.close()
        siteControlsPopover.close(); copiedLinkPopover.close(); permissionCoordinator.cancel()
        if selectedID != id { selectedTab?.captureThumbnail() }
        hideLinkStatus()
        hidePalette(); closePeek()
        let previousID = selectedID
        selectedID = id
        swapFindBar(from: previousID)
        attachVisiblePages()
        recentTabIDs.removeAll { $0 == id }; recentTabIDs.insert(id, at: 0)
        if let tab = selectedTab {
            window?.makeFirstResponder(tab.webView)
        }
        update(); layoutChrome()
        findBar.reattached()
    }
    func update() {
        applyTheme()
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: splitGroups)
        window?.title = (selectedTab?.title).map { "\($0) — Rise" } ?? "Rise"
        toolbarButtons[1].isEnabled = selectedTab?.webView.canGoBack ?? false
        toolbarButtons[2].isEnabled = selectedTab?.webView.canGoForward ?? false
        toolbarButtons[3].image = selectedTab?.isLoading == true ? NavigationIcon.stop : NavigationIcon.reload
        developerAddress.updateURL(selectedTab?.url?.absoluteString ?? "")
        errorSurface.isHidden = errorWebView == nil || errorWebView !== selectedTab?.webView
        layoutChrome(); refreshTabSwitcher(); scheduleSave()
    }
    @objc func newTab() { paletteCreatesTab = true; showPalette(text: "") }
    @objc func focusAddress() { paletteCreatesTab = false; showPalette(text: selectedTab?.url?.absoluteString == "about:blank" ? "" : selectedTab?.url?.absoluteString ?? "") }
    func showPalette(text: String) { historySwipe.cancel(); cancelTabSwitch(); hideLinkStatus(); siteControlsPopover.close(); copiedLinkPopover.close(); permissionCoordinator.cancel(); dismissArea.isHidden = false; palette.show(text: text, theme: theme, createsTab: paletteCreatesTab); layoutChrome() }
    func hidePalette() { googleSearchSuggestions.cancel(); suggestionFavicons.cancelPreview(); guard palette.isPresented else { return }; palette.hide(); dismissArea.isHidden = true; window?.makeFirstResponder(selectedTab?.webView) }
    func submitAddress(_ text: String, suggestion: AddressSuggestion?) {
        hidePalette()
        if let command = suggestion?.command {
            switch command {
            case "Toggle Developer Mode": toggleDeveloper()
            case "Change Theme": toggleTheme()
            case "Toggle Sidebar": toggleSidebar()
            case "Split View": toggleSplit()
            default: break
            }; return
        }
        guard let url = suggestion?.url ?? AddressResolver.resolve(text, searchEngine: searchEngine) else { return }
        // Resolve again at activation time: an open tab may have navigated or
        // closed since the result was built. Never create an exact duplicate.
        if let existing = openTab(for: url) { select(existing.id); return }
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
        if selectedID == id { copiedLinkPopover.close() }
        let tab = tabs.remove(at: index); closedTabs.append(tab.saved)
        permissionCoordinator.cancel(for: tab.webView)
        recentTabIDs.removeAll { $0 == id }
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        tab.cancelLoad(); tab.webView.removeFromSuperview()
        findBars.removeValue(forKey: id)?.discard()
        if selectedID == id {
            selectedID = nil
            if let partner, tabs.contains(where: { $0.id == partner }) { select(partner) }
            else if !tabs.isEmpty { select(tabs[min(index, tabs.count-1)].id) }
        }
        attachVisiblePages(); update()
    }
    @objc func reopenTab() { guard let saved = closedTabs.popLast() else { return }; let tab = configure(BrowserTab(saved: saved)); tabs.insert(tab, at: 0); select(tab.id) }
    @objc func goBack() { navigateHistory(.back) }
    @objc func goForward() { navigateHistory(.forward) }
    private func navigateHistory(_ direction: HistoryDirection) {
        // Buttons/menu shortcuts use WebKit directly. Remove any in-flight
        // swipe surface and arrow spring before navigation starts.
        historySwipe.cancel()
        developerMotion.cancel()
        toolbarButtons.compactMap { $0 as? HistoryArrowButton }.forEach { $0.restore() }
        errorWebView = nil
        if let tab = selectedTab, direction == .back ? tab.webView.canGoBack : tab.webView.canGoForward {
            tab.cancelLoad()
            if direction == .back { tab.webView.goBack() } else { tab.webView.goForward() }
        }
        update()
    }
    @objc func reload() { historySwipe.cancel(); errorWebView = nil; if selectedTab?.isLoading == true { selectedTab?.cancelLoad() } else if let tab = selectedTab, tab.webView.url == nil, let url = tab.requestedURL { tab.load(url) } else { selectedTab?.webView.reload() }; update() }
    @objc func retry() { errorWebView = nil; if let url = selectedTab?.url { selectedTab?.load(url) }; update() }
    @objc func toggleSidebar() {
        if keepPeekedSidebar() { return }
        hidePalette()
        siteControlsPopover.close(); copiedLinkPopover.close(); permissionCoordinator.cancel()
        sidebarVisible.toggle()
        if !sidebarVisible { sidebar.newTab.resetHover() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutChrome(); root.layoutSubtreeIfNeeded()
        CATransaction.commit()
    }
    @objc func toggleDeveloper() {
        guard let tab = selectedTab else { return }
        toggleDeveloperMode(for: tab)
    }
    func toggleDeveloperMode(for tab: BrowserTab) {
        let visible = tab.id == selectedID
        if visible {
            historySwipe.cancel()
            window?.makeFirstResponder(tab.webView); siteInfoPopover.close()
        }
        let from = visible ? developerMotion.height(for: tab.id, enabled: tab.developer) : 0
        tab.developer.toggle()
        if visible {
            developerMotion.start(tabID: tab.id, from: from, enabled: tab.developer, animated: window?.isVisible == true)
        }
        update()
    }
    @objc func toggleTheme() {
        let themes = RiseTheme.allCases
        theme = themes[((themes.firstIndex(of: theme) ?? 0) + 1) % themes.count]; update()
    }
    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    func cycleTab(_ direction: Int) { guard !tabs.isEmpty else { return }; let index = tabs.firstIndex { $0.id == selectedID } ?? 0; select(tabs[(index+direction+tabs.count)%tabs.count].id) }
    @objc func zoomIn() { selectedTab?.webView.pageZoom = min(3, (selectedTab?.webView.pageZoom ?? 1)+0.1) }
    @objc func zoomOut() { selectedTab?.webView.pageZoom = max(0.3, (selectedTab?.webView.pageZoom ?? 1)-0.1) }
    @objc func actualSize() { selectedTab?.webView.pageZoom = 1 }
    func scheduleSave() {
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.saveNow() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: work)
    }
    func saveNow() {
        suggestionFavicons.save()
        do { try browsingHistory.save() }
        catch { NSLog("Rise history save failed: %@", error.localizedDescription) }
        let state = BrowserSession(tabs: tabs.map(\.saved), selectedID: selectedID, theme: theme.rawValue, sidebarWidth: sidebarWidth, splitGroups: splitGroups)
        guard state != lastSaved else { return }
        do { try SessionStorage.write(state, to: sessionURL); lastSaved = state }
        catch { NSLog("Rise session save failed: %@", error.localizedDescription) }
    }
}
