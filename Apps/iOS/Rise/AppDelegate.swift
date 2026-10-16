import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let syncs = application.connectedScenes.compactMap { scene in
            let delegate = scene.delegate as? SceneDelegate
            return (delegate?.window?.rootViewController as? BrowserViewController)?.tabSync
        }
        Task {
            var synced = false
            for sync in syncs { synced = await sync.refreshAndWait() || synced }
            completionHandler(synced ? .newData : .noData)
        }
    }
}
