import AppKit
import RiseCore

/// A small queue fills dormant tabs' metadata without starting their Chromium pages.
@MainActor final class SyncedTabMetadata {
    private struct Key: Hashable { let id: UUID; let url: URL }
    private final class Job {
        weak var tab: BrowserTab?
        var task: Task<Void, Never>?
        var complete = false
        var failures = 0
        var nextAttempt = Date.distantPast
        init(_ tab: BrowserTab) { self.tab = tab }
    }
    static let concurrency = 3
    private let icons: SuggestionFavicons
    private let session: URLSession
    private let ownsSession: Bool
    private let retryDelay: TimeInterval
    private var jobs: [Key: Job] = [:]
    private var order: [Key] = []
    private var retry: Task<Void, Never>?
    var onChange: (() -> Void)?
    var activeCount: Int { jobs.values.filter { $0.task != nil }.count }

    init(icons: SuggestionFavicons, session: URLSession? = nil, retryDelay: TimeInterval = 30) {
        self.icons = icons; self.retryDelay = retryDelay; ownsSession = session == nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
        self.session = session ?? URLSession(configuration: configuration)
    }

    func update(tabs: [BrowserTab]) {
        var next: [Key] = []
        for tab in tabs {
            guard !tab.hasAttemptedNavigation, let url = tab.url, Self.isWebURL(url), !AddressResolver.isLocal(url) else { continue }
            if tab.favicon == nil, let image = icons.image(for: url, fetch: false) {
                tab.iconOrigin = SitePermissions.origin(url); tab.favicon = image
                tab.darkFavicon = icons.cachedDarkImage(for: url)
            }
            let key = Key(id: tab.id, url: url)
            if let old = jobs[key], old.tab !== tab { old.task?.cancel(); jobs[key] = nil }
            guard jobs[key] != nil || tab.favicon == nil || Self.needsTitle(tab.title, url: url) else { continue }
            next.append(key)
            if jobs[key] == nil { jobs[key] = Job(tab) }
        }
        let valid = Set(next)
        for key in Array(jobs.keys) where !valid.contains(key) {
            jobs.removeValue(forKey: key)?.task?.cancel()
        }
        order = next; pump()
    }

    func cancel() {
        retry?.cancel(); retry = nil
        jobs.values.forEach { $0.task?.cancel() }; jobs.removeAll(); order.removeAll()
    }

    private func pump() {
        retry?.cancel(); retry = nil
        var running = activeCount
        for key in order {
            guard running < Self.concurrency else { break }
            guard let job = jobs[key], !job.complete, job.task == nil, job.nextAttempt <= Date() else { continue }
            job.task = Task { [weak self, weak job] in
                guard let self, let job else { return }
                do {
                    try await self.fetch(key, job: job)
                    guard !Task.isCancelled, self.jobs[key] === job else { return }
                    job.complete = true
                } catch {
                    guard !Task.isCancelled, self.jobs[key] === job else { return }
                    job.failures = min(6, job.failures+1)
                    job.nextAttempt = Date().addingTimeInterval(min(300, self.retryDelay*pow(2, Double(job.failures-1))))
                }
                job.task = nil; self.pump()
            }
            running += 1
        }
        if running < Self.concurrency,
           let date = jobs.values.filter({ !$0.complete && $0.task == nil }).map(\.nextAttempt).min() {
            let delay = max(0.01, date.timeIntervalSinceNow)
            retry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.pump()
            }
        }
    }

    private func fetch(_ key: Key, job: Job) async throws {
        let metadata = try? await Self.document(key.url, session: session)
        guard isCurrent(key, job: job) else { throw CancellationError() }
        if let tab = job.tab, tab.customTitle == nil, Self.needsTitle(tab.title, url: key.url), let title = metadata?.title {
            tab.title = tab.hidesNotificationCounts ? TitleNotificationCount.removing(from: title, url: key.url) : title
            onChange?()
        }
        guard isCurrent(key, job: job) else { throw CancellationError() }
        let fallback = URL(string: "/favicon.ico", relativeTo: key.url)?.absoluteURL
        let light = [FaviconDiscovery.lightIcon(for: key.url), metadata?.lightIcon, fallback].compactMap { $0 }
        if icons.image(for: key.url, fetch: false) == nil || metadata?.lightIcon != nil {
            var seen = Set<URL>()
            for url in light where seen.insert(url).inserted {
                guard isCurrent(key, job: job) else { throw CancellationError() }
                if let (bytes, _) = try? await Self.download(url, session: session), isCurrent(key, job: job),
                   icons.storePageIcon(bytes, for: key.url) { break }
            }
        }
        if let dark = FaviconDiscovery.darkIcon(for: key.url) ?? metadata?.darkIcon, !light.contains(dark),
           icons.cachedDarkImage(for: key.url) == nil, isCurrent(key, job: job),
           let (bytes, _) = try? await Self.download(dark, session: session), isCurrent(key, job: job) {
            _ = icons.storePageIcon(bytes, for: key.url, dark: true)
        }
        guard isCurrent(key, job: job), let tab = job.tab else { throw CancellationError() }
        if let image = icons.image(for: key.url, fetch: false) {
            tab.iconOrigin = SitePermissions.origin(key.url); tab.favicon = image
            tab.darkFavicon = icons.cachedDarkImage(for: key.url)
            onChange?()
        }
        if metadata == nil { throw URLError(.badServerResponse) }
    }

    private func isCurrent(_ key: Key, job: Job) -> Bool {
        !Task.isCancelled && jobs[key] === job && job.tab?.url == key.url && job.tab?.hasAttemptedNavigation == false
    }

    static func needsTitle(_ title: String, url: URL) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "new tab", url.absoluteString.lowercased(), url.host?.lowercased() ?? "", AddressResolver.displayHost(url).lowercased()].contains(text)
    }

    nonisolated private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    nonisolated private static func document(_ url: URL, session: URLSession) async throws -> TabPageMetadata {
        let (bytes, response) = try await download(url, session: session)
        let landed = response.url ?? url
        let sameOrigin = SitePermissions.origin(landed) == SitePermissions.origin(url)
        let isHTML = response.mimeType.map { ["text/html", "application/xhtml+xml"].contains($0.lowercased()) } ?? true
        return TabPageMetadata(html: sameOrigin && isHTML ? bytes : Data(), url: landed)
    }

    /// Stop after one megabyte, and cancel the stream. Images and arbitrary page bodies never
    /// turn a large import into unbounded downloads or main-thread HTML parsing.
    nonisolated private static func download(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        guard isWebURL(url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 8; request.httpShouldHandleCookies = false
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url.map(isWebURL) == true else { throw URLError(.badServerResponse) }
        var bytes = Data()
        for try await byte in stream {
            if bytes.count == 1_000_000 { break }
            bytes.append(byte)
        }
        try Task.checkCancellation()
        return (bytes, response)
    }

    deinit {
        retry?.cancel(); jobs.values.forEach { $0.task?.cancel() }
        if ownsSession { session.invalidateAndCancel() }
    }
}
