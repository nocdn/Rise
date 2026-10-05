import AppKit

/// Keep WebKit's native engine/platform tokens, while identifying this as a
/// desktop Safari-compatible browser rather than a generic embedded web view.
@MainActor enum BrowserIdentity {
    static let applicationName: String = {
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0) }
        let version = safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "17.0"
        return "Version/\(version) Safari/605.1.15 Rise/1.0"
    }()
}
