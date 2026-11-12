import Foundation

/// What Rise sets in the profile's `Local State` before the engine reads it.
///
/// Chrome's experiments (rise://flags) that Rise turns on, once each, so they show as Enabled
/// there and stay however they're set after. And ⌘Q quits at once, as in any other app: Chrome
/// keeps its "Hold ⌘Q to Quit" warning on unless told otherwise, and Rise has no menu item for it.
enum ChromiumFlags {
    /// As rise://flags stores them: the flag's name, `@1` for Enabled.
    static let defaults = ["canvas-draw-element@1"]
    static let appliedKey = "Rise.DefaultFlags"

    static func prepare(_ profile: URL, preferences: UserDefaults = .standard) {
        let applied = Set(preferences.stringArray(forKey: appliedKey) ?? [])
        let pending = defaults.filter { !applied.contains($0) }
        let file = profile.appendingPathComponent("Local State")
        var state: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            // An unreadable one is left for Chromium, and tried again next time.
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            state = read
        }
        var browser = state["browser"] as? [String: Any] ?? [:]
        let confirmsQuit = browser["confirm_to_quit"] as? Bool != false
        guard !pending.isEmpty || confirmsQuit else { return }
        var flags = browser["enabled_labs_experiments"] as? [String] ?? []
        let name = { (flag: String) in flag.split(separator: "@").first.map(String.init) ?? flag }
        // A flag already set either way is left as it is.
        for flag in pending where !flags.contains(where: { name($0) == name(flag) }) { flags.append(flag) }
        if !pending.isEmpty { browser["enabled_labs_experiments"] = flags }
        browser["confirm_to_quit"] = false
        state["browser"] = browser
        guard let data = try? JSONSerialization.data(withJSONObject: state), (try? data.write(to: file, options: .atomic)) != nil else { return }
        if !pending.isEmpty { preferences.set(Array(applied.union(pending)).sorted(), forKey: appliedKey) }
    }
}
