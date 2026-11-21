import UIKit
import ImageIO

/// Look up only the public product ID and storefront, never the page's query or cookies.
/// Artwork stays in a bounded memory cache; private browsing adds nothing to disk.
@MainActor final class AppStoreArtwork {
    static let shared = AppStoreArtwork()
    private let session: URLSession
    private let images = NSCache<NSString, UIImage>()

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 4; configuration.timeoutIntervalForResource = 8
        self.session = session ?? URLSession(configuration: configuration)
        images.countLimit = 64
    }

    static func lookupURL(for link: AppStoreLink) -> URL {
        let first = link.webURL.path.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        let country = first.count == 2 && first.utf8.allSatisfy({ (97...122).contains($0) }) ? (first == "uk" ? "gb" : first) : "us"
        var parts = URLComponents(string: "https://itunes.apple.com/lookup")!
        parts.queryItems = [URLQueryItem(name: "id", value: link.appID), URLQueryItem(name: "country", value: country),
                            URLQueryItem(name: "entity", value: "software")]
        return parts.url!
    }

    func image(for link: AppStoreLink) async -> UIImage? {
        let lookup = Self.lookupURL(for: link), key = lookup.absoluteString as NSString
        if let image = images.object(forKey: key) { return image }
        do {
            let (data, response) = try await session.data(from: lookup)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
                  let result = try JSONDecoder().decode(Lookup.self, from: data).results.first(where: { String($0.trackId) == link.appID && $0.kind == "software" }),
                  let artwork = result.artworkUrl100, artwork.scheme == "https",
                  let host = artwork.host?.lowercased(), host.hasSuffix(".mzstatic.com"),
                  artwork.user == nil, artwork.password == nil, artwork.port == nil else { return nil }
            let (file, artworkResponse) = try await session.download(from: artwork)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard (artworkResponse as? HTTPURLResponse)?.statusCode == 200,
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            let image = UIImage(cgImage: thumbnail)
            images.setObject(image, forKey: key)
            return image
        } catch { return nil }
    }

    private struct Lookup: Decodable {
        let results: [Product]
        struct Product: Decodable {
            let trackId: Int64
            let kind: String?
            let artworkUrl100: URL?
        }
    }
}
