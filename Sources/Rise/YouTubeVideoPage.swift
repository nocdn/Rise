import Foundation

enum YouTubeVideoPage {
    static func containsVideo(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
        if url.path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } == true
        }
        return ["/shorts/", "/live/", "/embed/"].contains { url.path.hasPrefix($0) && url.path.count > $0.count }
    }
}
