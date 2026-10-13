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
        window.rootViewController = BrowserViewController(opensSearchOnFirstAppearance: true)
        self.window = window
        window.makeKeyAndVisible()
    }
}
