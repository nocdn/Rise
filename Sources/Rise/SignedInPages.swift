import AppKit

/// Pages kept offscreen on a private server's own address, with the person's session and any
/// sign-in in front of it (such as Cloudflare Access), so its API can be asked as its own pages
/// ask it while no tab of it is open. One per server, gone a while after it was last used.
@MainActor final class SignedInPages {
    /// Where the pages live: a window keeps them running.
    weak var host: NSView?
    static let idle: TimeInterval = 120
    private var pages: [String: (page: WebPage, container: NSView)] = [:]
    private var loading: [String: Task<WebPage?, Never>] = [:]
    private var teardowns: [String: Task<Void, Never>] = [:]

    /// A page on `server`'s own address, once it has loaded there; nil if it was sent elsewhere,
    /// as to a sign-in page.
    func page(for server: String) async -> WebPage? {
        let server = server.lowercased()
        keep(server)
        if let page = pages[server]?.page, !page.isLoading, page.url?.host?.lowercased() == server { return page }
        if let task = loading[server] { return await task.value }
        let task = Task { await self.load(server) }
        loading[server] = task
        let page = await task.value
        loading[server] = nil
        return page
    }

    private func load(_ server: String) async -> WebPage? {
        guard let host, let url = URL(string: "https://\(server)/robots.txt") else { return nil }
        let page = pages[server]?.page ?? {
            let web = BrowserTab.makePage()
            let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 800, height: 600))
            web.view.frame = container.bounds; container.addSubview(web.view)
            host.addSubview(container, positioned: .below, relativeTo: host.subviews.first)
            pages[server] = (web, container)
            return web
        }()
        guard page is ChromiumPage else { close(server); return nil }
        page.load(url)
        var started = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if page.isLoading { started = true }
            if !page.isLoading, started || page.url?.host?.lowercased() == server { break }
        }
        guard !page.isLoading, page.url?.host?.lowercased() == server else { close(server); return nil }
        return page
    }

    private func keep(_ server: String) {
        teardowns[server]?.cancel()
        teardowns[server] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idle))
            guard !Task.isCancelled else { return }
            self?.close(server)
        }
    }
    private func close(_ server: String) {
        guard let entry = pages.removeValue(forKey: server) else { return }
        entry.page.stopLoading(); entry.container.removeFromSuperview()
    }
    func tearDown() { for server in Array(pages.keys) { close(server) } }
}
