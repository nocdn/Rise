import AppKit
import RiseCore

/// Share icons by security origin, keeping bounded 32px PNGs across relaunches.
@MainActor final class SuggestionFavicons {
    static let limit = 128
    private let storageURL: URL
    private let session: URLSession
    private var images: [String: NSImage] = [:]
    private var data: [String: Data] = [:]
    private var tasks: [String: URLSessionDataTask] = [:]
    private var requested: [String: URL] = [:]
    private var attempted = Set<String>()
    private var order: [String] = []
    private var saveWork: DispatchWorkItem?
    private var dirty = false
    private var previewTimer: Timer?
    private var previewOrigin: String?
    var onLoad: ((String, NSImage) -> Void)?
    var onVariantLoad: ((String, NSImage, Bool) -> Void)?
    private static func key(_ origin: String, dark: Bool) -> String { dark ? origin+"|dark" : origin }

    init(storageURL: URL, session: URLSession = .shared) {
        self.storageURL = storageURL; self.session = session
        if let bytes = try? Data(contentsOf: storageURL), bytes.count <= 24_000_000,
           let saved = try? JSONDecoder().decode([String: Data].self, from: bytes) {
            for (key, png) in saved.sorted(by: { $0.key < $1.key }).prefix(Self.limit*2) {
                let origin = key.hasSuffix("|dark") ? String(key.dropLast(5)) : key
                guard SitePermissions.origin(URL(string: origin)) == origin,
                      order.contains(origin) || order.count < Self.limit,
                      let image = FaviconSnapshot.decode(png) else { continue }
                images[key] = image; data[key] = png
                if !order.contains(origin) { order.append(origin) }
            }
        }
    }
    func remember(_ tab: BrowserTab) {
        guard let origin = tab.iconOrigin, origin == SitePermissions.origin(tab.url) else { return }
        if let image = tab.favicon, let png = tab.faviconData, data[origin] != png { store(image, png: png, origin: origin) }
        let key = Self.key(origin, dark: true)
        if let image = tab.darkFavicon, let png = tab.darkFaviconData, data[key] != png { store(image, png: png, origin: origin, dark: true) }
    }
    func darkImage(for url: URL?) -> NSImage? {
        guard let origin = SitePermissions.origin(url) else { return nil }
        let key = Self.key(origin, dark: true)
        if let image = images[key] { return image }
        // GitHub changes its link in JavaScript, rather than declaring a media link.
        // Use its published white PNG even for restored tabs that haven't loaded yet.
        if let icon = FaviconDiscovery.darkIcon(for: url), attempted.insert(key).inserted {
            fetch(icon, origin: origin, dark: true)
        }
        return nil
    }
    func cachedDarkImage(for url: URL) -> NSImage? {
        SitePermissions.origin(url).flatMap { images[Self.key($0, dark: true)] }
    }
    func image(for url: URL?, fetch allowFetch: Bool = true, dark: Bool = false) -> NSImage? {
        guard let origin = SitePermissions.origin(url), let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if dark {
            if allowFetch, let image = darkImage(for: url) { return image }
            if let image = images[Self.key(origin, dark: true)] { return image }
        }
        if let image = images[origin] { return image }
        guard allowFetch, !AddressResolver.isLocal(url), attempted.insert(origin).inserted,
              let iconURL = Self.defaultIcon(for: url) else { return nil }
        fetch(iconURL, origin: origin, discoverIfNeeded: true)
        return nil
    }
    /// Fetch only the origin's icon once a plausible typed address settles.
    /// Paths/query strings never leave the address field in these requests.
    func preview(_ url: URL?) {
        guard let url, Self.isPreviewAddress(url), let origin = SitePermissions.origin(url) else {
            cancelPreview(); return
        }
        guard images[origin] == nil, !attempted.contains(origin) else { cancelPreview(); return }
        guard previewOrigin != origin else { return }
        cancelPreview(); previewOrigin = origin
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.previewOrigin == origin else { return }
                self.cancelPreview()
                _ = self.image(for: url)
            }
        }
        previewTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func cancelPreview() {
        previewTimer?.invalidate(); previewTimer = nil; previewOrigin = nil
    }
    private static func isPreviewAddress(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !AddressResolver.isLocal(url), let host = url.host?.lowercased() else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }
        guard labels.count >= 2, let suffix = labels.last, suffix.count >= 2,
              suffix.range(of: "^(?:[a-z]{2,63}|xn--[a-z0-9-]+)$", options: .regularExpression) != nil else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
        }
    }
    /// The icon a page declared. `throughPage` asks for it again with the page's own sign-in, for
    /// a site that keeps even its icon behind one (Jira, anything behind Cloudflare Access).
    func loadPageIcon(_ iconURL: URL, for pageURL: URL, dark: Bool = false, throughPage: ((URL) async -> Data?)? = nil) {
        guard ["http", "https"].contains(iconURL.scheme?.lowercased() ?? ""),
              iconURL.user == nil, iconURL.password == nil, let origin = SitePermissions.origin(pageURL),
              requested[Self.key(origin, dark: dark)] != iconURL else { return }
        fetch(iconURL, origin: origin, dark: dark, throughPage: throughPage)
    }
    /// Background tab metadata uses the same decoding, appearance variants and persistent cache.
    @discardableResult func storePageIcon(_ bytes: Data, for pageURL: URL, dark: Bool = false) -> Bool {
        guard bytes.count <= 1_000_000, let origin = SitePermissions.origin(pageURL),
              let image = FaviconImage.decode(bytes, dark: dark), image.isValid, let png = FaviconSnapshot.encode(image) else { return false }
        store(image, png: png, origin: origin, dark: dark)
        if !dark, FaviconImage.hasAppearanceStyles(bytes), let variant = FaviconImage.decode(bytes, dark: true), let png = FaviconSnapshot.encode(variant) {
            store(variant, png: png, origin: origin, dark: true)
        }
        return true
    }
    private func fetch(_ iconURL: URL, origin: String, discoverIfNeeded: Bool = false, dark: Bool = false, throughPage: ((URL) async -> Data?)? = nil) {
        let key = Self.key(origin, dark: dark)
        tasks[key]?.cancel(); requested[key] = iconURL
        var request = URLRequest(url: iconURL); request.timeoutInterval = 8
        let task = session.dataTask(with: request) { [weak self] bytes, response, _ in
            Task { @MainActor in
                guard let self, self.requested[key] == iconURL else { return }
                self.tasks[key] = nil
                if let bytes, (response as? HTTPURLResponse)?.statusCode == 200,
                   self.storePageIcon(bytes, for: URL(string: origin)!, dark: dark) {
                    return
                } else if let throughPage {
                    Task { @MainActor [weak self] in
                        guard let bytes = await throughPage(iconURL), let self, self.requested[key] == iconURL else { return }
                        self.storePageIcon(bytes, for: URL(string: origin)!, dark: dark)
                    }
                } else if discoverIfNeeded {
                    if let bytes, let declared = FaviconDiscovery.icon(in: bytes, baseURL: response?.url ?? iconURL), declared != iconURL {
                        self.fetch(declared, origin: origin)
                    } else { self.discoverRootIcon(origin: origin) }
                }
            }
        }
        tasks[key] = task; task.resume()
    }
    private func discoverRootIcon(origin: String) {
        guard let root = URL(string: origin + "/") else { return }
        requested[origin] = root
        var request = URLRequest(url: root); request.timeoutInterval = 8
        let task = session.dataTask(with: request) { [weak self] bytes, response, _ in
            Task { @MainActor in
                guard let self, self.requested[origin] == root else { return }
                self.tasks[origin] = nil
                guard let bytes, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let landed = response?.url ?? root
                let redirectedIcon = SitePermissions.origin(landed) != origin ? Self.defaultIcon(for: landed) : nil
                guard let icon = FaviconDiscovery.icon(in: bytes, baseURL: landed) ?? redirectedIcon else { return }
                self.fetch(icon, origin: origin)
                if let dark = FaviconDiscovery.icon(in: bytes, baseURL: landed, dark: true), dark != icon {
                    self.fetch(dark, origin: origin, dark: true)
                }
            }
        }
        tasks[origin] = task; task.resume()
    }
    private static func defaultIcon(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil; parts.password = nil; parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        return parts.url
    }
    private func store(_ image: NSImage, png: Data, origin: String, dark: Bool = false) {
        let key = Self.key(origin, dark: dark)
        images[key] = image; data[key] = png
        dirty = true
        order.removeAll { $0 == origin }; order.append(origin)
        while order.count > Self.limit {
            let old = order.removeFirst()
            for key in [old, Self.key(old, dark: true)] { images[key] = nil; data[key] = nil }
        }
        if !dark { onLoad?(origin, image) }
        onVariantLoad?(origin, image, dark)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: work)
    }
    func save() {
        saveWork?.cancel(); saveWork = nil
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: storageURL, options: .atomic)
            dirty = false
        } catch { NSLog("Rise suggestion icon save failed: %@", error.localizedDescription) }
    }
    func cancel() { cancelPreview(); tasks.values.forEach { $0.cancel() }; tasks = [:]; requested = [:]; saveWork?.cancel() }
    deinit { previewTimer?.invalidate(); tasks.values.forEach { $0.cancel() }; saveWork?.cancel() }
}
