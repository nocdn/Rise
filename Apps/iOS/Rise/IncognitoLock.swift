import Foundation
import LocalAuthentication

/// Locked incognito mode: Face ID, or the passcode, before the tab switcher shows the private tabs.
enum IncognitoLock {
    private static let key = "LockedIncognitoMode"

    /// On unless turned off in App settings.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Asks for Face ID, falling back to the passcode. Without a passcode there's nothing to lock
    /// with, so the tabs show.
    @MainActor static func authenticate(_ done: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { done(true); return }
        Task { @MainActor in
            let unlocked = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                             localizedReason: "Show your incognito tabs")) ?? false
            done(unlocked)
        }
    }
}
