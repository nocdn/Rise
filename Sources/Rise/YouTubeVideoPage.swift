import Foundation

enum YouTubeVideoPage {
    static func isYouTube(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
    /// YouTube puts the unread notification count in front of every title, as
    /// in "(7) Title" or "(9+) Title". A year such as "(2024)" is left alone.
    static func removingNotificationCount(from title: String, url: URL?) -> String {
        guard isYouTube(url), let range = title.range(of: #"^\(\d{1,2}\+?\)\s+"#, options: .regularExpression),
              range.upperBound < title.endIndex else { return title }
        return String(title[range.upperBound...])
    }
    static func containsVideo(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", isYouTube(url) else { return false }
        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } == true
        }
        return ["/shorts/", "/live/", "/embed/"].contains { url.path.hasPrefix($0) && url.path.count > $0.count }
    }
}
