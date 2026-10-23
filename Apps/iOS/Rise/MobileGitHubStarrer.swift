import UIKit
import WebKit

/// Uses the held link's exact WebKit data store. Cookies and CSRF tokens never leave WebKit.
@MainActor final class MobileGitHubStarrer {
    enum Outcome: Equatable, Sendable { case starred, alreadyStarred, unstarred, alreadyUnstarred, signedOut, notFound, failed, cancelled }
    enum Status: Equatable, Sendable { case starred, unstarred, signedOut, notFound, failed, cancelled }
    enum Action: Equatable, Sendable {
        case star, unstar
        var starred: Bool { self == .star }
        var progress: String { self == .star ? "Starring repository..." : "Unstarring repository..." }
        var title: String { self == .star ? "Star repository" : "Unstar repository" }
    }
    struct Key: Hashable { let repository: String; let store: ObjectIdentifier }
    private struct Mutation { let id: UUID; let action: Action; let task: Task<Outcome,Never> }
    private var pending: [Key: Mutation] = [:]
    private var queue: Task<Void, Never>?
    private var active: [UUID: () -> Void] = [:]
    private var workers: [UUID: [GitHubStarPage]] = [:]
    var origin = URL(string: "https://github.com")!
    var loadTimeout: TimeInterval = 20
    var verificationTimeout: TimeInterval = 6
    var isIdle: Bool { active.isEmpty && workers.isEmpty }
    #if DEBUG
    private(set) var diagnostics: [String] = []
    #endif
    private func trace(_ text: String) {
        #if DEBUG
        diagnostics.append(text)
        #endif
    }
    static func signedIn(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        cookies.contains {
            let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "github.com" && $0.name == "logged_in" && $0.value == "yes"
                && ($0.expiresDate.map { $0 > now } ?? true)
        }
    }
    static func signedIn(store: WKWebsiteDataStore) async -> Bool {
        signedIn(cookies: await store.httpCookieStore.allCookies())
    }
    func isPending(_ repository: GitHubRepository, store: WKWebsiteDataStore) -> Bool {
        pending[Key(repository: repository.path.lowercased(), store: ObjectIdentifier(store))] != nil
    }
    private func enqueue<Value: Sendable>(id: UUID, fallback: Value,
                                        work: @escaping @MainActor () async -> Value) -> Task<Value,Never> {
        let previous = queue
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return fallback }
            defer { active.removeValue(forKey: id); if active.isEmpty { queue = nil } }
            guard !Task.isCancelled else { return fallback }
            return await withTaskCancellationHandler(operation: work, onCancel: {
                Task { @MainActor [weak self] in self?.cancelWorkers(id) }
            })
        }
        active[id] = { task.cancel() }
        queue = Task { _ = await task.value }
        return task
    }
    /// Each menu opening gets a fresh, read-only lookup. Cancelling that menu only
    /// cancels its own helper, never an action already submitted by another menu.
    func status(_ repository: GitHubRepository, store: WKWebsiteDataStore, host: UIView) async -> Status {
        let id = UUID()
        let task = enqueue(id: id,fallback: Status.cancelled) { [weak self, weak host] in
            guard let self, let host, host.window != nil else { return .cancelled }
            let page = makePage(id: id,store: store,host: host)
            defer { cancelWorkers(id) }
            do {
                let found = try await page.probe(repository)
                switch found.status {
                case "already": return .starred
                case "ready": return .unstarred
                case "signedOut": return .signedOut
                case "notFound": return .notFound
                default: return .failed
                }
            } catch { return Task.isCancelled || error is CancellationError ? .cancelled : .failed }
        }
        return await withTaskCancellationHandler(operation: { await task.value },onCancel: { task.cancel() })
    }
    func star(_ repository: GitHubRepository, store: WKWebsiteDataStore, host: UIView) async -> Outcome {
        await set(.star,repository: repository,store: store,host: host)
    }
    func unstar(_ repository: GitHubRepository, store: WKWebsiteDataStore, host: UIView) async -> Outcome {
        await set(.unstar,repository: repository,store: store,host: host)
    }
    func set(_ action: Action, repository: GitHubRepository, store: WKWebsiteDataStore, host: UIView) async -> Outcome {
        let key = Key(repository: repository.path.lowercased(),store: ObjectIdentifier(store))
        // Only merge the latest identical intention. Star → Unstar → Star must
        // remain three ordered requests, rather than reusing the first Star task.
        if let latest = pending[key], latest.action == action { return await latest.task.value }
        let id = UUID()
        let task = enqueue(id: id,fallback: Outcome.cancelled) { [weak self, weak host] in
            guard let self, let host, host.window != nil else { return .cancelled }
            return await run(action,repository: repository,store: store,host: host,id: id)
        }
        pending[key] = Mutation(id: id,action: action,task: task)
        let outcome = await task.value
        if pending[key]?.id == id { pending.removeValue(forKey: key) }
        return outcome
    }
    func cancelAll() {
        Array(active.values).forEach { $0() }
        Array(workers.keys).forEach { cancelWorkers($0) }
    }
    private func makePage(id: UUID,store: WKWebsiteDataStore,host: UIView) -> GitHubStarPage {
        let page = GitHubStarPage(store: store,host: host,origin: origin,timeout: loadTimeout)
        workers[id,default: []].append(page); return page
    }
    private func cancelWorkers(_ id: UUID) {
        workers.removeValue(forKey: id)?.forEach { $0.cancel() }
    }
    private func run(_ action: Action, repository: GitHubRepository, store: WKWebsiteDataStore, host: UIView, id: UUID) async -> Outcome {
        let page = makePage(id: id,store: store,host: host)
        defer { cancelWorkers(id) }
        do {
            let found = try await page.probe(repository,starred: action.starred)
            trace("probe \(action): \(found.status ?? "nil"), form: \(found.form)")
            switch found.status {
            case "already": return .alreadyStarred
            case "alreadyUnstarred": return .alreadyUnstarred
            case "signedOut": return .signedOut
            case "notFound": return .notFound
            case "ready": break
            default: return .failed
            }
            if !found.form {
                let deadline = Date().addingTimeInterval(8)
                var wired = false
                repeat {
                    try Task.checkCancellation()
                    wired = try await page.evaluate(GitHubStarScripts.wired,world: .page).wired
                    if !wired { try await Task.sleep(for: .milliseconds(150)) }
                } while !wired && Date() < deadline
                guard wired else { return .failed }
            }
            // A plain form can navigate during the script. Never press twice.
            _ = try? await page.evaluate(GitHubStarScripts.press(starred: action.starred))
            try Task.checkCancellation()
            let verifier = makePage(id: id,store: store,host: host)
            let deadline = Date().addingTimeInterval(verificationTimeout)
            repeat {
                try Task.checkCancellation()
                let status = try await verifier.probe(repository,starred: action.starred).status
                trace("verify \(action): \(status ?? "nil")")
                if status == (action.starred ? "already" : "alreadyUnstarred") { return action.starred ? .starred : .unstarred }
                if status == "signedOut" { return .signedOut }
                if status == "notFound" { return .notFound }
                try await Task.sleep(for: .milliseconds(200))
            } while Date() < deadline
            return .failed
        } catch {
            trace("error: \(error)")
            return Task.isCancelled || error is CancellationError ? .cancelled : .failed
        }
    }
}

/// One attached, inaccessible helper page; no history, tabs, permission UI or external navigation.
@MainActor private final class GitHubStarPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Value: Sendable { var status: String?; var form = false; var wired = false; var detail: String? }
    private let page: WKWebView
    private let origin: URL
    private let timeout: TimeInterval
    private var loading: CheckedContinuation<Void, Error>?
    private var evaluating: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?
    private var cancelled = false
    private var evaluationID = UUID()
    private enum Failure: Error { case unavailable, timeout }
    private static let world = WKContentWorld.world(name: "RiseGitHubStar")

    init(store: WKWebsiteDataStore, host: UIView, origin: URL, timeout: TimeInterval) {
        self.origin = origin; self.timeout = timeout
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsPictureInPictureMediaPlayback = false
        page = WKWebView(frame: CGRect(x: -20000, y: 0, width: 1280, height: 900), configuration: config)
        super.init()
        page.navigationDelegate = self; page.uiDelegate = self
        page.isUserInteractionEnabled = false; page.accessibilityElementsHidden = true
        page.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        host.addSubview(page)
    }
    func probe(_ repository: GitHubRepository, starred: Bool = true) async throws -> Value {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let url = origin.appendingPathComponent(repository.owner).appendingPathComponent(repository.name)
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            armDeadline(timeout)
            page.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        }
        guard allows(page.url) else { throw Failure.unavailable }
        return try await evaluate(GitHubStarScripts.find(starred: starred))
    }
    func evaluate(_ script: String, world: WKContentWorld = GitHubStarPage.world) async throws -> Value {
        try Task.checkCancellation()
        guard !cancelled, allows(page.url) else { throw Failure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); evaluationID = id
            evaluating = continuation
            armDeadline(12)
            page.callAsyncJavaScript(script, arguments: [:], in: nil, in: world) { [weak self] result in
                guard let self, evaluationID == id, let continuation = evaluating else { return }
                evaluating = nil; deadline?.cancel(); deadline = nil
                switch result {
                case .success(let raw):
                    let dictionary = raw as? [String: Any]
                    continuation.resume(returning: Value(status: dictionary?["status"] as? String,
                        form: dictionary?["form"] as? Bool == true, wired: raw as? Bool == true, detail: dictionary?["detail"] as? String))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func armDeadline(_ seconds: TimeInterval) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)); self?.fail(Failure.timeout) } catch { }
        }
    }
    private func fail(_ error: Error) {
        deadline?.cancel(); deadline = nil
        let load = loading, evaluation = evaluating; loading = nil; evaluating = nil
        load?.resume(throwing: error); evaluation?.resume(throwing: error)
    }
    func cancel() {
        cancelled = true; fail(CancellationError())
        page.stopLoading(); page.navigationDelegate = nil; page.uiDelegate = nil; page.removeFromSuperview()
    }
    private func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port && url.user == nil && url.password == nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame != nil, !action.shouldPerformDownload else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == true, !allows(action.request.url) {
            decisionHandler(.cancel); fail(Failure.unavailable)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !response.isForMainFrame || response.canShowMIMEType else { decisionHandler(.cancel); fail(Failure.unavailable); return }
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           http.statusCode >= 400 && http.statusCode != 404 {
            decisionHandler(.cancel); fail(Failure.unavailable); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loading != nil else { return }
        deadline?.cancel(); deadline = nil
        let continuation = loading; loading = nil; continuation?.resume()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(Failure.unavailable) }
}
