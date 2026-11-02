import Foundation

/// An X player streams a MediaSource blob, but also supplies complete MP4 renditions.
/// Read the clicked player's own metadata only when downloading; never save the stream
/// blob (which isn't a file), guess a CDN path, or choose another video's network request.
enum ContextMenuVideoSource {
    @MainActor static func resolve(_ source: URL, in page: ChromiumPage) async -> URL {
        guard source.scheme == "blob", let host = page.url?.host?.lowercased(),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host) else { return source }
        let variants = try? await page.evaluate(xVariants, arguments: ["source": source.absoluteString], in: nil, world: .page)
        return preferredVariant(variants as? [[String: Any]] ?? []) ?? source
    }

    static func preferredVariant(_ variants: [[String: Any]]) -> URL? {
        variants.compactMap { variant -> (URL, Double)? in
            guard variant["type"] as? String == "video/mp4", let text = variant["src"] as? String,
                  let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "video.twimg.com",
                  url.user == nil, url.password == nil, url.port == nil, url.pathExtension.lowercased() == "mp4" else { return nil }
            let bitrate = (variant["bitrate"] as? NSNumber)?.doubleValue ?? 0
            return (url, bitrate.isFinite ? max(0, bitrate) : 0)
        }.max { $0.1 < $1.1 }?.0
    }

    static let xVariants = #"""
    const video = [...document.querySelectorAll('video')].find(video => video.currentSrc === source);
    if (!video) return [];
    let fiber;
    for (let node = video, depth = 0; node && depth < 12 && !fiber; node = node.parentElement, depth++) {
      const key = Object.keys(node).find(key => key.startsWith('__reactFiber$') || key.startsWith('__reactInternalInstance$'));
      if (key) fiber = node[key];
    }
    // The nearest player's props contain its variants, including the progressive MP4s.
    // A bounded walk tolerates React wrapper changes without searching the whole app's state.
    for (let depth = 0; fiber && depth < 24; fiber = fiber.return, depth++) {
      const variants = fiber.memoizedProps?.variants;
      if (Array.isArray(variants)) return variants.slice(0, 32).map(item => ({src:item.src, type:item.type, bitrate:item.bitrate}));
    }
    return [];
    """#
}
