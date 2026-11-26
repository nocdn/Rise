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
    private var retryAfter: [String: Date] = [:]
    private var preview: Task<Void, Never>?
    private let writer = DispatchQueue(label: "Rise.SuggestionIcons", qos: .utility)
    var onLoad: (() -> Void)?
    private var dirty = false
    private var savePending = false
    static let recheckInterval: TimeInterval = 7*24*60*60
    static let capacity = 128

    init(storageURL: URL?, session: URLSession? = nil, allowsNetwork: Bool = true) {
        self.allowsNetwork = allowsNetwork
        self.storageURL = storageURL
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        self.session = session ?? URLSession(configuration: config)
        if let storageURL, let data = try? Data(contentsOf: storageURL), data.count <= 16_000_000 {
            if let saved = try? JSONDecoder().decode([String: MobileFavicon.Saved].self, from: data) {
                // Decoded when first shown (`cached`): decoding all of them held up launch.
                for (key, value) in saved.sorted(by: { $0.value.recency > $1.value.recency }).prefix(Self.capacity) {
                    bytes[key] = value
                    if value.dark != nil || value.checked.map({ -$0.timeIntervalSinceNow < Self.recheckInterval }) == true {
                        attempted.insert(key)
                    }
                }
            } else if let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
                // Old single-image caches remain usable while their appearance variants load.
                for (key, value) in saved.sorted(by: { $0.key < $1.key }).prefix(Self.capacity) {
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
        guard let image, let origin = Self.origin(url), cached(origin) !== image else { return }
        // A late /favicon.ico or a restored tab must not replace sharper artwork.
        if let known = cached(origin), Self.pixels(known) > Self.pixels(image) { return }
        guard var saved = MobileFavicon.Saved(image) else { return }
        let checked = bytes[origin]?.checked
        // A restored tab may still have a single icon; keep any dark artwork already learned.
        if saved.dark == nil, let dark = bytes[origin]?.dark.flatMap(MobileFavicon.decode) {
            let combined = MobileFavicon.adaptive(light: image, dark: dark)
            guard let merged = MobileFavicon.Saved(combined) else { return }
            images[origin] = combined; saved = merged
        } else {
            images[origin] = image
        }
        // Same artwork again, as from a restored tab: nothing to write.
        if let known = bytes[origin], known.light == saved.light, known.dark == saved.dark { return }
        saved.checked = checked; saved.used = Date(); bytes[origin] = saved; dirty = true
        // The least recently used sites make room, never the one just saved.
        while bytes.count > Self.capacity,
              let oldest = bytes.filter({ $0.key != origin }).min(by: { $0.value.recency < $1.value.recency })?.key {
            images[oldest] = nil; bytes[oldest] = nil
        }
    }
    private static func pixels(_ image: UIImage) -> Int {
        let image = MobileFavicon.variant(image, style: .light)
        return min(image.cgImage?.width ?? 0, image.cgImage?.height ?? 0)
    }
    /// Typing a literal address waits for a quiet moment before fetching its public site's icon.
    func previewCandidate(_ url: URL?) {
        preview?.cancel(); preview = nil
        guard allowsNetwork, let url, let origin = Self.origin(url), bytes[origin] == nil,
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
              tasks[origin] == nil, !((retryAfter[origin] ?? .distantPast) > Date()),
              attempted.insert(origin).inserted else { return known(origin) }
        tasks[origin] = Task { [weak self] in
            guard let self else { return }
            defer {
                tasks[origin] = nil
                if bytes[origin] != nil, !Task.isCancelled { bytes[origin]?.checked = Date(); scheduleSave() }
                if bytes[origin] == nil {
                    attempted.remove(origin)
                    retryAfter[origin] = Date().addingTimeInterval(60)
                }
            }
            let root = URL(string: origin)!
            if let lightURL = FaviconDiscovery.lightIcon(for: root), let darkURL = FaviconDiscovery.darkIcon(for: root) {
                async let light = load(lightURL)
                async let dark = load(darkURL)
                let pair = await (light, dark)
                if let light = pair.0 ?? pair.1 {
                    store(MobileFavicon.adaptive(light: light, dark: pair.1), origin: origin); return
                }
            }
            var light = cached(origin)
            if light == nil, let fallback = URL(string: "/favicon.ico", relativeTo: root)?.absoluteURL {
                light = await load(fallback)
                if let light { remember(light, for: root); dirty = true; onLoad?() }
            }
            // Even when favicon.ico loads, metadata can declare a separate dark icon.
            var dark: UIImage?
            if let html = await resource(from: root) {
                let lightURLs = Array(FaviconDiscovery.icons(in: html.data, baseURL: html.url).prefix(4))
                let darkURLs = Array(FaviconDiscovery.icons(in: html.data, baseURL: html.url, dark: true).prefix(4))
                if let declared = await firstIcon(lightURLs) { light = declared }
                if darkURLs != lightURLs { dark = await firstIcon(darkURLs) }
            }
            if let light = light ?? dark { store(MobileFavicon.adaptive(light: light, dark: dark), origin: origin) }
        }
        return known(origin)
    }
    /// The site's icon, or until it has one of its own, its www. twin's: speedrun.com's pages
    /// are at www.speedrun.com, where its icon is learned.
    private func known(_ origin: String) -> UIImage? {
        if let image = cached(origin) { return image }
        guard var parts = URLComponents(string: origin), let host = parts.host else { return nil }
        parts.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : "www." + host
        return parts.string.flatMap(cached)
    }
    private func cached(_ origin: String) -> UIImage? {
        // Shown again: keep it ahead of the sites that make room for new ones.
        if bytes[origin] != nil, (bytes[origin]?.used).map({ -$0.timeIntervalSinceNow >= 60*60 }) ?? true {
            bytes[origin]?.used = Date(); dirty = true
        }
        if let image = images[origin] { return image }
        guard let saved = bytes[origin] else { return nil }
        guard let image = saved.image else { bytes[origin] = nil; dirty = true; return nil }
        images[origin] = image
        return image
    }
    private func firstIcon(_ urls: [URL]) async -> UIImage? {
        for url in urls {
            if Task.isCancelled { return nil }
            if let image = await load(url) { return image }
        }
        return nil
    }
    private func load(_ url: URL) async -> UIImage? {
        guard let resource = await resource(from: url) else { return nil }
        return await MobileFavicon.artwork(resource.data)
    }
    private func resource(from url: URL) async -> (data: Data, url: URL)? {
        guard ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request), !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { return nil }
        return (data, response.url ?? url)
    }
    private func store(_ image: UIImage, origin: String) {
        remember(image, for: URL(string: origin))
        scheduleSave(); onLoad?()
    }
    /// Icons arrive in bursts after launch; one write covers the burst.
    private func scheduleSave() {
        dirty = true
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.savePending = false; self?.save() }
        }
    }
    /// Writes changed icons. Encoding happens on the writer queue, off the main thread.
    func save() {
        guard dirty, let storageURL else { return }
        dirty = false
        let snapshot = bytes, file = storageURL
        writer.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
    func flush() { save(); writer.sync {} }
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
