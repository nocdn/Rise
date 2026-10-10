import Foundation

enum YouTubeVideoPage {
    static func isYouTube(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
    static func containsVideo(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", isYouTube(url) else { return false }
        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } == true
        }
        return ["/shorts/", "/live/", "/embed/"].contains { url.path.hasPrefix($0) && url.path.count > $0.count }
    }
}
