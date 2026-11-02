import UIKit

/// Bounded, persistent first-party icons. No third-party favicon service receives typed URLs.
@MainActor final class MobileSuggestionFavicons {
    private let storageURL: URL?
    private let allowsNetwork: Bool
    private let session: URLSession
    private var images: [String: UIImage] = [:]
    private var bytes: [String: MobileFavicon.Saved] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempted = Set<String>()
    private var preview: Task<Void, Never>?
    private let writer = DispatchQueue(label: "Rise.SuggestionIcons", qos: .utility)
    var onLoad: (() -> Void)?

    init(storageURL: URL?, session: URLSession? = nil, allowsNetwork: Bool = true) {
        self.allowsNetwork = allowsNetwork
        self.storageURL = storageURL
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        self.session = session ?? URLSession(configuration: config)
        if let storageURL, let data = try? Data(contentsOf: storageURL), data.count <= 16_000_000 {
            if let saved = try? JSONDecoder().decode([String: MobileFavicon.Saved].self, from: data) {
                for (key, value) in saved.sorted(by: { $0.key < $1.key }).prefix(128) {
                    if let image = value.image {
                        bytes[key] = value; images[key] = image
                        if value.dark != nil { attempted.insert(key) }
                    }
                }
            } else if let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
                // Old single-image caches remain usable while their appearance variants load.
                for (key, value) in saved.sorted(by: { $0.key < $1.key }).prefix(128) {
                    remember(MobileFavicon.decode(value), for: URL(string: key))
                }
            }
        }
    }
    static func origin(_ url: URL?) -> String? {
        guard let url, url.user == nil, url.password == nil, let site = BrowsingHistory.site(of: url) else { return nil }
        return site.absoluteString
    }
    func remember(_ image: UIImage?, for url: URL?) {
        guard let image, let origin = Self.origin(url), let saved = MobileFavicon.Saved(image) else { return }
        // A late /favicon.ico or a restored tab must not replace sharper artwork.
        if let known = images[origin], Self.pixels(known) > Self.pixels(image) { return }
        // A restored tab may still have a single icon; keep any dark artwork already learned.
        if saved.dark == nil, let dark = bytes[origin]?.dark.flatMap(MobileFavicon.decode) {
            let combined = MobileFavicon.adaptive(light: image, dark: dark)
            images[origin] = combined; bytes[origin] = MobileFavicon.Saved(combined)
        } else {
            images[origin] = image; bytes[origin] = saved
        }
        while images.count > 128, let oldest = images.keys.sorted().first { images[oldest] = nil; bytes[oldest] = nil }
    }
    private static func pixels(_ image: UIImage) -> Int {
        let image = MobileFavicon.variant(image, style: .light)
        return min(image.cgImage?.width ?? 0, image.cgImage?.height ?? 0)
    }
    /// Typing a literal address waits for a quiet moment before fetching its public site's icon.
    func previewCandidate(_ url: URL?) {
        preview?.cancel(); preview = nil
        guard allowsNetwork, let url, let origin = Self.origin(url), images[origin] == nil,
              !AddressResolver.isLocal(url), let host = url.host,
              let suffix = host.split(separator: ".").last, suffix.count >= 2 else { return }
        preview = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            _ = self?.image(for: url)
        }
    }
    func image(for url: URL?, fetch: Bool = true) -> UIImage? {
        guard let url, let origin = Self.origin(url) else { return nil }
        // Only complete public domains are fetched. In-progress/local addresses keep the placeholder.
        guard fetch, allowsNetwork, !AddressResolver.isLocal(url), let host = url.host, host.contains("."),
              !host.hasSuffix(".test"), !host.hasSuffix(".example"), !host.hasSuffix(".invalid"),
              attempted.insert(origin).inserted else { return images[origin] }
        tasks[origin] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[origin] = nil }
            let root = URL(string: origin)!
            if let lightURL = FaviconDiscovery.lightIcon(for: root), let darkURL = FaviconDiscovery.darkIcon(for: root) {
                async let light = load(lightURL)
                async let dark = load(darkURL)
                let pair = await (light, dark)
                if let light = pair.0 ?? pair.1 {
                    store(MobileFavicon.adaptive(light: light, dark: pair.1), origin: origin); return
                }
            }
            var light = images[origin]
            if light == nil, let fallback = URL(string: "/favicon.ico", relativeTo: root)?.absoluteURL {
                light = await load(fallback)
                if let light { remember(light, for: root); onLoad?() }
            }
            // Even when favicon.ico loads, metadata can declare a separate dark icon.
            var dark: UIImage?
            if let html = await data(from: root) {
                let lightURL = FaviconDiscovery.icon(in: html, baseURL: root)
                let darkURL = FaviconDiscovery.icon(in: html, baseURL: root, dark: true)
                if let lightURL, let declared = await load(lightURL) { light = declared }
                if let darkURL, darkURL != lightURL { dark = await load(darkURL) }
            }
            if let light = light ?? dark { store(MobileFavicon.adaptive(light: light, dark: dark), origin: origin) }
        }
        return images[origin]
    }
    private func load(_ url: URL) async -> UIImage? {
        guard let data = await data(from: url) else { return nil }
        return MobileFavicon.decode(data)
    }
    private func data(from url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request), !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { return nil }
        return data
    }
    private func store(_ image: UIImage, origin: String) {
        remember(image, for: URL(string: origin))
        save(); onLoad?()
    }
    func save() {
        guard let storageURL, let data = try? JSONEncoder().encode(bytes) else { return }
        let file = storageURL
        writer.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
    func flush() { writer.sync {} }
    /// The strongest non-neutral pixels supply a learned site's brand colour.
    static func color(in image: UIImage?) -> UIColor? {
        guard let image = image?.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: 16*16*4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16)); return true
        }
        guard drew else { return nil }
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i+3] > 200 {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            guard max(r,g,b)-min(r,g,b) > 40 else { continue }
            let key = (r/32)*64+(g/32)*8+b/32, previous = buckets[key] ?? (0,0,0,0)
            buckets[key] = (previous.count+1, previous.red+r, previous.green+g, previous.blue+b)
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        let divisor = CGFloat(best.count)*255
        return UIColor(red: CGFloat(best.red)/divisor, green: CGFloat(best.green)/divisor, blue: CGFloat(best.blue)/divisor, alpha: 1)
    }
}
