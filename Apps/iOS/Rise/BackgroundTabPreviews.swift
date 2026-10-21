import UIKit
import WebKit

/// A bounded pool paints disposable pages behind the browser. Real tabs stay lazy,
/// and icon requests never have to wait for a slow page's screenshot.
@MainActor final class BackgroundTabPreviews {
    let host = UIView()
    let cache: TabPreviewCache
    var canRender: () -> Bool = { false }
    private let adBlocker: MobileAdBlocker
    private let retryDelay: TimeInterval
    private var tabs: [BrowserTab] = []
    private var queue: [BrowserTab] = []
    private var priorityIDs: [UUID] = []
    private weak var selected: BrowserTab?
    private var viewport = CGSize.zero
    private var stripHeight: CGFloat = 0
    private var active = true
    private var revision = 0
    private var work: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var renderers: [Key: TabPreviewRenderer] = [:]
    private var rendering = Set<Key>()
    private var fetchingIcons = Set<Key>()
    private var cached = Set<Key>()
    private var failures: [Key: Retry] = [:]
    private var iconFailures: [Key: Retry] = [:]
    private var declaredIcons: [Key: [URL]] = [:]
    private var openIDs = Set<UUID>()
    private struct Key: Hashable { let id: UUID; let url: URL }
    private struct Retry {
        let attempts: Int
        let date: Date
        init(after previous: Retry?, delay: TimeInterval) {
            attempts = min(6, (previous?.attempts ?? 0)+1)
            date = Date().addingTimeInterval(min(300, delay*pow(2, Double(attempts-1))))
        }
    }

    init(cacheURL: URL, adBlocker: MobileAdBlocker, retryDelay: TimeInterval = 30) {
        cache = TabPreviewCache(folder: cacheURL)
        self.adBlocker = adBlocker; self.retryDelay = retryDelay
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
    }

    func update(tabs: [BrowserTab], selected: BrowserTab, viewport: CGSize, stripHeight: CGFloat) {
        let tabs = tabs.filter { !$0.isPrivateBrowsing }
        self.tabs = tabs; self.selected = selected; self.viewport = viewport; self.stripHeight = stripHeight
        reorderQueue()
        revision += 1
        let ids = Set(tabs.map(\.id)), keys = Set(tabs.compactMap { key(for: $0) })
        if ids != openIDs { openIDs = ids; cache.prune(keeping: ids) }
        cached.formIntersection(keys)
        failures = failures.filter { keys.contains($0.key) }
        iconFailures = iconFailures.filter { keys.contains($0.key) }
        declaredIcons = declaredIcons.filter { keys.contains($0.key) }
        for (key, renderer) in renderers where !keys.contains(key) { renderer.cancel() }
        start()
    }

    func prioritize(_ ids: [UUID]) {
        guard priorityIDs != ids else { return }
        priorityIDs = ids; reorderQueue(); revision += 1; start()
    }
    private func reorderQueue() {
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let preferred = Set(priorityIDs)
        queue = priorityIDs.compactMap { byID[$0] } + tabs.reversed().filter { !preferred.contains($0.id) }
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active { start() }
        else {
            retry?.cancel(); retry = nil
            work?.cancel()
            renderers.values.forEach { $0.cancel() }
        }
    }

    func save(_ tab: BrowserTab) {
        guard !tab.isPrivateBrowsing else { return }
        guard let url = tab.sessionTab.url, tab.snapshot != nil || tab.favicon != nil else { return }
        cache.save(id: tab.id, url: url, picture: tab.snapshot, favicon: tab.favicon)
    }

    private func key(for tab: BrowserTab) -> Key? {
        guard !tab.isPrivateBrowsing else { return nil }
        return tab.sessionTab.url.map { Key(id: tab.id, url: $0) }
    }
    private func isCurrent(_ tab: BrowserTab, key: Key) -> Bool {
        tabs.contains { $0 === tab } && tab.sessionTab.url == key.url
    }
    private func canRetry(_ retry: Retry?) -> Bool { retry.map { Date() >= $0.date } ?? true }

    private func start() {
        guard active, work == nil, host.window != nil, viewport.width > 0 else { return }
        retry?.cancel(); retry = nil
        let started = revision
        work = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<2 { group.addTask { await self.renderPreviews() } }
                for _ in 0..<3 { group.addTask { await self.fetchFavicons() } }
            }
            work = nil
            // Foregrounding or a new sync batch can arrive as the old pool is unwinding.
            guard active else { return }
            if Task.isCancelled || revision != started { start() }
            else { scheduleRetry() }
        }
    }

    private func scheduleRetry() {
        let pending = tabs.compactMap { tab -> Date? in
            guard let key = key(for: tab) else { return nil }
            let picture = tab !== selected && tab.snapshot == nil ? failures[key] : nil
            let icon = tab.favicon == nil ? iconFailures[key] : nil
            return [picture, icon].compactMap { $0?.date }.min()
        }.min()
        guard let pending else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.1, pending.timeIntervalSinceNow))) }
            catch { return }
            guard let self else { return }
            retry = nil; start()
        }
    }

    private func waitUntilIdle() async throws {
        while !canRender() {
            guard active, host.window != nil else { throw CancellationError() }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
    }

    private func restoreCachedPreviews() async {
        while !Task.isCancelled, let tab = tabs.first(where: {
            ($0.snapshot == nil || $0.favicon == nil) && key(for: $0).map { !cached.contains($0) } == true
        }), let key = key(for: tab) {
            cached.insert(key)
            guard let entry = await cache.load(id: key.id, url: key.url), isCurrent(tab, key: key) else { continue }
            if tab.snapshot == nil, let bytes = entry.picture, let picture = UIImage(data: bytes),
               !TabPreviewRenderer.isBlank(picture, topInset: stripHeight) {
                tab.snapshot = picture
            }
            tab.restoreFavicon(entry.favicon.flatMap(UIImage.init(data:)))
        }
    }

    private func fetchFavicons() async {
        while active, !Task.isCancelled {
            await restoreCachedPreviews()
            guard let tab = queue.first(where: {
                guard $0.favicon == nil, let key = key(for: $0) else { return false }
                return !fetchingIcons.contains(key) && canRetry(iconFailures[key])
            }), let key = key(for: tab) else {
                // Renderers can discover declared icons after the initial root-icon pass.
                guard !rendering.isEmpty else { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                continue
            }
            fetchingIcons.insert(key)
            defer { fetchingIcons.remove(key) }
            let candidates = declaredIcons[key]
            let icon: UIImage?
            if let candidates { icon = await BrowserTab.favicon(at: candidates) }
            else { icon = await BrowserTab.favicon(for: key.url) }
            guard !Task.isCancelled else { return }
            guard isCurrent(tab, key: key) else { continue }
            if let icon {
                tab.restoreFavicon(icon); iconFailures[key] = nil; save(tab)
            } else if candidates == declaredIcons[key] {
                iconFailures[key] = Retry(after: iconFailures[key], delay: retryDelay)
            }
        }
    }

    private func renderPreviews() async {
        while active, !Task.isCancelled {
            await restoreCachedPreviews()
            guard let tab = queue.first(where: {
                guard $0 !== selected, $0.snapshot == nil, let key = key(for: $0) else { return false }
                return !rendering.contains(key) && canRetry(failures[key])
            }), let key = key(for: tab) else { return }
            rendering.insert(key)
            defer { rendering.remove(key) }
            do {
                // Stagger creation so a large sync batch cannot create WebKit pages in one frame.
                try await Task.sleep(for: .milliseconds(rendering.count == 1 ? 300 : 600))
                try await waitUntilIdle()
                guard isCurrent(tab, key: key), tab !== selected, tab.snapshot == nil else { continue }
                let size = viewport, top = stripHeight
                let page = TabPreviewRenderer(host: host, size: CGSize(width: size.width, height: size.height-top),
                                              top: top, adBlocker: adBlocker)
                renderers[key] = page
                defer { page.cancel(); renderers[key] = nil }
                let picture = try await page.picture(for: key.url, beforeCapture: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.waitUntilIdle()
                })
                try await waitUntilIdle()
                guard isCurrent(tab, key: key), tab !== selected, tab.snapshot == nil else { continue }
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(1.5, 600/size.width); format.opaque = true
                let strip = picture.cgImage.flatMap(PageEdgeColor.dominantColor) ?? .systemBackground
                tab.snapshot = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    strip.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    picture.draw(in: CGRect(x: 0, y: top, width: size.width, height: size.height-top))
                }
                failures[key] = nil; save(tab)
                // Prefer the declared icon when the fast first-party favicon lookup found none.
                if tab.favicon == nil {
                    let candidates = await BrowserTab.faviconCandidates(for: page.webView)
                    guard !Task.isCancelled, isCurrent(tab, key: key) else { continue }
                    declaredIcons[key] = candidates; iconFailures[key] = nil; revision += 1
                }
            } catch is CancellationError {
                if Task.isCancelled || !active { return }
            } catch { failures[key] = Retry(after: failures[key], delay: retryDelay) }
        }
    }
}
