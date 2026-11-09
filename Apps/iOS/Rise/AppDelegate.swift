import UIKit
import os

/// Marks along a launch for Instruments' Points of Interest: the scene connecting, the browser
/// appearing, search taking focus, the keyboard first showing, and each search update as typing
/// goes on. They cost next to nothing unless something is recording. See docs/iOSLaunchPerformance.md.
@MainActor enum LaunchSignposts {
    static let signposter = OSSignposter(subsystem: "dev.bartosz.Rise.iOS", category: .pointsOfInterest)
    private static var keyboardObserver: NSObjectProtocol?
    static func event(_ name: StaticString) { signposter.emitEvent(name) }
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
    /// The first keyboard after launch is the point search is ready to type into.
    static func watchFirstKeyboard() {
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                event("Keyboard shown")
                keyboardObserver.map(NotificationCenter.default.removeObserver); keyboardObserver = nil
            }
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LaunchSignposts.event("Did finish launching")
        LaunchSignposts.watchFirstKeyboard()
        // The popup rules compile about 2,000 patterns. Starting now on another core means
        // they're usually ready by the time the first page is prepared, instead of the main
        // thread compiling them while the browser is built.
        DispatchQueue.global(qos: .userInitiated).async { _ = PopupDestinationRules.bundled }
        // The page Rise was left on, decoded while the browser is built (`LaunchCover`).
        LaunchCover.prefetch()
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
