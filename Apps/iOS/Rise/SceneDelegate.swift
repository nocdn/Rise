import UIKit
import WebKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = RiseWindow(windowScene: scene)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(PageLoadingAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            PageLoadingAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(LinkPreviewAudit.argument) {
            let controller = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            LinkPreviewAudit.run(in: controller)
            return
        }
        if PasskeyDiagnostic.requested {
            window.rootViewController = PasskeyDiagnostic()
            self.window = window
            window.makeKeyAndVisible()
            return
        }
        if ProcessInfo.processInfo.arguments.contains(PopupBlockingAudit.argument) {
            let controller = BrowserViewController(startURL: nil, adBlocker: MobileAdBlocker(preferences: nil),
                isPrivateBrowsing: ProcessInfo.processInfo.arguments.contains("-RisePopupPrivate"), websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            PopupBlockingAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(SelectionTimeMenuAudit.argument) {
            let controller = BrowserViewController(startURL: nil,websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            SelectionTimeMenuAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(SelectionExplanationAudit.argument) {
            let controller = BrowserViewController(startURL: nil,websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            SelectionExplanationAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(TorphTextAudit.argument) {
            let controller = BrowserViewController(startURL: nil,websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            TorphTextAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(GitHubStarAudit.argument)
            || ProcessInfo.processInfo.arguments.contains(GitHubStarAudit.deviceArgument) {
            let store: WKWebsiteDataStore = ProcessInfo.processInfo.arguments.contains(GitHubStarAudit.deviceArgument) ? .default() : .nonPersistent()
            let controller = BrowserViewController(startURL: nil, websiteDataStore: store)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            GitHubStarAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(SelectionFontInfoAudit.argument) {
            let controller = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            SelectionFontInfoAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(PageImageActionsAudit.argument) {
            let controller = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            PageImageActionsAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(ImageContextMenuAudit.argument) {
            let controller = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            ImageContextMenuAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(PageTranslationAudit.argument) || ProcessInfo.processInfo.arguments.contains(PageConnectionAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            if ProcessInfo.processInfo.arguments.contains(PageConnectionAudit.argument) { PageConnectionAudit.run(in: controller) }
            else { PageTranslationAudit.run(in: controller) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains(FullPageScreenshotAudit.argument) {
            let controller = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            FullPageScreenshotAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(AutofillAudit.argument) {
            let controller = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            AutofillAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(AIPromptsAudit.argument) {
            let controller = HistoryPanelAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            AIPromptsAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(PrivateTabsAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            PrivateTabsAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(TabArchiveAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            TabArchiveAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(TabSyncAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            TabSyncAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(TabPreviewAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            TabPreviewAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(DownloadActivityAudit.argument) {
            let controller = HistoryPanelAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            DownloadActivityAudit.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains(HistorySelectionAudit.argument) {
            let controller = HistoryPanelAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            HistorySelectionAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(HistoryRowSwipeAudit.argument) {
            let controller = HistoryPanelAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            HistoryRowSwipeAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(HistoryPanelAudit.argument) {
            let controller = HistoryPanelAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            HistoryPanelAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(SummariseBarAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            SummariseBarAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(HomeScreenActionsAudit.argument) {
            let controller = HomeScreenActionsAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            HomeScreenActionsAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(PanelCloseGapAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            PanelCloseGapAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(OpenHereAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            OpenHereAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(MenuAddressTapAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            MenuAddressTapAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(PanelMotionAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            PanelMotionAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(DownloadsPanelAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            DownloadsPanelAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(DownloadFlightAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            DownloadFlightAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(TabDeckAudit.argument) {
            let controller = InteractionAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            TabDeckAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(BrowserRecoveryAudit.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            BrowserRecoveryAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(AddressSuggestionsAudit.argument) {
            let controller = AddressSuggestionsAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            AddressSuggestionsAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(MobileFaviconAudit.argument) {
            let controller = AddressSuggestionsAudit.makeBrowser()
            window.rootViewController = controller; self.window = window; window.makeKeyAndVisible()
            MobileFaviconAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(InteractionAudit.argument) {
            let controller = InteractionAudit.makeBrowser()
            window.rootViewController = controller
            self.window = window
            window.makeKeyAndVisible()
            InteractionAudit.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(MenuColourPreview.argument) {
            let controller = BrowserViewController(startURL: nil)
            controller.overrideUserInterfaceStyle = .light
            window.rootViewController = controller
            self.window = window
            window.makeKeyAndVisible()
            MenuColourPreview.run(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(CookieConsentAudit.argument) {
            let controller = BrowserViewController(startURL: nil, adBlocker: CookieConsentAudit.makeBlocker())
            window.rootViewController = controller
            self.window = window
            window.makeKeyAndVisible()
            CookieConsentAudit.runIfRequested(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(AdBlockingAudit.argument) {
            let controller = BrowserViewController(startURL: nil, adBlocker: AdBlockingAudit.makeBlocker())
            window.rootViewController = controller
            self.window = window
            window.makeKeyAndVisible()
            AdBlockingAudit.runIfRequested(in: controller)
            return
        }
        if ProcessInfo.processInfo.arguments.contains(SummariseReplay.argument) {
            let controller = BrowserViewController(startURL: nil)
            window.rootViewController = controller
            self.window = window
            window.makeKeyAndVisible()
            SummariseReplay.runIfRequested(in: controller)
            return
        }
        #endif
        let connecting = LaunchSignposts.signposter.beginInterval("Scene connect")
        defer { LaunchSignposts.signposter.endInterval("Scene connect", connecting) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sync = LaunchSignposts.interval("Tab sync cache") { SharedTabsSync(cacheURL: support.appendingPathComponent("SharedTabs.json")) }
        let urls = connectionOptions.urlContexts.map(\.url)
        let action = connectionOptions.shortcutItem.flatMap(HomeScreenAction.init(shortcut:))
            ?? (urls.contains(where: Self.isDownloadsLink) ? .downloads : nil)
        let browser = LaunchSignposts.interval("Browser init") {
            BrowserViewController(opensSearchOnFirstAppearance: action == nil, sessionStore: .shared, tabSync: sync,
                previewCacheURL: URL.cachesDirectory.appendingPathComponent("TabPreviews"))
        }
        window.rootViewController = browser
        self.window = window
        if let action { browser.quickActions.open(action) }
        // Links go first: search opens as the window appears, and an incoming link replaces it.
        browser.openLinks(urls.filter { $0.scheme?.lowercased() != "rise" })
        window.makeKeyAndVisible()
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let action = HomeScreenAction(shortcut: shortcutItem),
              let browser = window?.rootViewController as? BrowserViewController else { completionHandler(false); return }
        browser.quickActions.open(action)
        completionHandler(true)
    }

    /// A link opened from another app, with Rise as the default browser.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let browser = window?.rootViewController as? BrowserViewController else { return }
        let urls = URLContexts.map(\.url)
        if urls.contains(where: Self.isDownloadsLink) { browser.quickActions.open(.downloads) }
        browser.openLinks(urls.filter { $0.scheme?.lowercased() != "rise" })
    }

    private static func isDownloadsLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "rise" && url.host?.lowercased() == "downloads"
    }

    func sceneWillResignActive(_ scene: UIScene) {
        #if DEBUG
        if PasskeyDiagnostic.keepsAwake { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        (window?.rootViewController as? BrowserViewController)?.prepareForInactivity()
        (window?.rootViewController as? BrowserViewController)?.cancelListening()
        if let window { (window.rootViewController as? BrowserViewController)?.quickActions.setActive(false, in: window) }
        (window?.rootViewController as? BrowserViewController)?.panelMotion.stop()
        (window?.rootViewController as? BrowserViewController)?.setTabPreviewsActive(false)
        saveSession()
    }
    private var enteredBackground: Date?
    private static let reconnectAfter: TimeInterval = 60
    func sceneDidEnterBackground(_ scene: UIScene) {
        enteredBackground = Date()
        (window?.rootViewController as? BrowserViewController)?.saveLaunchCover()
        (window?.rootViewController as? BrowserViewController)?.backgroundSearch.enteredBackground()
        (window?.rootViewController as? BrowserViewController)?.lockPrivateTabs()
        saveSession()
    }
    func sceneDidDisconnect(_ scene: UIScene) { saveSession() }
    func sceneDidBecomeActive(_ scene: UIScene) {
        #if DEBUG
        if PasskeyDiagnostic.keepsAwake { UIApplication.shared.isIdleTimerDisabled = true }
        #endif
        let browser = window?.rootViewController as? BrowserViewController
        if let window { browser?.quickActions.setActive(true, in: window) }
        browser?.applyPendingChanges()
        // The UK county of a card picked offline, or before Rise looked counties up.
        AutofillStore.shared.lookUpCounties()
        browser?.backgroundSearch.becameActive { [weak browser] in browser?.reopenSearchAfterInactivity() }
        // Back after a while, sync starts over as a launch does: a phone left suspended overnight
        // was seen not to fetch on returning, while a fresh start always does.
        if let enteredBackground, Date().timeIntervalSince(enteredBackground) >= Self.reconnectAfter { browser?.tabSync?.reconnect() }
        else { browser?.tabSync?.refresh() }
        enteredBackground = nil
        browser?.tabArchiveTick()
        browser?.setTabPreviewsActive(true)
        browser?.resumeLockedSwitcher()
    }

    private func saveSession() {
        (window?.rootViewController as? BrowserViewController)?.saveSession(flush: true)
    }
}

/// Shakes that nothing on screen used, such as a search field clearing itself, reach the
/// window: the browser in front brings back a closed tab, or the system's shake to undo runs.
final class RiseWindow: UIWindow {
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, let browser = frontBrowser, browser.reopenClosedTab() else {
            return super.motionEnded(motion, with: event)
        }
    }

    private var frontBrowser: BrowserViewController? {
        var front = rootViewController
        while let presented = front?.presentedViewController { front = presented }
        func browser(in controller: UIViewController) -> BrowserViewController? {
            controller as? BrowserViewController ?? controller.children.lazy.compactMap(browser).first
        }
        return front.flatMap(browser)
    }
}
