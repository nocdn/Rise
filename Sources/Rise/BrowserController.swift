import AppKit
import RiseCore

@MainActor final class BrowserController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    let root = Surface()
    let pageShadow = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let pageClip = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let emptyPage = Surface(color: NSColor(hex: 0xFDFCFC))
    let linkStatus = LinkStatusPill()
    /// The page whose link is under the pointer, as its view.
    weak var hoveredWebView: NSView?
    let developerBar = DeveloperHeader(color: NSColor(hex: 0xFCF6F7))
    let developerAddress = DeveloperAddressField(frame: .zero)
    lazy var developerMotion = DeveloperModeMotion { [weak self] in self?.layoutChrome() }
    let siteInfoPopover = NSPopover()
    let siteControlsPopover = NSPopover()
    /// The camera button's JPEG and PDF.
    let capturePopover = NSPopover()
    var linkPasteboard: NSPasteboard = .general
    var airDropService: NSSharingService?
    var airDropHandler: ((URL) -> Void)?
    let sitePermissions: SitePermissions
    lazy var permissionCoordinator = PermissionCoordinator(browser: self)
    lazy var pictureInPicture = VideoPictureInPicture(browser: self)
    lazy var tabMedia: TabMedia = {
        let media = TabMedia(browser: self)
        media.onChange = { [weak self] id in self?.refreshPlayback(id) }
        return media
    }()
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
    let infoPlaque = InfoPlaque()
    var sidebar: SidebarView!
    let toolbarHost = NativeTitlebarControls()
    let toolbarAccessory = NSTitlebarAccessoryViewController()
    var toolbarButtons: [ChromeButton] = []
    var devButtons: [ChromeButton] = []
    lazy var historySwipe: HistorySwipeController = {
        let controller = HistorySwipeController(window: window as! BrowserWindow, pageAt: { [weak self] event in
            self?.historyPage(at: event)
        }, feedback: { [weak self] direction, pull, armed, release in
            guard let self, let direction, let arrow = self.toolbarButtons[direction == .back ? 1 : 2] as? HistoryArrowButton else { return }
            if let committed = release { arrow.release(committed: committed) }
            else { arrow.drag(pull: pull, armed: armed) }
        })
        controller.canNavigate = { [weak self] page, direction in self?.canNavigate(page, direction) ?? false }
        controller.navigate = { [weak self] page, direction in self?.navigate(page, direction) }
        controller.isPeekPage = { [weak self] page in self?.peekTab?.page === page }
        controller.dragPeek = { [weak self] pull in self?.dragPeek(pull: pull) }
        controller.releasePeek = { [weak self] committed in
            if committed { self?.closePeek(animated: true) } else { self?.returnPeekFromSwipe() }
        }
        controller.cancelPeek = { [weak self] in self?.returnPeekFromSwipe() }
        return controller
    }()
    var tabs: [BrowserTab] = [] { didSet { extensionTabsChanged() } }
    var selectedID: UUID? { didSet { extensionTabsChanged() } }
    /// The window as Chrome extensions see it (`ExtensionWindow`).
    var extensionWindow: AnyObject?
    /// The extension popup that's open, if any.
    var extensionPopup: ExtensionPopup?
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var closedTabs: [SavedTab] = []
    let browsingHistory: BrowsingHistory
    let siteSearchLearner: SiteSearchLearner
    let suggestionFavicons: SuggestionFavicons
    let googleSearchSuggestions: GoogleSearchSuggestions
    var theme: RiseTheme = .neutral
    /// Follows macOS's appearance, Light by day and Dark by night when macOS
    /// itself is set to Auto, instead of keeping one chosen theme.
    var automaticTheme = false
    var systemAppearanceObservation: NSKeyValueObservation?
    var sidebarWidth = SidebarWidth.ideal
    var sidebarVisible = true
    let sidebarPeek = SidebarPeek()
    let sidebarFloat = SidebarFloat()
    let devTools = DevToolsPanel()
    lazy var tabHoverCards: TabHoverCards = {
        let hover = TabHoverCards(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("pr-summaries.json"))
        hover.summaries.onChange = { [weak self] key in self?.pullRequestSummaryChanged(key) }
        hover.summaries.provider = { [weak self] in self?.modelChoice ?? .openRouter }
        return hover
    }()
    lazy var gmailInbox: GmailInbox = {
        let inbox = GmailInbox()
        inbox.onChange = { [weak self] in self?.gmailInboxChanged() }
        return inbox
    }()
    var paletteCreatesTab = false
    var splitGroups: [SplitTabGroup] = []
    var peekSourceTabID: UUID?
    var peekOpensNewTab = false
    var peekSwipePull: Double = 0
    var peekTab: BrowserTab?
    var peekBackdrop: Surface?
    var peekCard: Surface?
    var peekControls: [PeekControl] = []
    /// ⌘Z puts a Peek that became a tab or a split back, for a short while.
    var peekUndo: PeekUndo?
    /// The divider can restore its original Peek even after the keyboard undo window expires.
    var splitPeekReturns: [UUID: PeekUndo] = [:]
    /// Waiting for the Peek's snapshot before it grows into the page.
    var isPromotingPeek = false
    var peekPromotion: PeekPromotion?
    /// The Peek card moving frame by frame with its live page inside, when Live Peek Resize is on.
    var peekLiveMotion: PeekLiveMotion?
    /// The pill between split pages, which drags the split.
    let splitHandle = SplitHandle()
    /// The split springing back to the middle after a double click on its handle.
    var splitMotion: PeekLiveMotion?
    /// The page area below the developer bar, as last laid out.
    var pageBody = NSRect.zero
    /// An animation is placing the pages itself, so layout leaves them where it put them.
    var pageLayoutHeld = false
    /// A Shift- or Option-click that opened a Peek: the rest of it stays from the page.
    var takesLinkClick = false
    var peekOrigin: PeekOrigin?
    var peekMotionToken: UUID?
    var peekLeftovers: [NSView] = []
    /// A pill hide held back while a Shift-click inside the Peek may still be refused.
    var refusedPeekHide: DispatchWorkItem?
    var peekStandby: (url: URL, tab: BrowserTab)?
    let peekStandbyView = PeekStandbyView()
    var peekStandbyWork: DispatchWorkItem?
    var peekStandbyExpiry: DispatchWorkItem?
    var downloadFlight: DownloadFlightView?
    /// Downloads save here without asking; tests point it elsewhere.
    var downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    lazy var downloads = DownloadList(storeURL: sessionURL.deletingLastPathComponent().appendingPathComponent("downloads.json"))
    let downloadsPopover = NSPopover()
    /// The download Quick Look is showing, while Rise controls the preview panel.
    var quickLookURL: URL?
    /// The row to restore when the download's Quick Look panel closes.
    var quickLookDownloadID: UUID?
    var saveWork: DispatchWorkItem?
    let sessionURL: URL
    let preferences: UserDefaults
    let aiKeys = AIKeys()
    /// Shows a page's menu at a point in its view; replaced in tests, as the menu tracks modally.
    var presentContextMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    var lastSaved: BrowserSession?
    var tabSync: SharedTabsSync?
    var isApplyingSharedTabs = false
    var hasPendingSharedTabs = false
    /// The page, as its view, whose load failed.
    var errorWebView: NSView?
    let adBlocker: AdBlocker
    var blockingChangeGeneration = 0
    let linkPreloader: LinkPreloader
    let pageFullscreen: PageFullscreen
    /// The docked sidebar's state before the visible page entered simulated fullscreen.
    var fullscreenSidebarWasVisible: Bool?
    let tabSwitcher = TabSwitcherView()
    let tabSwitchBackdrop = PeekBackdrop(color: NSColor.black.withAlphaComponent(0.08))
    var recentTabIDs: [UUID] = []
    var tabSwitchOrder: [UUID] = []
    var tabSwitchIndex = 0
    var tabSwitchWork: DispatchWorkItem?
    var tabSwitchGeneration = 0
    var pendingMiddleTabID: UUID?

    init(sessionURL: URL? = nil, restore: Bool = true, preferences: UserDefaults = .standard, searchSuggestions: GoogleSearchSuggestions? = nil) {
        let syncTabs = sessionURL == nil && restore && Bundle.main.bundleIdentifier == "dev.bartosz.Rise"
        self.preferences = preferences
        googleSearchSuggestions = searchSuggestions ?? GoogleSearchSuggestions()
        sitePermissions = SitePermissions(preferences: preferences)
        adBlocker = AdBlocker(preferences: preferences)
        linkPreloader = LinkPreloader(preferences: preferences)
        pageFullscreen = PageFullscreen(preferences: preferences)
        let sessionURL = sessionURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rise/session.json")
        self.sessionURL = sessionURL
        browsingHistory = BrowsingHistory(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("history.json"))
        siteSearchLearner = SiteSearchLearner(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("searches.json"))
        suggestionFavicons = SuggestionFavicons(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("suggestion-icons.json"))
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1496, height: 944), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        pageFullscreen.onChange = { [weak self] in self?.reconcileFullscreenSidebar() }
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
        window.undoEvent = { [weak self] event in
            guard let self else { return false }
            return self.palette.handleUndoKey(event) || self.handlePeekUndoKey(event)
        }
        window.smartRenameEvent = { [weak self] event in self?.handleSmartRenameKey(event) ?? false }
        window.extensionShortcutEvent = { [weak self] event in self?.runExtensionShortcut(event) ?? false }
        window.pageMouseDown = { [weak self] event in self?.focusSplitPage(at: event) }
        window.linkClickEvent = { [weak self] event in self?.takeLinkClick(event) ?? false }
        window.historyScrollEvent = { [weak self] event in self?.historySwipe.handle(event) ?? false }
        window.otherMouseEvent = { [weak self] event in self?.handleMiddleTabClick(event) ?? false }
        window.modifiersChanged = { [weak self] flags in self?.updateHoveredLinkModifiers(flags); self?.sidebarPeekModifiersChanged(flags) }
        window.pointerMoved = { [weak self] event in
            self?.sidebar.refreshReturningTabHover(at: event.locationInWindow)
            self?.tabHoverPointerMoved()
        }
        tabSwitcher.choose = { [weak self] id in self?.commitTabSwitch(id) }
        tabSwitchBackdrop.dismiss = { [weak self] in self?.cancelTabSwitch() }
        tabSwitchBackdrop.isHidden = true
        linkPreloader.loadPage = { url, page, done in
            guard page is ChromiumPage else { return nil }
            let preload = ChromiumPreload(url, size: page.view.bounds.size, done: done)
            return { preload.cancel() }
        }
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
            if !self.palette.isHidden {
                // Out of a site's search first, back to the address.
                if self.palette.siteSearch != nil { self.palette.leaveSiteSearch(); self.window?.makeFirstResponder(self.palette.input) }
                else { self.hidePalette() }
                return true
            }
            if self.findBar.isPresented { self.findBar.handleEscape(); return true }
            if self.peekTab != nil { self.closePeek(animated: true); return true }
            return false
        }
        buildChrome()
        if restore, let saved = SessionStorage.read(from: self.sessionURL) {
            if saved.theme == Self.automaticThemeName { automaticTheme = true; theme = systemTheme() }
            else { theme = RiseTheme(rawValue: saved.theme) ?? .neutral }
            sidebarWidth = SidebarWidth.previousIdeals.contains(saved.sidebarWidth) ? SidebarWidth.ideal
                : min(SidebarWidth.range.upperBound, max(SidebarWidth.range.lowerBound, saved.sidebarWidth))
            tabs = saved.tabs.map { configure(BrowserTab(saved: $0)) }
            // Old sessions can fill their missing icons without loading every page.
            tabs.forEach { $0.updateIcon() }
            splitGroups = saved.splitGroups
            selectedID = saved.selectedID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
        }
        if let selectedID { select(selectedID) }
        update(); layoutChrome()
        if syncTabs { startTabSync() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func buildChrome() {
        sidebar = SidebarView(copy: { [weak self] in self?.copyURL() }, settings: { [weak self] in self?.siteMenu() }, archive: { [weak self] in self?.showDownloads() }, cleanUp: { [weak self] in self?.cleanUpTabs() })
        sidebar.onAddress = { [weak self] in self?.focusAddress() }
        // Recently closed tabs stay one right-click away on the downloads button.
        sidebar.archiveButton.secondaryAction = { [weak self] in self?.archiveMenu() }
        sidebar.onNewTab = { [weak self] in self?.newTab() }
        sidebar.onSelect = { [weak self] id in self?.select(id) }
        sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        sidebar.onTabMenu = { [weak self] id, event in self?.tabMenu(id, event: event) }
        sidebar.onReorder = { [weak self] in self?.reorderTabs($0) }
        sidebar.onRename = { [weak self] id, title in self?.renameTab(id, title: title) }
        sidebar.onTabHover = { [weak self] id, hovering in self?.tabHoverChanged(id, hovering: hovering) }
        sidebar.playbackState = { [weak self] id in self?.playbackPaused(id) }
        sidebar.onTogglePlayback = { [weak self] id in self?.togglePlayback(id) }
        sidebar.onToggleMute = { [weak self] id in
            if let tab = self?.tabs.first(where: { $0.id == id }) { tab.setAudioMuted(!tab.isAudioMuted) }
        }
        sidebar.onTabPress = { [weak self] in self?.tabPressed() }
        pageShadow.layer?.cornerCurve = .continuous; pageClip.layer?.cornerCurve = .continuous
        pageShadow.shadow = chromeShadow(opacity: PageAppearance.shadowOpacity, blur: PageAppearance.shadowBlur, offset: PageAppearance.shadowOffset)
        pageClip.layer?.masksToBounds = true; pageClip.clipsToBounds = true
        root.addSubview(sidebar); root.addSubview(pageShadow); pageShadow.addSubview(pageClip); installSplitHandle()
        pageClip.addSubview(emptyPage); pageClip.addSubview(developerBar)
        installSidebarEdge()
        installDevTools()
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
            } else if symbol == "arrow.clockwise" {
                button = ReloadButton(title: title, action: action)
            } else { button = ChromeButton(symbol: symbol, size: 16, title: title, action: action) }
            toolbarHost.addSubview(button); toolbarButtons.append(button)
        }
        developerAddress.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        developerAddress.textColor = NSColor(hex: 0x393134); developerBar.addSubview(developerAddress)
        developerAddress.onSubmit = { [weak self] text in self?.navigateDeveloperAddress(text) }
        developerAddress.onCancel = { [weak self] in self?.window?.makeFirstResponder(self?.selectedTab?.page.view) }
        siteInfoPopover.behavior = .transient
        downloadsPopover.behavior = .transient
        siteControlsPopover.behavior = .transient
        siteControlsPopover.delegate = self
        // The pages under the notice would take its button's pointer and cursor for their own links.
        infoPlaque.onPointer = { [weak self] over in
            guard let self else { return }
            if over { for tab in tabs + [peekTab].compactMap({ $0 }) { setCovered(true, tab) } }
            else { updatePeekCovers() }
        }
        let devActions: [(String, String, () -> Void)] = [
            ("link", "Copy URL", { [weak self] in self?.copyURL() }),
            ("camera", "Capture whole page", { [weak self] in if let self { self.showCaptureChoices(from: self.devButtons[1]) } }),
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
        palette.learnedSite = { [weak self] text in self?.siteSearchLearner.searches.site(forAddress: text) }
        palette.customSite = { [weak self] text in self?.siteSearchLearner.searches.customSite(forAddress: text) }
        siteSearchLearner.onLearn = { [weak self] in self?.scheduleSave() }
        palette.siteFavicon = { [weak self] url in
            guard let self else { return nil }
            return self.suggestionFavicons.image(for: url, dark: self.theme == .dark)
        }
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
        let width = displayedSidebarWidth, shown = sidebarVisible || sidebarFloat.isVisible
        sidebar.isHidden = !shown
        let pageLeft = layoutFloatingSidebar(in: b, width: width)
        // Keep the native titlebar hierarchy intact, but hide all of its chrome
        // for the edge-to-edge reading layout. No animator proxies are involved.
        if toolbarAccessory.isHidden == shown { toolbarAccessory.isHidden = !shown }
        if window.toolbar?.isVisible != shown {
            // Let AppKit place the traffic lights for the new titlebar now, before they're carried.
            window.toolbar?.isVisible = shown; window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !shown
        }
        toolbarHost.isHidden = !shown
        toolbarButtons.forEach { $0.isHidden = !shown }
        // A floating sidebar carries the traffic lights and navigation with it, as one block.
        let carry = shown ? sidebar.frame.origin : .zero
        let toolbarX = toolbarHost.convert(toolbarHost.bounds, to: root).minX
        // Room for the carried buttons, held steady while floating so the titlebar isn't resized every frame.
        let room = sidebarVisible && sidebarFloat.dockProgress == 1 ? 0 : SidebarFloatAppearance.inset
        toolbarHost.shift = carry.x; toolbarHost.room = room
        toolbarHost.frame.size.width = shown ? max(112, sidebar.frame.width-toolbarX-8)+room : 28
        carryTitlebarControls(by: carry)
        toolbarHost.layout()
        // The selected tab's DevTools take the window's right side.
        let devToolsRoom = layoutDevTools(in: b, pageLeft: pageLeft)
        pageShadow.frame = PageAppearance.frame(in: b, sidebarWidth: pageLeft, sidebarVisible: true)
        pageShadow.frame.size.width = max(0, pageShadow.frame.width-devToolsRoom)
        pageShadow.refreshOutline()
        pageClip.frame = pageShadow.bounds
        // The peek width is temporary, and a floating sidebar is never resized.
        grip.frame = NSRect(x: width-3, y: 44, width: 6, height: b.height-88)
        grip.isHidden = !sidebarVisible || sidebarPeek.progress > 0 || sidebarFloat.dockProgress < 1
        let cb = pageClip.bounds
        let devHeight = developerMotion.height(for: selectedID, enabled: selectedTab?.developer == true)
        developerBar.frame = NSRect(x: 0, y: devHeight-DeveloperModeMotion.headerHeight, width: cb.width, height: DeveloperModeMotion.headerHeight)
        developerBar.isHidden = devHeight == 0
        let addressHeight = developerAddress.intrinsicContentSize.height
        developerAddress.frame = NSRect(x: 18, y: (DeveloperModeMotion.headerHeight-addressHeight)/2, width: max(100, cb.width-270), height: addressHeight)
        devButtons.enumerated().forEach { i, button in button.frame = NSRect(x: cb.width-240+CGFloat(i)*38, y: 6, width: 30, height: 28) }
        let body = NSRect(x: 0, y: devHeight, width: cb.width, height: cb.height-devHeight)
        emptyPage.frame = body; pageBody = body
        if pageLayoutHeld {
            // An animation is placing the pages.
        } else if let group = activeSplitGroup {
            let frames = splitFrames(in: body, fraction: group.fraction)
            for (id, frame) in [(group.leftID, frames.left), (group.rightID, frames.right)] {
                if let tab = tabs.first(where: { $0.id == id }), !pictureInPicture.owns(tab), !tab.isInNativeFullscreen { tab.page.view.frame = frame }
            }
            shapePage(around: [frames.left, frames.right])
        } else {
            if let tab = selectedTab, !pictureInPicture.owns(tab), !tab.isInNativeFullscreen { tab.page.view.frame = body }
            shapePage(around: [])
        }
        layoutSplitHandle()
        errorSurface.frame = body
        errorTitle.frame = NSRect(x: 40, y: body.height/2-60, width: body.width-80, height: 34)
        errorMessage.frame = NSRect(x: 60, y: body.height/2-12, width: body.width-120, height: 56)
        retryButton.frame = NSRect(x: body.width/2-55, y: body.height/2+55, width: 110, height: 32)
        findBar.frame = pageShadow.frame; findBar.topInset = devHeight
        infoPlaque.frame = pageShadow.frame; infoPlaque.topInset = devHeight
        dismissArea.frame = b
        let paletteWidth: CGFloat = paletteCreatesTab ? 520 : 600
        if isSidebarShown {
            let address = root.convert(sidebar.address.frame, from: sidebar)
            let paletteOrigin = NSPoint(x: address.minX, y: address.minY-2)
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
    func windowWillClose(_ notification: Notification) { tabPressed(); gmailInbox.tearDown(); settleSidebarFloat(docking: false); pictureInPicture.tearDown(); googleSearchSuggestions.cancel(); quickLookDownloadID = nil; developerMotion.cancel(); sidebar.cancelTabInteractions(); historySwipe.cancel(); siteInfoPopover.close(); siteControlsPopover.close(); permissionCoordinator.cancel(); cancelTabSwitch(); saveNow() }
    func windowDidResignKey(_ notification: Notification) {
        pendingMiddleTabID = nil; historySwipe.cancel(); cancelTabSwitch(); endSidebarPeek(); tabPressed()
        sidebar?.cancelTabInteractions()
        DispatchQueue.main.async { [weak self] in
            guard let self, !NSApp.isActive else { return }
            for tab in self.tabs where self.visibleTabIDs.contains(tab.id) {
                tab.page.evaluate("window.riseSiteControls?.autoPiP()", arguments: [:], in: nil, world: .page) { _ in }
            }
        }
    }
    func configure(_ tab: BrowserTab) -> BrowserTab {
        // The page reports hovers, new tabs and its menu.
        // The page, not the tab, is captured: it can move to another tab when a Peek becomes one.
        let page = tab.page
        page.onHoverLink = { [weak self, weak page] url in
            guard let self, let page else { return }
            self.showHoveredLink(url, in: page.view)
        }
        page.onOpenElsewhere = { [weak self, weak page] url, background in
            guard let self else { return false }
            // Chrome's own pages open only as Rise's (rise://settings); the rest, which Rise's pages
            // can't show, aren't opened at all rather than as a blank tab.
            if url.scheme?.lowercased() == "chrome" {
                if let address = RisePages.address(for: url), address.scheme == "rise" { self.addTab(url: address) }
                return true
            }
            let opener = self.tabs.first { $0.page === page }?.id
            if background { self.addTab(url: url, background: true, opener: opener ?? self.selectedID) }
            else { self.addTab(url: url).returnsTo = opener }
            return true
        }
        page.onOpenInPeek = { [weak self, weak page] url in self?.showPeek(url: url, from: page?.view) }
        page.onEvent = { [weak self, weak page] event in
            guard let self, let view = page?.view else { return }
            switch event {
            case .willNavigate(let kind):
                if kind == .newPage { self.leaveForwardPages(of: view) }
                self.pageFullscreen.setActive(false, in: view)
                self.pageStartedLoading(view)
            case .finished: self.pageFinishedLoading(view)
            case .failed(let message): self.showNavigationError(message, in: view)
            case .crashed: self.pageFullscreen.setActive(false, in: view); self.pageCrashed(view)
            case .openInOtherApp(let url): self.confirmOpeningInOtherApp(url)
            case .closed:
                // Out of Chromium's closing, its tab goes too.
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let tab = self.tabs.first(where: { $0.page.view === view }) else { return }
                    self.closeTab(tab.id)
                }
            }
        }
        if let chromium = page as? ChromiumPage {
            chromium.onDownload = { [weak self] download, name in self?.beginChromiumDownload(download, suggestedName: name) }
            installRiseSettings(on: chromium)
            installWebStoreButton(on: chromium)
            chromium.onContextMenu = { [weak self, weak chromium] info in
                guard let self, let chromium else { return }
                self.showContextMenu(info, in: chromium)
            }
            chromium.onDialog = { [weak self, weak chromium] dialog, finish in
                guard let self, let chromium else { finish(false, nil); return nil }
                return self.showDialog(dialog, from: chromium, finish: finish)
            }
            chromium.onChooseFiles = { [weak self] mode, path, finish in
                guard let self else { finish(nil); return }
                self.chooseFiles(mode, defaultPath: path, finish: finish)
            }
            chromium.onPopup = { [weak self, weak chromium] popup, url in
                // Chrome's own pages go as other links do, above.
                guard let self, let chromium, url.scheme?.lowercased() != "chrome" else { return false }
                // Gmail draws a popped-out conversation from the page that opened it, so it shows
                // in the popup itself, in a Peek.
                if GmailAccount.isPopout(url), self.tabHoverCards.popoutSource === chromium.view || self.shouldPeek(modifiers: NSEvent.modifierFlags) {
                    self.tabHoverCards.popoutSource = nil; self.discardPeekUndo()
                    self.showPeek(url: url, existing: self.configure(BrowserTab(page: popup)))
                    return true
                }
                // A site taking the user to a new tab: Back from there comes home again.
                let opener = self.tabs.first { $0.page === chromium }
                self.addTab(page: popup).returnsTo = opener?.id
                return true
            }
            chromium.onPermissionRequest = { [weak self, weak chromium] capabilities, origin, decide in
                guard let self, let chromium else { decide(false); return }
                self.permissionCoordinator.request(in: chromium.view, origin: origin, capabilities: capabilities, completion: decide)
            }
            // Chromium doesn't know these pages were windows a site opened, so closing one when it
            // asks is left to Rise.
            chromium.addMessageHandler("riseWindowClose", world: .page) { [weak self] message in
                guard let self, let page = message.page, message.frame.isMain,
                      let tab = self.tabs.first(where: { $0.page === page }), tab.returnsTo != nil else { return }
                self.closeTab(tab.id)
            }
            chromium.addUserScript("window.close = function close() { riseHandlers.riseWindowClose.postMessage(null); };",
                                   world: .page, mainFrameOnly: true, handlers: ["riseWindowClose"])
            chromium.onPermissionWithdrawn = { [weak self, weak chromium] in
                if let view = chromium?.view { self?.permissionCoordinator.cancel(for: view) }
            }
        }
        tab.hidesNotificationCounts = hidesNotificationCounts
        tab.showsRepositorySubtitle = showsRepositorySubtitle
        tab.page.setTheme(theme.appearance, background: theme.page)
        adBlocker.install(on: tab.page)
        HistorySwipeController.install(on: tab.page)
        siteSearchLearner.install(on: tab.page)
        linkPreloader.install(on: tab.page)
        permissionCoordinator.install(on: tab.page)
        pageFullscreen.install(on: tab.page)
        pictureInPicture.install(on: tab.page)
        tabMedia.install(on: tab.page)
        suggestionFavicons.remember(tab)
        tab.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.suggestionFavicons.remember(tab)
            self.siteSearchLearner.addressChanged(tab.page.view, url: tab.page.url)
            if !tab.page.isLoading, let url = tab.page.url, let title = tab.page.title {
                self.browsingHistory.updateTitle(self.historyTitle(title, url: url), for: url)
            }
            self.update()
        }
        tab.onThumbnailChange = { [weak self] in self?.refreshTabSwitcher() }
        // The engine's full screen hands the page back where it took it from, even if its tab is no longer shown.
        tab.onFullscreenChange = { [weak self] in self?.attachVisiblePages(); self?.update() }
        return tab
    }
    /// A background tab loads in the list without taking over the page, as ⌘-clicked links do.
    /// Given an `opener`, it goes right above that tab (or its split pair), so the two stay together.
    @discardableResult func addTab(url: URL? = nil, background: Bool = false, opener: UUID? = nil, page: WebPage? = nil) -> BrowserTab {
        let tab = configure(BrowserTab(page: page))
        let members = opener.map { id in splitGroups.first { $0.contains(id) }.map { [$0.leftID, $0.rightID] } ?? [id] } ?? []
        tabs.insert(tab, at: members.compactMap { id in tabs.firstIndex { $0.id == id } }.min() ?? 0)
        if background { update() } else { select(tab.id) }
        if let url { tab.load(url) }; return tab
    }
    func select(_ id: UUID) {
        // A Peek's stand-ins belong to the page they cover.
        finishPeekPromotion()
        historySwipe.cancel()
        cancelTabSwitch()
        siteInfoPopover.close()
        siteControlsPopover.close(); permissionCoordinator.cancel()
        if selectedID != id { selectedTab?.captureThumbnail() }
        hideLinkStatus()
        hidePalette(); closePeek()
        let previousID = selectedID
        selectedID = id
        swapFindBar(from: previousID)
        attachVisiblePages()
        recentTabIDs.removeAll { $0 == id }; recentTabIDs.insert(id, at: 0)
        if let tab = selectedTab {
            window?.makeFirstResponder(tab.page.view)
        }
        update(); layoutChrome()
        findBar.reattached()
    }
    func update() {
        extensionTabsChanged()
        reconcileFullscreenSidebar()
        splitPeekReturns = splitPeekReturns.filter { id, undo in
            splitGroups.contains { $0.id == id && $0.contains(undo.tab.id) } && tabs.contains { $0 === undo.tab }
        }
        applyTheme()
        sidebar.update(tabs: tabs, selected: selectedTab, theme: theme, splits: splitGroups)
        refreshTabHoverCard(); preloadGmailInbox()
        window?.title = (selectedTab?.title).map { "\($0) — Rise" } ?? "Rise"
        toolbarButtons[1].isEnabled = historyPage.map { canNavigate($0, .back) } ?? false
        toolbarButtons[2].isEnabled = historyPage.map { canNavigate($0, .forward) } ?? false
        (toolbarButtons[3] as? ReloadButton)?.setMode(selectedTab?.isLoading == true ? .stop : .reload)
        developerAddress.updateURL(selectedTab?.url?.absoluteString ?? "")
        errorSurface.isHidden = errorWebView == nil || errorWebView !== selectedTab?.page.view
        layoutChrome(); refreshTabSwitcher(); scheduleSave()
        if !isApplyingSharedTabs { tabSync?.capture(sharedTabsSnapshot) }
        if hasPendingSharedTabs, canApplySharedTabs { applyPendingSharedTabs() }
    }
    @objc func newTab() { paletteCreatesTab = true; showPalette(text: "") }
    @objc func focusAddress() { paletteCreatesTab = false; showPalette(text: selectedTab?.url?.absoluteString == "about:blank" ? "" : selectedTab?.url?.absoluteString ?? "") }
    func showPalette(text: String) { if searchProvider.isGoogle { googleSearchSuggestions.warmUp() }; historySwipe.cancel(); cancelTabSwitch(); hideLinkStatus(); siteControlsPopover.close(); permissionCoordinator.cancel(); dismissArea.isHidden = false; palette.currentPage = selectedTab.flatMap { tab in tab.url.map { ($0.absoluteString, tab.favicon(for: theme)) } }; palette.show(text: text, theme: theme, createsTab: paletteCreatesTab); layoutChrome() }
    func hidePalette() {
        googleSearchSuggestions.cancel(); suggestionFavicons.cancelPreview()
        guard palette.isPresented else { return }
        palette.hide(); dismissArea.isHidden = true; window?.makeFirstResponder(selectedTab?.page.view)
        DispatchQueue.main.async { [weak self] in self?.applyPendingSharedTabs() }
    }
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
        guard let url = suggestion?.url ?? AddressResolver.resolve(text, search: searchProvider.searchURL) else { return }
        // Resolve again at activation time: an open tab may have navigated or
        // closed since the result was built. Never create an exact duplicate.
        if let existing = openTab(for: url) { select(existing.id); return }
        if paletteCreatesTab || selectedTab == nil { addTab(url: url) }
        else { errorWebView = nil; selectedTab?.load(url) }
    }
    @objc func closeCurrentTab() {
        if peekTab != nil { closePeek(animated: true); return }
        if let id = selectedID { closeTab(id) }
    }
    func closeTab(_ id: UUID) {
        historySwipe.cancel()
        cancelTabSwitch()
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        pictureInPicture.remove(tabs[index]); tabMedia.remove(id)
        let partner = splitGroups.first { $0.contains(id) }.map { $0.leftID == id ? $0.rightID : $0.leftID }
        splitGroups.removeAll { $0.contains(id) }
        let tab = tabs.remove(at: index); closedTabs.append(tab.saved)
        pageFullscreen.setActive(false, in: tab.page.view)
        releaseHeldPages(of: tab)
        permissionCoordinator.cancel(for: tab.page.view)
        recentTabIDs.removeAll { $0 == id }
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        tab.cancelLoad(); tab.page.view.removeFromSuperview()
        findBars.removeValue(forKey: id)?.discard()
        if selectedID == id {
            selectedID = nil
            if let partner, tabs.contains(where: { $0.id == partner }) { select(partner) }
            else if !tabs.isEmpty { select(tabs[min(index, tabs.count-1)].id) }
        }
        attachVisiblePages(); update()
    }
    @objc func reopenTab() {
        guard var saved = closedTabs.popLast() else { return }
        if tabSync?.isClosed(saved.id) == true { saved.id = UUID() }
        let tab = configure(BrowserTab(saved: saved)); tabs.insert(tab, at: 0); select(tab.id)
    }
    @objc func goBack() { navigateHistory(.back) }
    @objc func goForward() { navigateHistory(.forward) }
    private func navigateHistory(_ direction: HistoryDirection) {
        // Buttons and menu shortcuts go straight to the page. Remove any in-flight
        // swipe surface and arrow spring before navigation starts.
        historySwipe.cancel()
        developerMotion.cancel()
        toolbarButtons.compactMap { $0 as? HistoryArrowButton }.forEach { $0.restore() }
        errorWebView = nil
        if let peek = peekTab {
            // Pages visited inside a Peek have their own history.
            if direction == .back ? peek.page.canGoBack : peek.page.canGoForward {
                if direction == .back { peek.page.goBack() } else { peek.page.goForward() }
            }
        } else if let tab = selectedTab, direction == .back ? tab.page.canGoBack : tab.page.canGoForward {
            tab.cancelLoad()
            if direction == .back { tab.page.goBack() } else { tab.page.goForward() }
        } else if let tab = selectedTab {
            // Past the page's own history: a page held from before a Peek grew into the tab.
            goThroughHeldPages(direction, in: tab)
        }
        update()
    }
    /// Reloads without the cache, refetching the page and everything it loads.
    @objc func hardReload() {
        historySwipe.cancel(); errorWebView = nil
        selectedTab?.isHardReloading = true
        if let tab = selectedTab, tab.page.url == nil, let url = tab.requestedURL { tab.load(url) } else { selectedTab?.page.reloadIgnoringCache() }
        update()
    }
    @objc func reload() { historySwipe.cancel(); errorWebView = nil; (toolbarButtons[3] as? ReloadButton)?.armAnimation(); if selectedTab?.isLoading == true { selectedTab?.cancelLoad() } else if let tab = selectedTab, tab.page.url == nil, let url = tab.requestedURL { tab.load(url) } else { selectedTab?.page.reload() }; update() }
    @objc func retry() { errorWebView = nil; if let url = selectedTab?.url { selectedTab?.load(url) }; update() }
    @objc func toggleSidebar() {
        if keepPeekedSidebar() { return }
        // An explicit sidebar choice takes precedence over automatic restoration.
        if fullscreenSidebarWasVisible != nil { fullscreenSidebarWasVisible = false }
        setSidebarVisible(!sidebarVisible)
    }
    func setSidebarVisible(_ visible: Bool) {
        guard sidebarVisible != visible else { return }
        tabPressed()
        hidePalette()
        siteControlsPopover.close(); permissionCoordinator.cancel()
        let floating = isSidebarFloating
        sidebarVisible = visible
        if !sidebarVisible { sidebar.newTab.resetHover() }
        settleSidebarFloat(docking: floating)
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
            window?.makeFirstResponder(tab.page.view); siteInfoPopover.close()
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
        automaticTheme = false
        theme = themes[((themes.firstIndex(of: theme) ?? 0) + 1) % themes.count]; update()
    }
    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    func cycleTab(_ direction: Int) { guard !tabs.isEmpty else { return }; let index = tabs.firstIndex { $0.id == selectedID } ?? 0; select(tabs[(index+direction+tabs.count)%tabs.count].id) }
    @objc func zoomIn() { selectedTab?.page.zoom = min(3, (selectedTab?.page.zoom ?? 1)+0.1) }
    @objc func zoomOut() { selectedTab?.page.zoom = max(0.3, (selectedTab?.page.zoom ?? 1)-0.1) }
    @objc func actualSize() { selectedTab?.page.zoom = 1 }
    func scheduleSave() {
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.saveNow() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: work)
    }
    func saveNow() {
        if !isApplyingSharedTabs { tabSync?.capture(sharedTabsSnapshot) }
        tabSync?.flush()
        suggestionFavicons.save()
        do { try browsingHistory.save(); try siteSearchLearner.searches.save() }
        catch { NSLog("Rise history save failed: %@", error.localizedDescription) }
        let state = BrowserSession(tabs: tabs.map(\.saved), selectedID: selectedID, theme: automaticTheme ? Self.automaticThemeName : theme.rawValue, sidebarWidth: sidebarWidth, splitGroups: splitGroups)
        guard state != lastSaved else { return }
        do { try SessionStorage.write(state, to: sessionURL); lastSaved = state }
        catch { NSLog("Rise session save failed: %@", error.localizedDescription) }
    }
}

@MainActor extension BrowserController {
    /// Whether a tab's media is paused, or nil when it has none. A YouTube video
    /// page answers for its video; any other tab, for whatever it last played with sound.
    func playbackPaused(_ id: UUID) -> Bool? { pictureInPicture.playbackPaused(id) ?? tabMedia.paused(id) }
    func togglePlayback(_ id: UUID) {
        if pictureInPicture.playbackPaused(id) != nil { pictureInPicture.togglePlayback(id) } else { tabMedia.togglePlayback(id) }
    }
    func refreshPlayback(_ id: UUID) { sidebar.rows[id]?.setPlayback(paused: playbackPaused(id)) }
}
