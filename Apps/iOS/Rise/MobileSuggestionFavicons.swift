import UIKit
import ImageIO

/// Bounded, persistent first-party icons. No third-party favicon service receives typed URLs.
@MainActor final class MobileSuggestionFavicons {
    private let storageURL: URL?
    private let allowsNetwork: Bool
    private let session: URLSession
    private var images: [String: UIImage] = [:]
    private var bytes: [String: Data] = [:]
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
        if let storageURL, let data = try? Data(contentsOf: storageURL), data.count <= 8_000_000,
           let saved = try? JSONDecoder().decode([String: Data].self, from: data) {
            for (key, value) in saved.sorted(by: { $0.key < $1.key }).prefix(128) {
                if let image = Self.decode(value) { bytes[key] = value; images[key] = image }
            }
        }
    }
    static func origin(_ url: URL?) -> String? {
        guard let url, url.user == nil, url.password == nil, let site = BrowsingHistory.site(of: url) else { return nil }
        return site.absoluteString
    }
    func remember(_ image: UIImage?, for url: URL?) {
        guard let image, let origin = Self.origin(url), let data = image.pngData(), data.count <= 100_000 else { return }
        images[origin] = image; bytes[origin] = data
        while images.count > 128, let oldest = images.keys.sorted().first { images[oldest] = nil; bytes[oldest] = nil }
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
        if let image = images[origin] { return image }
        // Only complete public domains are fetched. In-progress/local addresses keep the placeholder.
        guard fetch, allowsNetwork, !AddressResolver.isLocal(url), let host = url.host, host.contains("."),
              !host.hasSuffix(".test"), !host.hasSuffix(".example"), !host.hasSuffix(".invalid"),
              attempted.insert(origin).inserted else { return nil }
        tasks[origin] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[origin] = nil }
            let root = URL(string: origin)!
            let candidates = [FaviconDiscovery.lightIcon(for: root), URL(string: "/favicon.ico", relativeTo: root)?.absoluteURL].compactMap { $0 }
            for icon in candidates {
                if let data = await data(from: icon), let image = Self.decode(data) { store(image, origin: origin); return }
            }
            if let html = await data(from: root), let declared = FaviconDiscovery.icon(in: html, baseURL: root),
               let data = await data(from: declared), let image = Self.decode(data) { store(image, origin: origin) }
        }
        return nil
    }
    private func data(from url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request), !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000 else { return nil }
        return data
    }
    private static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 1_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
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
