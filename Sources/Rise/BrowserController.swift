import AppKit
import RiseCore

@MainActor final class BrowserController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    let root = Surface()
    /// The window's backdrop, as Kero's: macOS's sidebar material, behind the window,
    /// under 82% of Kero's grey.
    let plainMaterial = NSVisualEffectView(), plainTint = Surface()
    /// Stars repositories as the person signed in to GitHub, from a link's menu.
    private(set) lazy var githubStarrer: GitHubStarrer = { let starrer = GitHubStarrer(); starrer.host = root; return starrer }()
    /// Dark puts Kero's lit edge around the page.
    let pageEdge = PageEdge()
    /// The bar over the page, as Dia's.
    private(set) lazy var navBar: PlainNavBar = PlainNavBar(copy: { [weak self] in self?.copyURL() }, settings: { [weak self] in self?.siteMenu() },
                                               zoom: { [weak self] in self?.actualSize() }, permission: { [weak self] in self?.permissionCoordinator.togglePrompt() },
                                               currency: { [weak self] in if let self { currencyReplacement.toggle(from: navBar) } })
    var plainBarTimer: Timer?, plainBarColors: [UUID: NSColor] = [:], plainBarTabID: UUID?, plainBarSampling = false
    /// When the page bar's colour was last seen changing, by what (`PlainNavBarController.swift`).
    var plainBarWatchedUntil = Date.distantPast, plainBarPages = "", plainBarMonitor: Any?
    /// A split's right page's own bar (`SplitNavBar.swift`), its buttons, and the page it shows.
    private(set) lazy var splitBar: PlainNavBar = PlainNavBar(copy: { [weak self] in self?.copyURL() }, settings: { [weak self] in self?.siteMenu() },
                                                 zoom: { [weak self] in self?.actualSize() }, permission: { [weak self] in self?.permissionCoordinator.togglePrompt() },
                                                 currency: { [weak self] in if let self { currencyReplacement.toggle(from: splitBar) } })
    var splitBarButtons: [ChromeButton] = [], splitBarTabID: UUID?
    /// The Peek's own bar, across its card's top (`PeekBar.swift`), its buttons, and the page it shows.
    private(set) lazy var peekBar: PlainNavBar = PlainNavBar(copy: { [weak self] in self?.copyURL() }, settings: { [weak self] in self?.siteMenu() },
                                                zoom: { [weak self] in self?.actualSize() }, permission: { [weak self] in self?.permissionCoordinator.togglePrompt() },
                                                currency: { [weak self] in if let self { currencyReplacement.toggle(from: peekBar) } })
    var peekBarButtons: [ChromeButton] = [], peekBarTabID: UUID?
    let pageShadow = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let pageClip = PageSurface(color: NSColor(hex: 0xFDFCFC), radius: PageAppearance.radius)
    let emptyPage = Surface(color: NSColor(hex: 0xFDFCFC))
    let linkStatus = LinkStatusPill()
    private(set) lazy var githubLinkStatus = makeGitHubLinkStatus()
    lazy var annotations = PageAnnotations(browser: self)
    lazy var smartTabSearch = SmartTabSearch(browser: self)
    /// The page whose link is under the pointer, as its view.
    weak var hoveredWebView: NSView?
    let developerBar = DeveloperHeader(color: NSColor(hex: 0xFCF6F7))
    let developerAddress = DeveloperAddressField(frame: .zero)
    lazy var developerMotion = DeveloperModeMotion { [weak self] in self?.layoutChrome() }
    let siteInfoPopover = NSPopover()
    let siteControlsPopover = NSPopover()
    /// The page bar the site controls opened from, kept looking hovered while they show.
    weak var siteControlsBar: PlainNavBar?
    /// A reload switching a setting in the site controls asked for, which leaves them open.
    var siteControlsReload: (tab: UUID, url: URL, until: Date)?
    /// The camera button's JPEG and PDF.
    let capturePopover = NSPopover()
    var linkPasteboard: NSPasteboard = .general
    let sitePermissions: SitePermissions
    let cookieConsent: CookieConsent
    lazy var permissionCoordinator = PermissionCoordinator(browser: self)
    lazy var currencyReplacement = CurrencyReplacement(browser: self)
    lazy var timeReplacement = TimeReplacement(browser: self)
    lazy var adBlockPrompt = AdBlockPrompt(browser: self)
    lazy var pictureInPicture = VideoPictureInPicture(browser: self)
    lazy var tabMedia: TabMedia = {
        let media = TabMedia(browser: self)
        media.onChange = { [weak self] id in self?.refreshPlayback(id) }
        media.onReport = { [weak self] _ in self?.nowPlaying.setNeedsRefresh() }
        return media
    }()
    lazy var nowPlaying = NowPlaying(browser: self)
    var sharingPicker: NSSharingServicePicker?
    var selectionItemReceipts: [SelectionItemReceipt] = []
    var selectionItemExpiry: Timer?
    var assistantSubmissions: [UUID: AssistantPromptSubmission] = [:]
    let errorSurface = Surface(color: NSColor(hex: 0xFDFCFC))
    let errorTitle = label("This page couldn’t be opened", size: 23, weight: .semibold)
    let errorMessage = label("", size: 13, color: .secondaryLabelColor)
    var retryButton: NSButton!
    let dismissArea = DismissView()
    /// Shared dimming and motion for the address palette and tab switcher.
    let veil = PanelVeil(frame: .zero)
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
    lazy var historySwipe: HistorySwipeController = {
        let controller = HistorySwipeController(window: window as! BrowserWindow, pageAt: { [weak self] event in
            self?.historyPage(at: event)
        }, feedback: { [weak self] direction, pull, armed, release in
            guard let self, let direction, let arrow = self.selectedHistoryArrow(direction) else { return }
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
        controller.indicatorDrag = { [weak self] page, direction, pull, armed in
            self?.dragHistoryIndicator(on: page, direction, pull: pull, armed: armed)
        }
        controller.indicatorList = { [weak self] entries in
            if let entries { self?.historyIndicator.showList(entries) } else { self?.historyIndicator.hideList() }
        }
        controller.indicatorSelect = { [weak self] index in self?.historyIndicator.select(index) }
        controller.indicatorRelease = { [weak self] in self?.historyIndicator.release() }
        controller.listEntries = { [weak self] page, direction in self?.historyListEntries(for: page, direction) ?? [] }
        return controller
    }()
    lazy var historyIndicator = HistorySwipeIndicator(frame: .zero)
    var tabs: [BrowserTab] = [] { didSet { extensionTabsChanged() } }
    var selectedID: UUID? { didSet { extensionTabsChanged() } }
    /// The window as Chrome extensions see it (`ExtensionWindow`).
    var extensionWindow: AnyObject?
    /// The extension popup that's open, if any.
    var extensionPopup: ExtensionPopup?
    var spareExtensionPopup: ExtensionPopup?
    /// Keeps an extension's process running while the pointer is on its button (ExtensionControls).
    var extensionWarmer: (id: String, page: ChromiumPage, ends: DispatchWorkItem?)?
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
    var closedTabs: [SavedTab] = []
    /// Tabs archived for going unused, which stay until reopened, removed or too old to keep.
    lazy var archivedTabs = ArchivedTabs(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("archived-tabs.json"))
    let archivedTabsPopover = NSPopover()
    lazy var tabUseClock: TabUseClock = preferences.data(forKey: Self.tabUseClockKey)
        .flatMap { try? JSONDecoder().decode(TabUseClock.self, from: $0) } ?? TabUseClock()
    var tabUseWork: DispatchWorkItem?
    var lastTabArchiveCheck: Date?
    var isArchivingTabs = false
    /// A pinned tab ⌘W was pressed in, and until when a second press closes it.
    var pinnedCloseRequest: (id: UUID, until: Date)?
    let browsingHistory: BrowsingHistory
    let siteSearchLearner: SiteSearchLearner
    let suggestionFavicons: SuggestionFavicons
    /// Control-Tab's card pictures, kept across launches.
    let tabPictures: TabPictureStore
    let googleSearchSuggestions: GoogleSearchSuggestions
    let paletteCommandUsage: PaletteCommandUsage
    var theme: RiseTheme = .neutral
    /// The palette lab's panel, in its build (`PaletteLab`).
    var paletteLab: PaletteLabPanel?
    /// Follows macOS's appearance, Light by day and Dark by night when macOS
    /// itself is set to Auto, instead of keeping one chosen theme.
    var automaticTheme = false
    var systemAppearanceObservation: NSKeyValueObservation?
    var sidebarWidth = SidebarWidth.ideal
    var sidebarVisible = true
    let sidebarPeek = SidebarPeek()
    /// Bookmarks (`Bookmarks.swift`): kept beside the session, shown in a bar under the page's bar
    /// (`BookmarksBar.swift`) or in the sidebar in the tabs' place (`SidebarBookmarks.swift`).
    lazy var bookmarks = BookmarkStore(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("bookmarks.json"))
    let bookmarksBar = BookmarksBar()
    let bookmarksBarHover = BookmarksBarHover(frame: .zero)
    let sidebarBookmarks = SidebarBookmarksState()
    /// A menu from the bookmarks bar is open, so a bar that hides itself stays down.
    var bookmarksMenuOpen = false
    /// Until when a bar that hides itself stays down to show a bookmark just added.
    var bookmarksBarRevealUntil: Date?
    /// The bookmark whose title is being typed after ⌘D: whether it was just added, so Escape
    /// takes it away again, and whether the sidebar rolled to bookmarks for it, to roll back after.
    var bookmarkEdit: (id: UUID, isNew: Bool, returnsToTabs: Bool)?
    let sidebarFloat = SidebarFloat()
    let devTools = DevToolsPanel()
    /// The AI chat docked at the window's right (`AIChatPanel.swift`).
    let aiChat = AIChatPanel()
    lazy var tabHoverCards: TabHoverCards = {
        let hover = TabHoverCards(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("pr-summaries.json"))
        hover.summaries.onChange = { [weak self] key in self?.pullRequestSummaryChanged(key) }
        // The icon by a request tab's repository.
        hover.summaries.onStateChange = { [weak self] _ in self?.update() }
        hover.pullRequestClock = Timer.scheduledTimer(withTimeInterval: PullRequestSummaries.statusRefresh+1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPullRequestTabs() }
        }
        hover.summaries.provider = { [weak self] in self?.modelChoice ?? .openRouter }
        // A private GitLab answers through a page signed in to it: the one showing, else any open.
        hover.summaries.openSignedInPage = { [weak self] host in
            guard let self else { return nil }
            let pages = ([self.selectedTab].compactMap { $0 } + self.tabs + self.allPeekTabs).map(\.page)
            return pages.first { $0 is ChromiumPage && $0.url?.host?.lowercased() == host.lowercased() && !$0.isLoading }
        }
        hover.summaries.signedInPage = { [weak self] host in
            guard let self else { return nil }
            if let open = self.tabHoverCards.summaries.openSignedInPage(host) { return open }
            // None open: one offscreen, with the same session.
            self.signedInPages.host = self.root
            return await self.signedInPages.page(for: host)
        }
        return hover
    }()
    let linkPullRequests = LinkPullRequestCards()
    /// Private servers' pages kept offscreen, for their hover cards (`SignedInPages.swift`).
    let signedInPages = SignedInPages()
    /// Option was held at the last change of the hovered link's modifiers.
    var hoveredWithOption = false
    lazy var calendarAgenda: CalendarAgenda = {
        let agenda = CalendarAgenda()
        agenda.onChange = { [weak self] in self?.calendarAgendaChanged() }
        agenda.onAnswerFailed = { [weak self] event, _ in self?.calendarAnswerFailed(event) }
        return agenda
    }()
    lazy var gmailInbox: GmailInbox = {
        let inbox = GmailInbox()
        inbox.onChange = { [weak self] in self?.gmailInboxChanged() }
        return inbox
    }()
    lazy var chatInbox: GoogleChatInbox = {
        let inbox = GoogleChatInbox()
        inbox.onChange = { [weak self] in self?.chatInboxChanged() }
        return inbox
    }()
    lazy var protonMailInbox: ProtonMailInbox = {
        let inbox = ProtonMailInbox()
        inbox.onChange = { [weak self] in self?.protonMailInboxChanged() }
        return inbox
    }()
    var paletteCreatesTab = false
    var splitGroups: [SplitTabGroup] = []
    lazy var keyboardShortcuts: KeyboardShortcuts = {
        let shortcuts = KeyboardShortcuts(preferences: preferences)
        shortcuts.onChange = { [weak self] in self?.keyboardShortcutsChanged() }
        return shortcuts
    }()
    weak var shortcutRecordingPage: WebPage?
    var shortcutRecordingID: String?
    var shortcutRecordingIndex = 0
    var shortcutRecordingCandidate: KeyboardShortcut?
    var shortcutRecordingModifiers: NSEvent.ModifierFlags = []
    var shortcutRecordedKeyCode: UInt16?
    var tabMoveHeldModifiers: NSEvent.ModifierFlags = [.command, .option]
    var tabSwitchHeldModifiers: NSEvent.ModifierFlags = .control
    let tabScroll = TabScrollSelection()
    /// Arrow presses while ⌥⌘ stays held share one tab-order undo step.
    var tabMoveSequence: (tabID: UUID, order: [UUID])?
    /// Route undo to the sidebar until the next editing key goes to the page or a text field.
    var tabOrderUndoPending = false
    /// A shortcut on its way to the page, and one the bar is offering Rise's command for (`PageShortcuts`).
    var pendingPageKey: PendingPageKey?
    var shortcutAgain: (id: String, until: Date)?
    var peekSourceTabID: UUID?
    var peekOpensNewTab = false
    var peekSwipePull: Double = 0
    var peekTab: BrowserTab?
    /// Live Peeks belonging to tabs that aren't currently shown.
    var suspendedPeeks: [UUID: SuspendedPeek] = [:]
    var isSelectingTab = false
    var peekBackdrop: Surface?
    var peekCard: Surface?
    var peekControls: [PeekControl] = []
    /// ⌘Z puts a Peek that became a tab or a split back, for a short while.
    var peekUndo: PeekUndo?
    /// ⌘Z takes back a split just made, for as long as a Peek's (`SplitUndo`).
    var splitUndo: SplitUndo?
    /// The divider can restore its original Peek even after the keyboard undo window expires.
    var splitPeekReturns: [UUID: PeekUndo] = [:]
    /// Waiting for the Peek's snapshot before it grows into the page.
    var isPromotingPeek = false
    /// A Peek growing into a new tab, whose row the sidebar shows from the press, before it lands.
    var peekJoiningSidebar: (tab: BrowserTab, index: Int)?
    var peekPromotion: PeekPromotion?
    /// The Peek card moving frame by frame with its live page inside, when Live Peek Resize is on.
    var peekLiveMotion: PeekLiveMotion?
    /// ⇧⌘D's copy lifting off the page into the right half (`SplitDuplicate.swift`).
    var duplicateMotion: PeekLiveMotion?
    /// The targets over the page while a tab is dragged from the sidebar, and a tab let go on one
    /// coming into its half (`SplitDrop.swift`).
    let splitDrop = SplitDropTargets()
    var splitDropMotion: PeekLiveMotion?
    /// The split a dropped tab is forming, shown in the sidebar while the pages move into it.
    var pendingSplitDrop: SplitTabGroup?
    /// The pill between split pages, which drags the split.
    let splitHandle = SplitHandle()
    /// The split springing back to the middle after a double click on its handle.
    var splitMotion: PeekLiveMotion?
    /// Stills of a split's sides crossing over as they swap (`SplitSwap`).
    var splitSwapMotion: PeekLiveMotion?
    /// The page area below the developer bar, as last laid out.
    var pageBody = NSRect.zero
    /// An animation is placing the pages itself, so layout leaves them where it put them.
    var pageLayoutHeld = false
    /// A Shift-click that opened a Peek, or an Option-click that copied a link: the rest of it
    /// stays from the page.
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
    var downloadFlight: DownloadFlight?
    /// Downloads save here without asking; tests point it elsewhere.
    var downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// The image or video being got for AirDrop, and, for checks, what's sent in place of AirDrop's panel.
    var mediaAirDrop: MediaAirDrop?
    var airDropFile: ((URL) -> Void)?
    lazy var downloads: DownloadList = {
        let list = DownloadList(storeURL: sessionURL.deletingLastPathComponent().appendingPathComponent("downloads.json"))
        list.onChange = { [weak self] in self?.reloadDownloadsList?(); self?.updateDownloadsButton() }
        list.onFinish = { [weak self] _ in
            guard let self, self.downloads.items.allSatisfy(\.isFinished) else { return }
            self.sidebar.archiveButton.glyph.complete()
        }
        return list
    }()
    /// Refreshes the downloads popover's rows while it's open.
    var reloadDownloadsList: (() -> Void)?
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
        menu.separatingIconSections().popUp(positioning: nil, at: point, in: view)
    }
    /// macOS's certificate choosers showing for pages that asked for a certificate, by page.
    var clientCertificateChoosers: [ObjectIdentifier: ClientCertificateChooser] = [:]
    var lastSaved: BrowserSession?
    /// An update pages' changes are waiting for (`BrowserUpdates`).
    var pendingUpdate: PendingUpdate?
    /// The tabs, in order, as tab sync last had them.
    var syncedTabOrder: [UUID] = []
    var tabSync: SharedTabsSync?
    var isApplyingSharedTabs = false
    var hasPendingSharedTabs = false
    var syncedTabMetadata: SyncedTabMetadata?
    /// The page, as its view, whose load failed.
    var errorWebView: NSView?
    let adBlocker: AdBlocker
    var blockingChangeGeneration = 0
    let linkPreloader: LinkPreloader
    let openTabLinks: OpenTabLinks
    let pageFullscreen: PageFullscreen
    let youTubeAutoplay: YouTubeAutoplay
    /// The docked sidebar's state before the visible page entered simulated fullscreen.
    var fullscreenSidebarWasVisible: Bool?
    let fullscreenNavigationHover = FullscreenNavigationHover(frame: .zero)
    let tabSwitcher = TabSwitcherView()
    var recentTabIDs: [UUID] = []
    var tabSwitchOrder: [UUID] = []
    var tabSwitchIndex = 0
    var tabSwitchWork: DispatchWorkItem?
    var tabSwitchGeneration = 0
    let switcherPictureHost = PeekStandbyView()
    var switcherPictureWork: DispatchWorkItem?
    var switcherPictureTask: Task<Void, Never>?
    var tabSleepTimer: Timer?
    /// Tabs whose pages are being asked whether a form is part-filled before they sleep.
    var tabsAskedToSleep: Set<UUID> = []
    var pendingMiddleTabID: UUID?

    init(sessionURL: URL? = nil, restore: Bool = true, preferences: UserDefaults = .standard, searchSuggestions: GoogleSearchSuggestions? = nil) {
        let syncTabs = sessionURL == nil && restore && Bundle.main.bundleIdentifier == "dev.bartosz.Rise"
        self.preferences = preferences
        googleSearchSuggestions = searchSuggestions ?? GoogleSearchSuggestions()
        sitePermissions = SitePermissions(preferences: preferences)
        sitePermissions.shareChoices()
        cookieConsent = CookieConsent(preferences: preferences)
        adBlocker = AdBlocker(preferences: preferences)
        linkPreloader = LinkPreloader(preferences: preferences)
        openTabLinks = OpenTabLinks(preferences: preferences)
        pageFullscreen = PageFullscreen(preferences: preferences)
        youTubeAutoplay = YouTubeAutoplay(preferences: preferences)
        let sessionURL = sessionURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rise/session.json")
        self.sessionURL = sessionURL
        paletteCommandUsage = PaletteCommandUsage(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("command-usage.json"))
        browsingHistory = BrowsingHistory(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("history.json"))
        siteSearchLearner = SiteSearchLearner(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("searches.json"))
        suggestionFavicons = SuggestionFavicons(storageURL: sessionURL.deletingLastPathComponent().appendingPathComponent("suggestion-icons.json"))
        tabPictures = TabPictureStore(folder: sessionURL.deletingLastPathComponent().appendingPathComponent("Tab Pictures"))
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1496, height: 944), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        if ChromiumEngine.isRunning {
            syncedTabMetadata = SyncedTabMetadata(icons: suggestionFavicons)
            syncedTabMetadata?.onChange = { [weak self] in self?.update() }
        }
        pageFullscreen.onChange = { [weak self] in self?.reconcileFullscreenSidebar(); self?.layoutChrome() }
        fullscreenNavigationHover.changed = { [weak self] in self?.refreshFullscreenNavigation() }
        googleSearchSuggestions.onLoad = { [weak self] query in
            guard let self, self.palette.isPresented, self.palette.query.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                  (self.palette.input.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            self.palette.replaceSuggestions(self.suggestions(for: query))
        }
        suggestionFavicons.onVariantLoad = { [weak self] origin, image, dark in
            guard let self else { return }
            for tab in self.tabs + self.allPeekTabs where SitePermissions.origin(tab.url) == origin {
                if dark { tab.darkFavicon = image }
                else { tab.iconTask?.cancel(); tab.iconTask = nil; tab.iconOrigin = origin; tab.favicon = image }
            }
            if let icon = self.suggestionFavicons.image(for: URL(string: origin), fetch: false, dark: self.theme == .dark) {
                self.palette.updateFavicon(icon, origin: origin)
            }
            self.update()
        }
        window.tabSwitchEvent = { [weak self] event in self?.handleTabSwitchEvent(event) ?? false }
        window.tabScrollEvent = { [weak self] event in self?.handleTabScrollEvent(event) ?? false }
        window.shortcutEvent = { [weak self] event in self?.handleKeyboardShortcut(event) ?? false }
        window.addressPaletteEvent = { [weak self] event in
            guard let self else { return false }; return self.palette.handleKeyEquivalent(event, shortcuts: self.keyboardShortcuts)
        }
        window.undoEvent = { [weak self] event in
            guard let self else { return false }
            // On its way to the page, which goes first.
            if let pending = self.pendingPageKey, pending.timestamp == event.timestamp, pending.keyCode == event.keyCode { return false }
            return self.runBrowserUndo(event)
        }
        window.smartRenameEvent = { [weak self] event in self?.handleSmartRenameKey(event) ?? false }
        window.extensionShortcutEvent = { [weak self] event in self?.runExtensionShortcut(event) ?? false }
        window.pageMouseDown = { [weak self] event in
            if event.type == .rightMouseDown { self?.linkCardPagePressed(event) }
            self?.focusSplitPage(at: event)
        }
        // Any press, even one Rise takes for a Peek or a copy, closes a link's card first.
        window.linkClickEvent = { [weak self] event in
            if event.type == .leftMouseDown { self?.linkCardPagePressed(event) }
            return self?.takeLinkClick(event) ?? false
        }
        window.historyScrollEvent = { [weak self] event in
            guard let self else { return false }
            if let handled = self.tabHoverCards.calendarCard.routeScroll(event) {
                self.historySwipe.cancel()
                return handled
            }
            return self.historySwipe.handle(event)
        }
        window.otherMouseEvent = { [weak self] event in self?.handleMiddleTabClick(event) ?? false }
        window.modifiersChanged = { [weak self] flags in self?.updateHoveredLinkModifiers(flags); self?.sidebarPeekModifiersChanged(flags) }
        window.pointerMoved = { [weak self] event in
            self?.refreshFullscreenNavigation(pointer: event.locationInWindow)
            self?.sidebar.refreshReturningTabHover(at: event.locationInWindow)
            self?.tabHoverPointerMoved()
        }
        tabSwitcher.choose = { [weak self] id in self?.commitTabSwitch(id) }
        tabSwitcher.hover = { [weak self] id in self?.pickTabSwitchCard(id) }
        linkPreloader.loadPage = { url, page, done in
            guard page is ChromiumPage else { return nil }
            let preload = ChromiumPreload(url, size: page.view.bounds.size, done: done)
            return { preload.cancel() }
        }
        openTabLinks.openLinks = { [weak self] page in self?.linksOpenElsewhere(than: page) ?? OpenTabLinks.Open() }
        openTabLinks.goTo = { [weak self] url, page in self?.goToOpenTab(url, from: page) }
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
            // Escape in a card being edited cancels the edit, not Find.
            let editingCard = self.tabHoverCards.pullRequestCard.isEditing || self.linkPullRequests.card.isEditing
            guard self.palette.isHidden, !self.isSwitchingTabs, self.sidebar.drag == nil, !editingCard else { return false }
            if self.annotations.activeID != nil && self.annotations.bar.superview != nil { self.annotations.collapse(); return true }
            if self.findBar.isPresented { swallowingEscape = true; self.findBar.handleEscape(); return true }
            // Escape closes a Peek before its page can keep it, as most pages do, so it never comes back
            // to `escapeAction`; but a page full screen leaves that first, and text being composed ends it.
            guard let peek = self.peekTab, !peek.isInNativeFullscreen, !self.pageFullscreen.isActive(in: peek.page.view),
                  (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
            swallowingEscape = true; self.closePeek(animated: true); return true
        }
        window.escapeAction = { [weak self] in
            guard let self else { return false }
            if self.sidebar.drag != nil { self.sidebar.cancelTabInteractions(); return true }
            if self.isSwitchingTabs { self.cancelTabSwitch(); return true }
            if !self.palette.isHidden {
                // Out of a site's search first, back to the address.
                if self.palette.siteSearch != nil || self.palette.isChoosing {
                    // Focused first: focusing the field selects all of it, over the selection put back.
                    if self.palette.input.currentEditor() == nil { self.window?.makeFirstResponder(self.palette.input) }
                    if self.palette.isChoosing { self.palette.leaveChoice() } else { self.palette.leaveSiteSearch() }
                }
                else { self.palette.dismiss?() }
                return true
            }
            if self.annotations.activeID != nil && self.annotations.bar.superview != nil { self.annotations.collapse(); return true }
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
            // Each tab's card picture from last time, so Control-Tab needn't load its page for one.
            for tab in tabs { tab.thumbnail = tabPictures.picture(for: tab) }
            tabPictures.keepOnly(Set(tabs.map(\.id)))
            // The metadata queue fills dormant pages' missing titles and icons in bounded batches.
            splitGroups = saved.splitGroups
            restorePeeks(saved.peeks)
            selectedID = saved.selectedID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
        }
        if let selectedID { select(selectedID) }
        update(); layoutChrome()
        if syncTabs { startTabSync() }
        startTabSleep()
    }
    required init?(coder: NSCoder) { fatalError() }
    func buildChrome() {
        sidebar = SidebarView(archive: { [weak self] in self?.showDownloads() }, cleanUp: { [weak self] in self?.sidebarSortPressed() })
        sidebar.onSearchQuestion = { [weak self] query in self?.smartTabSearch.search(query) }
        sidebar.onSearchChanged = { [weak self] in self?.smartTabSearch.cancel() }
        sidebar.searchMetadata = { [weak self] tab in self?.smartTabSearch.detail(tab) ?? "" }
        // Recently closed tabs stay one right-click away on the downloads button.
        sidebar.archiveButton.secondaryAction = { [weak self] in self?.archiveMenu() }
        sidebar.onNewTab = { [weak self] in self?.newTab() }
        sidebar.minimalNewTab = minimalNewTab
        sidebar.hidesScrollbar = hidesSidebarScrollbar
        // Choosing a tab, from a search too, shows them all again with it selected.
        sidebar.onSelect = { [weak self] id in self?.sidebar.endTabSearch(); self?.select(id) }
        sidebar.onTabSearchEnded = { [weak self] in self?.window?.makeFirstResponder(self?.selectedTab?.page.view) }
        sidebar.onClose = { [weak self] id in self?.closeTab(id) }
        sidebar.onTabMenu = { [weak self] id, event in self?.tabMenu(id, event: event) }
        sidebar.onReorder = { [weak self] in self?.reorderTabs($0) }
        installSplitDrop()
        sidebar.onPin = { [weak self] id, slot in self?.pinTab(id, at: slot) }
        sidebar.onUnpin = { [weak self] id, index in self?.unpinTab(id, at: index) }
        sidebar.onReorderPinned = { [weak self] in self?.reorderPinnedTabs($0) }
        sidebar.onRename = { [weak self] id, title in self?.renameTab(id, title: title) }
        sidebar.onTabHover = { [weak self] id, hovering in self?.tabHoverChanged(id, hovering: hovering) }
        sidebar.onScrollFocusChanged = { [weak self] in self?.layoutTabScrollArrow() }
        sidebar.playbackState = { [weak self] id in self?.playbackPaused(id) }
        sidebar.peekState = { [weak self] id in self?.peek(for: id) }
        sidebar.pullRequestState = { [weak self] pr in self?.tabHoverCards.summaries.tabState(of: pr) }
        sidebar.onTogglePlayback = { [weak self] id in self?.togglePlayback(id) }
        sidebar.onToggleMute = { [weak self] id in
            if let tab = self?.tabs.first(where: { $0.id == id }) { tab.setAudioMuted(!tab.isAudioMuted) }
        }
        sidebar.onTabPress = { [weak self] in self?.tabPressed() }
        sidebar.bookmarksPane.onOpen = { [weak self] id, atTop in self?.openSidebarBookmark(id, atTop: atTop) }
        sidebar.bookmarksPane.onMenu = { [weak self] id, event, view in self?.showBookmarkMenu(id, event: event, in: view) }
        sidebar.bookmarksPane.onReorder = { [weak self] id, index in self?.bookmarks.move(id, to: index) }
        sidebar.bookmarksPane.onEditEnd = { [weak self] id, title in self?.finishBookmarkEdit(id, title: title) }
        pageShadow.layer?.cornerCurve = .continuous; pageClip.layer?.cornerCurve = .continuous
        pageClip.layer?.masksToBounds = true; pageClip.clipsToBounds = true
        root.addSubview(sidebar); root.addSubview(pageShadow); pageShadow.addSubview(pageClip); installSplitHandle()
        pageClip.addSubview(emptyPage); pageClip.addSubview(developerBar); pageClip.addSubview(navBar)
        navBar.onOpenAddress = { [weak self] in self?.focusAddress() }
        installBookmarksBar()
        navBar.addressMenu = { [weak self] bar in self?.addressMenu(for: bar) }
        installSidebarEdge()
        installDevTools()
        installAIChat()
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
                let reload = ReloadButton(title: title, action: action)
                reload.onRepeatedPress = { [weak self] in self?.adBlockPrompt.noteReload() }
                button = reload
            } else { button = ChromeButton(symbol: symbol, size: 13, title: title, action: action) }
            if symbol == "sidebar.left" { button.setHoverHint("Toggle Sidebar", shortcut: "⌘B") }
            toolbarButtons.append(button)
        }
        // The page bar's, drawn as Dia's: chevrons, and a smaller sidebar glyph.
        navBar.navigation = toolbarButtons
        installSplitBar(); installPeekBar()
        historyArrows.forEach { $0.historyMenu = { [weak self] in self?.historyMenu(for: $0) } }
        developerAddress.font = IoskeleyMonoFont.developerAddress
        developerAddress.textColor = NSColor(hex: 0x393134); developerBar.addSubview(developerAddress)
        navBar.developerAddress = developerAddress; splitBar.developerAddress = developerAddress
        developerAddress.onSubmit = { [weak self] text in self?.navigateDeveloperAddress(text) }
        developerAddress.onCancel = { [weak self] in self?.window?.makeFirstResponder(self?.selectedTab?.page.view) }
        siteInfoPopover.behavior = .transient
        downloadsPopover.behavior = .transient
        archivedTabsPopover.behavior = .transient
        siteControlsPopover.behavior = .transient; siteControlsPopover.delegate = self
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
            button.contentTintColor = PlainNavBar.developerRed; developerBar.addSubview(button); devButtons.append(button)
        }
        errorTitle.alignment = .center; errorMessage.alignment = .center
        errorMessage.maximumNumberOfLines = 3
        retryButton = NSButton(title: "Try Again", target: self, action: #selector(retry))
        retryButton.bezelStyle = .rounded
        [errorTitle, errorMessage, retryButton].forEach(errorSurface.addSubview); errorSurface.isHidden = true
        pageClip.addSubview(errorSurface)
        dismissArea.protectedView = palette
        dismissArea.dismiss = { [weak self] in self?.hidePalette() }; dismissArea.isHidden = true
        root.addSubview(linkStatus); root.addSubview(veil); root.addSubview(dismissArea); root.addSubview(palette)
        palette.dismiss = { [weak self] in self?.hidePalette() }
        loadAddressDisplay()
        palette.choices = { [weak self] command in self?.paletteChoice(for: command) }
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
        toolbarHost.frame = NSRect(x: 0, y: 0, width: 144, height: 48)
        toolbarAccessory.view = toolbarHost
        toolbarAccessory.layoutAttribute = .left
        window?.addTitlebarAccessoryViewController(toolbarAccessory)
        toolbarHost.onMove = { [weak self] in self?.placeTitlebarNewTab() }
    }
    func layoutChrome() {
        // AppKit can deliver a resize while restoring the window, before its
        // sidebar and titlebar controls have finished being constructed.
        guard let window, let sidebar else { return }; let b = root.bounds
        window.backgroundColor = theme.background
        layoutPlainBackdrop()
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
        // A floating sidebar carries the traffic lights with it.
        let carry = shown ? sidebar.frame.origin : .zero
        let toolbarX = toolbarHost.convert(toolbarHost.bounds, to: root).minX
        // Room for the traffic lights to be carried into, held steady while floating so the titlebar
        // isn't resized every frame.
        let room = sidebarVisible && sidebarFloat.dockProgress == 1 ? 0 : SidebarFloatAppearance.inset
        toolbarHost.frame.size.width = shown ? max(112, sidebar.frame.width-toolbarX-8)+room : 28
        carryTitlebarControls(by: carry)
        placeTitlebarNewTab()
        placeBookmarksTitle()
        // The chat takes the window's right side, and the selected tab's DevTools go beside it.
        let chatRoom = layoutAIChat(in: b, pageLeft: pageLeft)
        let devToolsRoom = layoutDevTools(in: NSRect(x: b.minX, y: b.minY, width: b.width-chatRoom, height: b.height), pageLeft: pageLeft)
        pageShadow.frame = PageAppearance.frame(in: b, sidebarWidth: pageLeft, sidebarVisible: true)
        pageShadow.frame.size.width = max(0, pageShadow.frame.width-devToolsRoom-chatRoom)
        // The page is lifted as Kero lifts its cards: in Light, a soft pair of shadows for its
        // edge; in Dark, a lit edge over three tight shadows.
        let keroCard = theme == .dark
        pageShadow.keroShadows = theme == .dark ? .dark : .light
        pageShadow.refreshOutline()
        pageClip.frame = pageShadow.bounds
        pageEdge.isHidden = !keroCard
        if keroCard {
            if pageClip.subviews.last !== pageEdge { pageClip.addSubview(pageEdge) }
            pageEdge.frame = pageClip.bounds
        }
        // The peek width is temporary, and a floating sidebar is never resized.
        grip.frame = NSRect(x: width-3, y: 44, width: 6, height: b.height-88)
        grip.isHidden = !sidebarVisible || sidebarPeek.progress > 0 || sidebarFloat.dockProgress < 1
        let cb = pageClip.bounds
        // The page starts under its bar, and under the bookmarks bar while that stays.
        let barHeight = pageHeaderHeight
        layoutPageBars(width: cb.width)
        layoutDeveloperBar()
        layoutBookmarksBar(width: cb.width)
        let regularBody = NSRect(x: 0, y: barHeight, width: cb.width, height: cb.height-barHeight)
        let body = activeSplitGroup == nil ? fullscreenContentFrame(for: selectedTab, regular: regularBody) : regularBody
        emptyPage.frame = body; pageBody = body
        if pageLayoutHeld {
            // An animation is placing the pages.
        } else if let group = activeSplitGroup {
            let frames = splitFrames(in: body, fraction: group.fraction)
            for (id, frame) in [(group.leftID, frames.left), (group.rightID, frames.right)] {
                if let tab = tabs.first(where: { $0.id == id }), !pictureInPicture.owns(tab), !tab.isInNativeFullscreen {
                    tab.page.view.frame = fullscreenContentFrame(for: tab, regular: frame)
                }
            }
            layoutDevToolsToolbox(body: nil)
            shapePage(around: [frames.left, frames.right])
        } else {
            if let tab = selectedTab, !pictureInPicture.owns(tab), !tab.isInNativeFullscreen { tab.page.view.frame = body }
            layoutDevToolsToolbox(body: body)
            shapePage(around: [])
        }
        layoutSplitHandle()
        errorSurface.frame = body
        errorTitle.frame = NSRect(x: 40, y: body.height/2-60, width: body.width-80, height: 34)
        errorMessage.frame = NSRect(x: 60, y: body.height/2-12, width: body.width-120, height: 56)
        retryButton.frame = NSRect(x: body.width/2-55, y: body.height/2+55, width: 110, height: 32)
        // The panels come down from beneath the page bar and what's under it.
        selectedFindBar.frame = pageShadow.frame; selectedFindBar.topInset = barHeight; selectedFindBar.tuckedInset = barHeight
        permissionCoordinator.layoutPanel(); currencyReplacement.layoutPanel(); timeReplacement.layoutPanel(); adBlockPrompt.layoutPanel()
        dismissArea.frame = b
        // Both centred panels share the same window-wide dim.
        veil.frame = b
        veil.applyTheme(theme)
        let paletteWidth = paletteCreatesTab ? AddressAppearance.tuning.newTabWidth : AddressAppearance.tuning.addressWidth
        if palette.isCentered {
            // Placed where, at its tallest, it's centred in the window, and grows down from there.
            let width = min(CenteredPaletteStyle.width, b.width-16)
            palette.place(at: NSPoint(x: round(b.midX-width/2), y: max(8, round(b.midY-CenteredPaletteStyle.maximumHeight/2))), width: width)
        } else if isSidebarShown {
            let address = root.convert(sidebar.paletteAnchor, from: sidebar)
            let paletteOrigin = NSPoint(x: address.minX, y: address.minY-2)
            palette.place(at: paletteOrigin, width: min(paletteWidth, b.width-paletteOrigin.x-8))
        } else {
            let centeredWidth = paletteCreatesTab ? AddressAppearance.tuning.centeredNewTabWidth : paletteWidth
            palette.place(centeredAt: NSPoint(x: b.midX, y: b.midY), width: min(centeredWidth, b.width-16))
        }
        layoutPeek()
        layoutFullscreenNavigation()
        layoutLinkStatus()
        layoutTabScrollArrow()
        annotations.layout()
        if !tabSwitcher.isHidden { tabSwitcher.place(in: b) }
    }
    /// Developer mode's bar is under the selected page's bar, in its place, and the bar becomes
    /// it: the page bar's colour eases away over the stripes, its address is exchanged for
    /// developer mode's as a notice is, and developer mode's buttons come in one after another.
    func layoutDeveloperBar() {
        let enabled = selectedTab?.developer == true
        let progress = developerMotion.progress(for: selectedID, enabled: enabled)
        let bar = tabBar
        // The bars share developer mode's address: the other gives it up before this one takes it.
        for each in [bar === navBar ? splitBar : navBar, bar] {
            each.setDeveloper(each === bar ? progress : 0, enabled: each === bar && enabled, surface: theme.developerSurface)
        }
        developerBar.frame = bar.frame
        developerBar.isHidden = progress == 0
        // Find's panel over a developer mode page takes its bar's stripes; a permission's does as it's placed.
        for (id, findBar) in findBars { findBar.developer = (tabs.first { $0.id == id } ?? peekTab.flatMap { $0.id == id ? $0 : nil })?.developer == true }
        let height = developerBar.bounds.height, end = min(bar.developerControlsMaxX-8, bar.frame.width-20)
        for (i, button) in devButtons.enumerated() {
            button.frame = NSRect(x: end-CGFloat(devButtons.count-i)*38+8, y: 6, width: 30, height: 28)
            button.alphaValue = DeveloperModeMotion.arriving(progress, delay: CGFloat(i)*0.04)
        }
        bar.developerControlsMinX = progress > 0 ? devButtons.first?.frame.minX : nil
        // A permission's icon, while a page asks, sits before them.
        let addressEnd = (devButtons.first?.frame.minX ?? end)-(bar.requestedPermission == nil ? 0 : 35)
        // Where the page bar's address starts.
        let x = PlainNavBar.Metrics.textX-PlainNavBar.Metrics.textInset-bar.leadingRoom
        // As tall as the bar, its line centred in it.
        developerAddress.frame = NSRect(x: x, y: 0, width: max(60, addressEnd-12-x), height: height)
    }
    func windowDidResize(_ notification: Notification) { layoutChrome(); watchPlainBarColor(for: 0.5) }
    func windowDidChangeOcclusionState(_ notification: Notification) { if window?.occlusionState.contains(.visible) == true { watchPlainBarColor(for: 0.5) } }
    func windowWillClose(_ notification: Notification) { annotations.close(); smartTabSearch.tearDown(); cancelTabScroll(); githubLinkStatus.hover(nil); timeReplacement.cancelHold(); githubStarrer.tearDown(); signedInPages.tearDown(); linkPullRequests.summaries.tearDown(); tabHoverCards.pullRequestClock?.invalidate(); tabHoverCards.pullRequestClock = nil; plainBarTimer?.invalidate(); plainBarTimer = nil; plainBarMonitor.map(NSEvent.removeMonitor); plainBarMonitor = nil; tabPressed(); gmailInbox.tearDown(); protonMailInbox.tearDown(); chatInbox.tearDown(); calendarAgenda.tearDown(); calendarAgenda.clock?.invalidate(); calendarAgenda.clock = nil; settleSidebarFloat(docking: false); pictureInPicture.tearDown(); googleSearchSuggestions.cancel(); quickLookDownloadID = nil; developerMotion.cancel(); sidebar.cancelTabInteractions(); historySwipe.cancel(); siteInfoPopover.close(); siteControlsPopover.close(); permissionCoordinator.cancel(); cancelTabSwitch(); syncedTabMetadata?.cancel(); stopTabSleep(); saveNow() }
    func windowDidResignKey(_ notification: Notification) {
        cancelTabScroll()
        timeReplacement.cancelHold()
        cancelShortcutRecording()
        pendingMiddleTabID = nil; historySwipe.cancel(); cancelTabSwitch(); endSidebarPeek(); endBookmarksHold(); tabPressed()
        refreshBookmarksBar()
        sidebar?.cancelTabInteractions()
        // Leaving Rise floats a shown video in Rise's own window, as leaving its tab does.
        DispatchQueue.main.async { [weak self] in
            guard let self, !NSApp.isActive, self.window?.isKeyWindow != true else { return }
            self.pictureInPicture.applicationDidLeave()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { pictureInPicture.applicationDidReturn() }
    func configure(_ tab: BrowserTab) -> BrowserTab {
        // The page reports hovers, new tabs and its menu.
        // The page, not the tab, is captured: it can move to another tab when a Peek becomes one.
        let page = tab.page
        annotations.install(on: page)
        page.onHoverLink = { [weak self, weak page] url in
            guard let self, let page else { return }
            self.showHoveredLink(url, in: page.view)
        }
        page.onOpenElsewhere = { [weak self, weak page] url, background in
            guard let self else { return false }
            let opener = self.tabs.first { $0.page === page }?.id
            // Chrome's own pages open only as Rise's (rise://settings); the rest, which Rise's pages
            // can't show, aren't opened at all rather than as a blank tab.
            if url.scheme?.lowercased() == "chrome" {
                if let address = RisePages.address(for: url), address.scheme == "rise" { self.addTab(url: address, opener: opener ?? self.selectedID) }
                return true
            }
            if background { self.addTab(url: url, background: true, opener: opener ?? self.selectedID) }
            else { self.addTab(url: url, opener: opener ?? self.selectedID).returnsTo = opener }
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
                    self?.closePage(view)
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
                // A page the chat's model is using asks it, not the person.
                if self.aiChat.tools?.driver.take(dialog, from: chromium, finish: finish) == true { return nil }
                return self.showDialog(dialog, from: chromium, finish: finish)
            }
            chromium.onPageUsedKey = { [weak self] code in self?.pageUsedKey(code: code) }
            chromium.onUnusedKey = { [weak self] event in self?.handleUnusedPageKey(event) ?? false }
            chromium.onChooseClientCertificate = { [weak self, weak chromium] identities, host, finish in
                guard let self, let chromium else { finish(nil); return }
                self.chooseClientCertificate(identities, host: host, for: chromium, finish: finish)
            }
            chromium.onClientCertificateCancelled = { [weak self, weak chromium] in
                guard let self, let chromium else { return }
                self.cancelClientCertificate(for: chromium)
            }
            chromium.onChooseFiles = { [weak self, weak chromium] mode, path, finish in
                guard let self else { finish(nil); return }
                // One the chat's model opened, using the page: its to answer, with upload_file.
                if let chromium, self.aiChat.tools?.driver.takeChooser(mode, from: chromium, finish: finish) == true { return }
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
                self.addTab(opener: opener?.id ?? self.selectedID, page: popup).returnsTo = opener?.id
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
        cookieConsent.install(on: tab.page)
        HistorySwipeController.install(on: tab.page)
        siteSearchLearner.install(on: tab.page)
        linkPreloader.install(on: tab.page); openTabLinks.install(on: tab.page)
        permissionCoordinator.install(on: tab.page)
        pageFullscreen.install(on: tab.page)
        pictureInPicture.install(on: tab.page)
        tabMedia.install(on: tab.page)
        youTubeAutoplay.install(on: tab.page)
        RiseRelaunch.install(on: tab.page)
        suggestionFavicons.remember(tab)
        tab.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            // What the page reports as it loads waits for the frame's update, once however many
            // come; progress alone only moves its loading line and its row's.
            if let page = tab.reportingPageChange, page.progressOnly { self.setNeedsUpdate(.progress); return }
            self.suggestionFavicons.remember(tab)
            self.siteSearchLearner.addressChanged(tab.page.view, url: tab.page.url)
            self.currencyReplacement.pageChanged(tab)
            self.adBlockPrompt.pageChanged(tab)
            if !tab.page.isLoading { self.bookmarks.refreshIcons(from: tab) }
            if !tab.page.isLoading, let url = tab.page.url, let title = tab.page.title {
                self.browsingHistory.updateTitle(self.historyTitle(title, url: url), for: url)
            }
            if tab.reportingPageChange != nil { self.setNeedsUpdate(.full) } else { self.update() }
        }
        tab.onThumbnailChange = { [weak self, weak tab] in
            if let tab { self?.tabPictures.keep(tab) }
            self?.refreshTabSwitcher()
        }
        // The engine's full screen hands the page back where it took it from, even if its tab is no longer shown.
        tab.onFullscreenChange = { [weak self] in self?.attachVisiblePages(); self?.update() }
        // A pull request's page loading, as when it's reloaded to see it now, brings its card up to date.
        tab.onLoadFinished = { [weak self, weak tab] in
            if let self, let tab { self.smartTabSearch.collect(tab); Task { await self.annotations.restore(in: tab.page) } }
            if let pr = PullRequest(url: tab?.url) { self?.tabHoverCards.summaries.refreshStatus(pr, pageLoaded: true) }
        }
        return tab
    }
    /// A background tab loads in the list without taking over the page, as ⌘-clicked links do.
    /// Given an `opener`, it goes right above that tab (or its split pair), so the two stay together.
    @discardableResult func addTab(url: URL? = nil, background: Bool = false, opener: UUID? = nil, page: WebPage? = nil) -> BrowserTab {
        let tab = configure(BrowserTab(page: page))
        tab.openedFrom = opener
        tabs.insert(tab, at: newTabIndex(opener: opener))
        if background { update() } else { select(tab.id) }
        if let url { tab.load(url) }; return tab
    }
    /// Where a new tab goes: right above its opener (or the opener's split pair), else at the top.
    func newTabIndex(opener: UUID?) -> Int {
        let members = opener.map { id in splitGroups.first { $0.contains(id) }.map { [$0.leftID, $0.rightID] } ?? [id] } ?? []
        return members.compactMap { id in tabs.firstIndex { $0.id == id } }.min() ?? 0
    }
    func select(_ id: UUID) {
        cancelTabScroll()
        if selectedID != id { timeReplacement.cancelHold() }
        if selectedID != id { cancelShortcutRecording() }
        let wasSelecting = isSelectingTab
        isSelectingTab = true
        defer {
            isSelectingTab = wasSelecting
            if !wasSelecting { applyPendingSharedTabs() }
        }
        // A Peek's stand-ins belong to the page they cover.
        finishPeekPromotion()
        historySwipe.cancel()
        cancelTabSwitch()
        siteInfoPopover.close()
        siteControlsPopover.close(); permissionCoordinator.cancel()
        if selectedID != id {
            selectedTab?.captureThumbnail()
            selectedTab.map(noteEditsOnLeaving)
        }
        hideLinkStatus()
        hidePalette()
        if selectedID != id {
            suspendPeek()
            finishPeekMotion()
            recedePage(false, along: nil)
        }
        let previousID = selectedID
        selectedID = id
        swapFindBar(from: previousID)
        attachVisiblePages()
        restoreSuspendedPeek()
        recentTabIDs.removeAll { $0 == id }; recentTabIDs.insert(id, at: 0)
        scheduleTabUse(id)
        if let tab = selectedTab {
            window?.makeFirstResponder(peekTab?.page.view ?? tab.page.view)
        }
        update(); layoutChrome()
        findBar.reattached()
    }
    func update() {
        pendingUpdate = nil
        syncedTabMetadata?.update(tabs: tabs)
        extensionTabsChanged()
        reconcileFullscreenSidebar()
        splitPeekReturns = splitPeekReturns.filter { id, undo in
            splitGroups.contains { $0.id == id && $0.contains(undo.tab.id) } && tabs.contains { $0 === undo.tab }
        }
        applyTheme()
        if let first = tabs.firstIndex(where: { !$0.pinned }), tabs[first...].contains(where: \.pinned) {
            tabs = tabs.filter(\.pinned) + tabs.filter { !$0.pinned }
        }
        sidebar.developerTabLook = developerTabLook
        sidebar.update(tabs: sidebarTabs, selected: sidebarSelectedTab, theme: theme, splits: sidebarSplitGroups)
        annotations.layout()
        refreshTabScroll()
        nowPlaying.setNeedsRefresh()
        refreshTabHoverCard(); refreshPullRequestTabs(); preloadGmailInbox(); preloadProtonMailInbox(); preloadChatInbox(); preloadCalendarAgenda()
        window?.title = (selectedTab?.title).map { "\($0) — Rise" } ?? "Rise"
        updateNavigationButtons()
        refreshAIChatPage()
        developerAddress.updateURL(selectedTab?.url?.absoluteString ?? "")
        errorSurface.isHidden = errorWebView == nil || errorWebView !== selectedTab?.page.view
        updatePlainBar()
        layoutChrome(); refreshTabSwitcher(); scheduleSave(); scheduleSwitcherPictures(); openTabLinks.refresh(shownPages)
        // Tabs opened, closed or moved go to tab sync at once; what changes within them, as a load's
        // title and history, waits for the save this schedules, rather than reading every tab's
        // history at every step of a load.
        if !isApplyingSharedTabs, let sync = tabSync, tabs.map(\.id) != syncedTabOrder {
            syncedTabOrder = tabs.map(\.id); sync.capture(sharedTabsSnapshot)
        }
        if hasPendingSharedTabs, canApplySharedTabs { applyPendingSharedTabs() }
    }
    @objc func newTab() { paletteCreatesTab = true; showPalette(text: "") }
    /// Searches the sidebar's tabs (`TabSearch.swift`), bringing a hidden sidebar out to do it.
    @objc func searchTabs() {
        cancelTabScroll()
        returnToTabs(animated: false)
        hidePalette()
        if !sidebarVisible { revealFloatingSidebar() }
        sidebar.beginTabSearch()
    }
    /// ⌘L and a click on a page bar's address edit the page commands act on, an open Peek's included.
    @objc func focusAddress() { paletteCreatesTab = false; showPalette(text: commandTab?.url?.absoluteString == "about:blank" ? "" : commandTab?.url?.absoluteString ?? "") }
    func showPalette(text: String) {
        cancelTabScroll()
        sidebar.endTabSearch()
        if searchProvider.isGoogle { googleSearchSuggestions.warmUp() }
        historySwipe.cancel(); cancelTabSwitch(); hideLinkStatus()
        siteControlsPopover.close(); extensionPopup?.close(); permissionCoordinator.cancel()
        let veilWasHidden = dismissArea.isHidden
        dismissArea.isHidden = false
        veil.dismiss = nil
        root.addSubview(veil, positioned: .below, relativeTo: dismissArea)
        palette.currentPage = selectedTab.flatMap { tab in tab.url.map { ($0.absoluteString, tab.favicon(for: theme)) } }
        palette.show(text: text, theme: theme, createsTab: paletteCreatesTab, centered: paletteLab == nil)
        layoutChrome()
        if veilWasHidden {
            if palette.isCentered { veil.show(theme: theme) }
            else { veil.hide(animated: false) }
        }
    }
    func hidePalette() {
        // The palette lab's palette stays open, whatever's clicked.
        guard paletteLab == nil else { return }
        googleSearchSuggestions.cancel(); suggestionFavicons.cancelPreview()
        guard palette.isPresented else { return }
        palette.hide(); dismissArea.isHidden = true; veil.hide(); window?.makeFirstResponder(commandTab?.page.view)
        refreshFullscreenNavigation()
        DispatchQueue.main.async { [weak self] in self?.applyPendingSharedTabs() }
    }
    func submitAddress(_ text: String, suggestion: AddressSuggestion?) {
        // The palette lab opens nothing: Enter starts the palette over.
        if paletteLab != nil { palette.dismiss?(); return }
        // An unmatched command stays in the palette rather than becoming a web search.
        if PaletteCommand.query(in: text) != nil, suggestion == nil { return }
        hidePalette()
        if let command = suggestion?.command { runPaletteCommand(command); return }
        if let request = suggestion?.assistantPrompt { submitAssistantPrompt(request); return }
        guard let url = suggestion?.url ?? AddressResolver.resolve(text, search: searchProvider.searchURL) else { return }
        // Typed or picked to go to, not searched for: what the address field learns most from.
        if url.host != searchProvider.searchURL(text)?.host { browsingHistory.recordTyped(url) }
        // Resolve again at activation time: an open tab may have navigated or
        // closed since the result was built. Never create an exact duplicate.
        if let existing = openTab(for: url) { select(existing.id); return }
        if paletteCreatesTab || commandTab == nil { addTab(url: url) }
        else if let peek = peekTab { peek.load(url) }
        else { errorWebView = nil; selectedTab?.load(url) }
    }
    @objc func closeCurrentTab() { closeSelectedTab(confirmingPinned: true) }
    /// ⌘W in a pinned tab asks first (PinnedTabClosing); Close Tab picked in the palette doesn't.
    func closeSelectedTab(confirmingPinned: Bool) {
        if peekTab != nil { closePeek(animated: true); return }
        guard let id = selectedID else { return }
        if confirmingPinned, asksBeforeClosingPinnedTab(id) { return }
        closeTab(id)
    }
    /// With `remembering` off, ⌘⇧T won't bring it back, as for a tab that's archived instead.
    func closeTab(_ id: UUID, remembering: Bool = true) {
        cancelTabScroll()
        historySwipe.cancel()
        cancelTabSwitch()
        discardPeek(for: id)
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Scrolled to the list's end, the tab above comes down into its place, and is the one shown.
        let atListEnd = sidebar.isScrolledToEnd
        pictureInPicture.remove(tabs[index]); tabMedia.remove(id)
        let partner = splitGroups.first { $0.contains(id) }.map { $0.leftID == id ? $0.rightID : $0.leftID }
        splitGroups.removeAll { $0.contains(id) }
        let tab = tabs.remove(at: index)
        if remembering { closedTabs.append(tab.saved) }
        assistantSubmissions.removeValue(forKey: id)?.cancel()
        pageFullscreen.setActive(false, in: tab.page.view)
        releaseHeldPages(of: tab)
        permissionCoordinator.cancel(for: tab.page.view)
        recentTabIDs.removeAll { $0 == id }
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        tab.cancelLoad(); tab.page.view.removeFromSuperview()
        findBars.removeValue(forKey: id)?.discard()
        if selectedID == id {
            selectedID = nil
            // Straight back to the tab it was opened from, as a pinned tab's links open at the list's
            // top rather than beside it, when that's where the user came from.
            let opener = tab.openedFrom.flatMap { id in recentTabIDs.first == id ? tabs.first { $0.id == id } : nil }
            if let partner, tabs.contains(where: { $0.id == partner }) { select(partner) }
            else if let opener { select(opener.id) }
            else if atListEnd, !tab.pinned, index > 0, !tabs[index-1].pinned { select(tabs[index-1].id) }
            else if !tabs.isEmpty { select(tabs[min(index, tabs.count-1)].id) }
        }
        attachVisiblePages(); update()
    }
    static let showsReopenedTabsKey = "Rise.ShowReopenedTabs"
    /// Whether ⌘⇧T switches to the tab it brings back; off unless set in rise://settings.
    var showsReopenedTabs: Bool { preferences.bool(forKey: Self.showsReopenedTabsKey) }
    func setShowsReopenedTabs(_ on: Bool) { preferences.set(on, forKey: Self.showsReopenedTabsKey) }
    /// ⌘⇧T brings the last closed tab back at the top, behind the current one unless set otherwise.
    @objc func reopenTab() {
        guard let id = closedTabs.last?.id else { return }
        reopenClosedTab(id, shows: showsReopenedTabs)
    }
    /// A tab picked from the recently closed list is shown. With no other tab open, it always is.
    func reopenClosedTab(_ id: UUID, shows: Bool = true) {
        guard let index = closedTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = reopened(closedTabs.remove(at: index)); tabs.insert(tab, at: 0)
        if shows || selectedTab == nil { select(tab.id) } else { update() }
    }
    /// A saved tab open again, used just now, with a new identity if its old one's closure has synced.
    func reopened(_ tab: SavedTab) -> BrowserTab {
        var saved = tab
        if tabSync?.isClosed(saved.id) == true { saved.id = UUID() }
        var use = saved.use ?? TabUse(lastUsed: Date())
        use.record(at: Date())
        saved.use = use
        return configure(BrowserTab(saved: saved))
    }
    @objc func goBack() { navigateHistory(.back) }
    @objc func goForward() { navigateHistory(.forward) }
    /// Buttons and menu shortcuts go straight to the page. Remove any in-flight
    /// swipe surface and arrow spring before navigation starts.
    private func settleBeforeHistoryNavigation() {
        historySwipe.cancel()
        developerMotion.cancel()
        historyArrows.forEach { $0.restore() }
        errorWebView = nil
    }
    private var historyArrows: [HistoryArrowButton] {
        (toolbarButtons+splitBarButtons+peekBarButtons).compactMap { $0 as? HistoryArrowButton }
    }
    private func navigateHistory(_ direction: HistoryDirection) {
        settleBeforeHistoryNavigation()
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
    /// What right-clicking a page bar's arrow lists: the pages that way in the history of the page
    /// the arrow acts on, nearest first, by title alone, as the swipe's list has them. Choosing one
    /// goes straight there.
    func historyMenu(for button: HistoryArrowButton) -> NSMenu? {
        let barTab = allPageBarTabs.first { $0.bar.navigation.contains { $0 === button } }?.tab
        guard let tab = peekTab ?? barTab ?? selectedTab else { return nil }
        let page = tab.page, direction = button.direction
        let entries = historyListEntries(for: page, direction, limit: TabNavigationHistory.maximumEntries)
        guard !entries.isEmpty else { return nil }
        if tab !== peekTab, tab.id != selectedID { select(tab.id) }
        let menu = NSMenu()
        for (offset, entry) in entries.enumerated() {
            let item = menuItem(Self.historyMenuTitle(entry.title)) { [weak self, weak tab] in
                guard let self, let tab, tab.page === page else { return }
                self.goThroughHistory(direction, steps: offset+1, in: tab)
            }
            if item.title != entry.title { item.toolTip = entry.title }
            menu.addItem(item)
        }
        return menu
    }
    /// How wide a title in an arrow's history menu may be, in points of the menu's font.
    static let historyMenuTitleWidth: CGFloat = 420
    /// A title as an arrow's history menu shows it: a long one shortened in the middle, keeping
    /// its start and its end (often the site's name), as Safari's menu does.
    static func historyMenuTitle(_ title: String, width: CGFloat = historyMenuTitleWidth) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        let measure = { (text: String) in (text as NSString).size(withAttributes: [.font: font]).width }
        guard measure(title) > width else { return title }
        let characters = Array(title)
        func shortened(keeping count: Int) -> String {
            let head = (count+1)/2, tail = count/2
            let start = String(characters.prefix(head)).trimmingCharacters(in: .whitespaces)
            let end = String(characters.suffix(tail)).trimmingCharacters(in: .whitespaces)
            return start+"…"+end
        }
        var low = 0, high = characters.count-1
        while low < high {
            let middle = (low+high+1)/2
            if measure(shortened(keeping: middle)) <= width { low = middle } else { high = middle-1 }
        }
        return shortened(keeping: low)
    }
    /// Goes `steps` pages that way in the tab's page's own history, as picking from its list does.
    func goThroughHistory(_ direction: HistoryDirection, steps: Int, in tab: BrowserTab) {
        settleBeforeHistoryNavigation()
        let page = tab.page
        if tab !== peekTab { tab.cancelLoad() }
        for _ in 0..<steps {
            guard direction == .back ? page.canGoBack : page.canGoForward else { break }
            if direction == .back { page.goBack() } else { page.goForward() }
        }
        update()
    }
    /// Reloads without the cache, refetching the page and everything it loads.
    @objc func hardReload() {
        adBlockPrompt.noteReload(); historySwipe.cancel(); errorWebView = nil; selectedReloadButton?.armAnimation()
        commandTab?.isHardReloading = true
        if let tab = commandTab, tab.page.url == nil, let url = tab.requestedURL { tab.load(url) } else { commandTab?.page.reloadIgnoringCache() }
        update()
    }
    @objc func reload() { adBlockPrompt.noteReload(); historySwipe.cancel(); errorWebView = nil; selectedReloadButton?.armAnimation(); if commandTab?.isLoading == true { commandTab?.cancelLoad() } else if let tab = commandTab, tab.page.url == nil, let url = tab.requestedURL { tab.load(url) } else { commandTab?.page.reload() }; update() }
    @objc func retry() { errorWebView = nil; if let url = selectedTab?.url { selectedTab?.load(url) }; update() }
    @objc func toggleSidebar() {
        if keepPeekedSidebar() { return }
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
    @objc func toggleDeveloper() { toggleDeveloperMode(from: NSApp.currentEvent) }
    /// Holding the shortcut toggles once: its key's repeats don't toggle it back and forth.
    func toggleDeveloperMode(from event: NSEvent?) {
        if let event, event.type == .keyDown, event.isARepeat { return }
        guard let tab = selectedTab else { return }
        toggleDeveloperMode(for: tab)
    }
    func toggleDeveloperMode(for tab: BrowserTab) {
        let visible = tab.id == selectedID
        if visible {
            historySwipe.cancel()
            window?.makeFirstResponder(tab.page.view); siteInfoPopover.close()
        }
        let from = visible ? developerMotion.progress(for: tab.id, enabled: tab.developer) : 0
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
    @objc func zoomIn() { setPageZoom(PageZoom.next(after: commandTab?.page.zoom ?? 1)) }
    @objc func zoomOut() { setPageZoom(PageZoom.previous(before: commandTab?.page.zoom ?? 1)) }
    @objc func actualSize() { setPageZoom(1, resetting: true) }
    /// The page's zoom, shown by the page bar's zoom button while it isn't 100%.
    func setPageZoom(_ zoom: CGFloat, resetting: Bool = false) {
        guard let tab = commandTab else { return }
        tab.page.zoom = zoom
        let applied = tab.page.zoom
        selectedBar.setPageZoom(applied, animated: true)
        selectedBar.showNotice("\(resetting ? "Reset" : "Set") page zoom to \(PageZoom.text(applied))",
                               image: TablerIcon.image(TablerIcon.zoomIn, size: 12, description: "Page zoom"))
    }
    func scheduleSave() {
        saveWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.save(waiting: false) }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: work)
    }
    /// Saves everything at once and waits for it, as on quitting.
    func saveNow() { save(waiting: true) }
    /// Without `waiting`, as after changes: the main thread only gathers what to save; the session
    /// and history, megabytes of JSON, are encoded and written in the background, as tab sync's
    /// cache is, so a page's load bar and Reload button don't stall while they're written.
    private func save(waiting: Bool) {
        saveWork?.cancel(); saveWork = nil
        // Quitting keeps each page exactly as it is, scrolled where it is.
        if waiting { for tab in tabs { (tab.page as? ChromiumPage)?.forgetSavedState() } }
        let saved = tabs.map(\.saved)
        if !isApplyingSharedTabs, let sync = tabSync { syncedTabOrder = tabs.map(\.id); sync.capture(sharedTabs(from: saved)) }
        if waiting { tabSync?.flush() }
        suggestionFavicons.save(); tabPictures.save()
        do {
            try siteSearchLearner.searches.save()
            if waiting { try browsingHistory.save() } else { browsingHistory.saveInBackground() }
        } catch { NSLog("Rise history save failed: %@", error.localizedDescription) }
        let state = BrowserSession(tabs: saved, selectedID: selectedID, theme: automaticTheme ? Self.automaticThemeName : theme.rawValue, sidebarWidth: sidebarWidth, splitGroups: splitGroups, peeks: savedPeeks)
        let changed = state != lastSaved
        if changed { lastSaved = state }
        nonisolated(unsafe) let session = state
        let url = sessionURL
        let write: @Sendable () -> Void = { [weak self] in
            guard changed else { return }
            do { try SessionStorage.write(session, to: url) }
            catch {
                NSLog("Rise session save failed: %@", error.localizedDescription)
                // Tried again at the next save.
                Task { @MainActor in self?.lastSaved = nil }
            }
        }
        if waiting {
            SessionStorage.writer.sync(execute: write)
            BackgroundFiles.flush(); archivedTabs.flush(); tabPictures.flush()
        } else { SessionStorage.writer.async(execute: write) }
    }
}

@MainActor extension BrowserController {
    /// Whether a tab's media is paused, or nil when it has none. A YouTube video
    /// page answers for its video; any other tab, for whatever it last played with sound.
    func playbackPaused(_ id: UUID) -> Bool? { pictureInPicture.playbackPaused(id) ?? tabMedia.paused(id) }
    func togglePlayback(_ id: UUID) {
        if pictureInPicture.playbackPaused(id) != nil { pictureInPicture.togglePlayback(id) } else { tabMedia.togglePlayback(id) }
    }
    func refreshPlayback(_ id: UUID) { sidebar.rows[id]?.setPlayback(paused: playbackPaused(id)); nowPlaying.setNeedsRefresh() }
}
