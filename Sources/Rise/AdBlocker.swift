import Foundation
import RiseChromium

/// Ads, blocked by uBlock Origin, which Rise carries (scripts/build.sh) and the engine loads as
/// one of Chrome's own extensions; turned off, the engine unloads it.
@MainActor final class AdBlocker {
    static let preferenceKey = "Rise.AdBlocking"
    private let preferences: UserDefaults
    private(set) var enabled: Bool
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.object(forKey: Self.preferenceKey) == nil || preferences.bool(forKey: Self.preferenceKey)
        RCAdBlock.enabled = enabled
    }
    /// Turns blocking on or off; the task ends once uBlock Origin is loaded or unloaded to match.
    func setEnabled(_ value: Bool) -> Task<Void, Error> {
        enabled = value; preferences.set(value, forKey: Self.preferenceKey)
        return Task { await withCheckedContinuation { done in RCAdBlock.setEnabled(value) { done.resume() } } }
    }
}
