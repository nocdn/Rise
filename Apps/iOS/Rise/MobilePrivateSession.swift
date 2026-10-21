import WebKit

/// Released after the last private tab closes. A later private tab starts with fresh storage
/// and fresh in-memory protection preferences, even if an outgoing card is still animating.
@MainActor final class MobilePrivateSession {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let adBlocker = MobileAdBlocker(preferences: nil)
}
