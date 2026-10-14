import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        #if DEBUG
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
        window.rootViewController = BrowserViewController(opensSearchOnFirstAppearance: true, sessionStore: .shared, tabSync: sync,
            previewCacheURL: URL.cachesDirectory.appendingPathComponent("TabPreviews"))
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? BrowserViewController)?.setTabPreviewsActive(false)
        saveSession()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { saveSession() }
    func sceneDidDisconnect(_ scene: UIScene) { saveSession() }
    func sceneDidBecomeActive(_ scene: UIScene) {
        let browser = window?.rootViewController as? BrowserViewController
        browser?.applyPendingSharedTabs()
        browser?.tabSync?.refresh()
        browser?.setTabPreviewsActive(true)
    }

    private func saveSession() {
        (window?.rootViewController as? BrowserViewController)?.saveSession(flush: true)
    }
}
