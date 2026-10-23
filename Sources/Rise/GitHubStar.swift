import AppKit
import RiseCore

@MainActor extension BrowserController {
    /// Stars `repository` as the person signed in to GitHub in Rise, saying so in the blue notice:
    /// a spinner while it's under way, then a star.
    func starGitHubRepository(_ repository: GitHubRepository) {
        let kind = "github-star"
        // It stays while it's under way; what came of it holds as long as other notices do.
        showInfo("Starring repository", image: InfoPlaque.spinnerIcon, hold: .seconds(90), kind: kind)
        Task { [weak self] in
            guard let self else { return }
            switch await self.githubStarrer.star(repository) {
            case .starred: self.showInfo("Starred repository", image: InfoPlaque.starIcon, hold: .seconds(2), kind: kind)
            case .alreadyStarred: self.showInfo("Already starred", image: InfoPlaque.starIcon, hold: .seconds(2), kind: kind)
            case .signedOut:
                self.showInfo("Sign in to GitHub to star repositories", image: InfoPlaque.warningIcon,
                              link: .init(text: "Sign In") { [weak self] in self?.addTab(url: URL(string: "https://github.com/login")!) },
                              hold: .seconds(4), kind: kind)
            case .notFound: self.showInfo("Couldn’t find that repository", image: InfoPlaque.warningIcon, hold: .seconds(3), kind: kind)
            case .failed: self.showInfo("Couldn’t star repository", image: InfoPlaque.warningIcon, hold: .seconds(3), kind: kind)
            }
        }
    }
}

/// Stars repositories as the person signed in to GitHub in Rise, with github.com's own Star button:
/// the repository's page, kept offscreen with their session, says whether they're signed in and
/// whether it's starred, and its button is pressed once GitHub's code has taken it over. One at a
/// time, in order.
@MainActor final class GitHubStarrer {
    enum Outcome: Equatable { case starred, alreadyStarred, signedOut, notFound, failed }
    private var page: WebPage?
    private var queue: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    /// Where the offscreen page lives: a window keeps it running.
    weak var host: NSView?
    static let world = "Rise.GitHub"
    /// Each attempt and what came of it, for finding out why one didn't work.
    static let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rise/github-star.log")
    static func log(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kept short: the last few hundred lines.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 200_000 { try? FileManager.default.removeItem(at: logURL) }
        if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close() }
        else { try? Data(text.utf8).write(to: logURL) }
    }

    func star(_ repository: GitHubRepository) async -> Outcome {
        let previous = queue
        let work = Task { @MainActor [weak self] () -> Outcome in
            await previous?.value
            guard let self else { return .failed }
            return await self.run(repository)
        }
        queue = Task { _ = await work.value }
        return await work.value
    }

    private func run(_ repository: GitHubRepository) async -> Outcome {
        idle?.cancel()
        defer { scheduleTearDown() }
        Self.log("start \(repository.path)")
        let path = "/\(repository.owner)/\(repository.name)"
        guard let page = hiddenPage(), let url = URL(string: "https://github.com" + path) else { return .failed }
        // The repository's own page, with GitHub's Star button. A page left from an earlier star
        // mustn't pass for it: done once this load has been seen to start, or it shows this one.
        let before = page.url
        page.load(url)
        var started = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if page.isLoading || page.url != before { started = true }
            if !page.isLoading, page.url?.host == "github.com", started || page.url?.path.lowercased() == path.lowercased() { break }
        }
        guard !page.isLoading, page.url?.host == "github.com", started || page.url?.path.lowercased() == path.lowercased() else {
            Self.log("\(repository.path): the page didn't load (\(page.url?.absoluteString ?? "nothing"))"); tearDown(); return .failed
        }
        let found = await withTimeout(seconds: 15) { await page.evaluate(Self.findScript, arguments: [:], world: Self.world) }
        guard let ready = found as? [String: Any], ready["status"] as? String == "ready" else {
            let found = Self.outcome(found)
            Self.log("\(repository.path): \(found.status)\(found.detail.map { " (\($0))" } ?? "")")
            return found.outcome
        }
        // GitHub draws the button before its code takes it over: wait for that, or a press is lost.
        // A plain form's button works at once.
        if ready["form"] as? Bool != true {
            let start = Date()
            var wired = false
            while !wired, Date().timeIntervalSince(start) < 12 {
                wired = (try? await page.evaluate(Self.wiredScript, arguments: [:], in: nil, world: .page)) as? Bool == true
                if !wired { try? await Task.sleep(for: .milliseconds(200)) }
            }
            Self.log("\(repository.path): \(wired ? "wired" : "never seen wired") after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
        let pressed = Self.outcome(await withTimeout(seconds: 15) { await page.evaluate(Self.pressScript, arguments: [:], world: Self.world) })
        Self.log("\(repository.path): \(pressed.status)\(pressed.detail.map { " (\($0))" } ?? "")")
        return pressed.outcome
    }
    private static func outcome(_ value: Any?) -> (outcome: Outcome, status: String, detail: String?) {
        guard let result = value as? [String: Any], let status = result["status"] as? String else {
            return (.failed, value == nil ? "no answer (timed out or the script failed)" : "unexpected answer", value.map { String(describing: $0) })
        }
        let detail = result["detail"].map { String(describing: $0) }
        switch status {
        case "starred": return (.starred, status, detail)
        case "already": return (.alreadyStarred, status, detail)
        case "signedOut": return (.signedOut, status, detail)
        case "notFound": return (.notFound, status, detail)
        default: return (.failed, status, detail)
        }
    }

    /// A page kept offscreen, its requests carrying the person's session; a window keeps it running.
    private func hiddenPage() -> WebPage? {
        let page = self.page ?? {
            let web = BrowserTab.makePage()
            // Desktop-sized, so GitHub doesn't move the Star button into its narrow layout's menu.
            let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 1280, height: 900))
            web.view.frame = container.bounds; container.addSubview(web.view)
            host?.addSubview(container, positioned: .below, relativeTo: host?.subviews.first)
            self.page = web
            return web
        }()
        return page is ChromiumPage ? page : nil
    }

    private func withTimeout(seconds: Double, _ work: @escaping @MainActor () async -> Any?) async -> Any? {
        await withTaskGroup(of: Any?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    private func scheduleTearDown() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.tearDown()
        }
    }
    func tearDown() {
        idle?.cancel(); idle = nil
        page?.view.superview?.removeFromSuperview()
        (page as? ChromiumPage)?.browserView.close()
        page = nil
    }

    static let findScript = GitHubStarScripts.find
    static let wiredScript = GitHubStarScripts.wired
    static let pressScript = GitHubStarScripts.press
}
