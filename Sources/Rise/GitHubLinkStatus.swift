import AppKit
import RiseCore

/// One hovered repository, with short-lived session-local results. Leaving a link
/// cancels its waiter; a late result can never overwrite the next link's indicator.
@MainActor final class GitHubLinkStatus {
    enum State: Equatable { case checking, starred, unstarred }
    typealias Lookup = @MainActor (GitHubRepository) async -> Bool?
    var onChange: ((State?) -> Void)?
    private(set) var state: State?
    private let lookup: Lookup
    private let now: () -> Date
    private let delay: Duration
    private var repository: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var cache: [String: (value: Bool, until: Date)] = [:]

    init(delay: Duration = .milliseconds(150), now: @escaping () -> Date = Date.init, lookup: @escaping Lookup) {
        self.delay = delay; self.now = now; self.lookup = lookup
    }
    func hover(_ url: URL?) {
        let target = GitHubRepository(url: url), key = target?.path.lowercased()
        guard key != repository else { return }
        task?.cancel(); task = nil; generation = UUID(); repository = key
        guard let target, let key else { set(nil); return }
        cache = cache.filter { $0.value.until > now() }
        if let cached = cache[key] { set(cached.value ? .starred : .unstarred); return }
        set(.checking)
        let token = generation, lookup = lookup, delay = delay
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            let value = await lookup(target)
            guard !Task.isCancelled, let self, generation == token else { return }
            if let value { remember(value, for: key) }
            set(value.map { $0 ? .starred : .unstarred }); task = nil
        }
    }
    func record(_ starred: Bool, for target: GitHubRepository) {
        let key = target.path.lowercased()
        remember(starred, for: key)
        if repository == key {
            task?.cancel(); task = nil; generation = UUID()
            set(starred ? .starred : .unstarred)
        }
    }
    private func remember(_ value: Bool, for key: String) {
        if cache.count >= 64 { cache.removeAll() }
        cache[key] = (value, now().addingTimeInterval(15))
    }
    private func set(_ value: State?) { state = value; onChange?(value) }
    isolated deinit { task?.cancel() }
}

@MainActor extension BrowserController {
    func makeGitHubLinkStatus() -> GitHubLinkStatus {
        let status = GitHubLinkStatus { [weak self] repository in
            guard let self else { return nil }
            let existing = tabs.map(\.page).first {
                $0.url?.host?.lowercased() == "github.com" && !$0.isLoading && $0.view.window != nil && !$0.isCovered
            }
            guard !Task.isCancelled else { return nil }
            if let page = existing, let state = (try? await page.evaluate(GitHubStarScripts.readStatus, arguments: ["repositoryPath": repository.path],
                                                    in: nil, world: .named("Rise.GitHubStatus"))) as? Bool { return state }
            guard !Task.isCancelled else { return nil }
            GitHubStarrer.log("hover \(repository.path): checking live page")
            return await githubStarrer.status(repository)
        }
        status.onChange = { [weak self] state in
            guard let self else { return }
            linkStatus.setRepositoryState(state)
            if hoveredWebView != nil { layoutLinkStatus() }
        }
        return status
    }
}
