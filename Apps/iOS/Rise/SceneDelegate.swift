import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        #if DEBUG
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sync = SharedTabsSync(cacheURL: support.appendingPathComponent("SharedTabs.json"))
        let action = connectionOptions.shortcutItem.flatMap(HomeScreenAction.init(shortcut:))
        let browser = BrowserViewController(opensSearchOnFirstAppearance: action == nil, sessionStore: .shared, tabSync: sync,
            previewCacheURL: URL.cachesDirectory.appendingPathComponent("TabPreviews"))
        window.rootViewController = browser
        self.window = window
        if let action { browser.quickActions.open(action) }
        window.makeKeyAndVisible()
        browser.openLinks(connectionOptions.urlContexts.map(\.url))
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
        (window?.rootViewController as? BrowserViewController)?.openLinks(URLContexts.map(\.url))
    }

    func sceneWillResignActive(_ scene: UIScene) {
        if let window { (window.rootViewController as? BrowserViewController)?.quickActions.setActive(false, in: window) }
        (window?.rootViewController as? BrowserViewController)?.panelMotion.stop()
        (window?.rootViewController as? BrowserViewController)?.setTabPreviewsActive(false)
        saveSession()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { saveSession() }
    func sceneDidDisconnect(_ scene: UIScene) { saveSession() }
    func sceneDidBecomeActive(_ scene: UIScene) {
        let browser = window?.rootViewController as? BrowserViewController
        if let window { browser?.quickActions.setActive(true, in: window) }
        browser?.applyPendingChanges()
        browser?.tabSync?.refresh()
        browser?.setTabPreviewsActive(true)
    }

    private func saveSession() {
        (window?.rootViewController as? BrowserViewController)?.saveSession(flush: true)
    }
}
