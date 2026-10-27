import Foundation

/// A pull request on github.com or a merge request on GitLab, from any of its pages
/// (conversation, commits, files or changes).
struct PullRequest: Equatable {
    enum Forge: Equatable { case github, gitlab(host: String) }
    let forge: Forge
    /// "owner/repo" on GitHub; on GitLab the project's full path, subgroups included.
    let project: String
    let number: Int
    /// GitHub's keys stay "owner/repo#12", as saved cards have them.
    var key: String {
        switch forge {
        case .github: return "\(project)#\(number)"
        case .gitlab(let host): return "\(host)/\(project)!\(number)"
        }
    }
    var reference: String { forge == .github ? "#\(number)" : "!\(number)" }
    /// The conversation on GitHub, the overview on GitLab.
    var overviewURL: URL? {
        switch forge {
        case .github: return URL(string: "https://github.com/\(project)/pull/\(number)")
        case .gitlab(let host): return URL(string: "https://\(host)/\(project)/-/merge_requests/\(number)")
        }
    }
    /// GitHub's "Files changed", GitLab's "Changes".
    var filesURL: URL? {
        switch forge {
        case .github: return URL(string: "https://github.com/\(project)/pull/\(number)/files")
        case .gitlab(let host): return URL(string: "https://\(host)/\(project)/-/merge_requests/\(number)/diffs")
        }
    }
    init?(url: URL?) {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host.replacingOccurrences(of: "www.", with: "") == "github.com" {
            guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
            forge = .github; project = "\(parts[0])/\(parts[1])"; self.number = number
            return
        }
        // GitLab, on gitlab.com or a company's own server: group/subgroup/project/-/merge_requests/12.
        guard let dash = parts.firstIndex(of: "-"), dash >= 2, parts.count > dash+2,
              parts[dash+1] == "merge_requests", let number = Int(parts[dash+2]) else { return nil }
        forge = .gitlab(host: host); project = parts[..<dash].joined(separator: "/"); self.number = number
    }
    /// The tab's title down to the request's own. GitHub: "Title by author · Pull Request #12 ·
    /// owner/repo". GitLab: "Title (!12) · Merge requests · Group / Project · GitLab".
    func title(fromTab title: String) -> String {
        var title = title
        switch forge {
        case .github:
            title = title.components(separatedBy: " · Pull Request #").first ?? title
            if let by = title.range(of: " by ", options: .backwards) { title = String(title[..<by.lowerBound]) }
        case .gitlab:
            if let end = title.range(of: " (\(reference)) · ") ?? title.range(of: " · ") { title = String(title[..<end.lowerBound]) }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

struct PullRequestDetails: Equatable, Codable {
    enum State: String, Codable { case open, draft, merged, closed }
    let title: String, state: State, commits: Int, changedFiles: Int, additions: Int, deletions: Int
    /// A GitLab merge request's latest pipeline, and whether it can be merged.
    var pipeline: Pipeline?, mergeCheck: MergeCheck?
    /// Only for writing the description; never saved.
    var body = "", diff = ""
    /// The lines split by kind of file, when every changed file was counted: with the details on
    /// GitLab, read on first hover of the file count on GitHub.
    var breakdown: ChangeBreakdown?
    private enum CodingKeys: String, CodingKey { case title, state, commits, changedFiles, additions, deletions, pipeline, mergeCheck, breakdown }
}

/// Whether an open merge request can be merged, and if not, what's in the way.
struct MergeCheck: Equatable, Codable {
    /// Short names for each thing in the way, as GitLab's merge checks list them.
    let blockers: [String]
    var ready: Bool { blockers.isEmpty }

    /// GitLab names only the first thing in the way (`detailed_merge_status`), so the rest come
    /// from the merge request's own fields and its approvals. Nil while GitLab hasn't checked yet.
    init?(gitLab object: [String: Any], approvals: [String: Any]?) {
        guard object["state"] as? String == "opened" else { return nil }
        let status = object["detailed_merge_status"] as? String ?? ""
        var blockers: [String] = []
        if object["draft"] as? Bool == true || status == "draft_status" { blockers.append("Draft") }
        if object["has_conflicts"] as? Bool == true || status == "conflict" { blockers.append("Conflicts") }
        if status == "need_rebase" { blockers.append("Rebase") }
        if object["blocking_discussions_resolved"] as? Bool == false || status == "discussions_not_resolved" { blockers.append("Open threads") }
        let pipeline = Pipeline(gitLab: object["head_pipeline"] as? [String: Any])
        // Whether a project needs a passing pipeline isn't public; GitLab saying so, or a pipeline
        // that hasn't passed on a merge request already blocked, counts.
        let pipelinePending = pipeline.map { ![.success, .warning, .skipped, .manual].contains($0.status) } ?? false
        // GitLab's own name for the check when it says so; only "Pipeline" when it's inferred.
        if ["ci_must_pass", "ci_still_running"].contains(status) { blockers.append("Pipeline must succeed") }
        else if pipelinePending && !["mergeable", "unchecked", "checking", "preparing"].contains(status) { blockers.append("Pipeline") }
        let required = approvals?["approvals_required"] as? Int ?? 0, left = approvals?["approvals_left"] as? Int ?? 0
        if left > 0 { blockers.append("\(required-left) of \(required) \(required == 1 ? "Approval" : "Approvals")") }
        else if status == "not_approved" { blockers.append("Approvals") }
        if status == "requested_changes" { blockers.append("Changes requested") }
        let others = ["external_status_checks": "Status checks", "status_checks_must_pass": "Status checks", "jira_association_missing": "Jira issue",
                      "merge_request_blocked": "Blocked by another MR", "security_policy_violations": "Security policy", "locked_paths": "Locked files",
                      "locked_lfs_files": "Locked files", "title_regex": "Title", "commits_status": "Commits", "broken_status": "Broken"]
        if let other = others[status], !blockers.contains(other) { blockers.append(other) }
        // Not checked yet and nothing known in the way: unknown rather than ready.
        if blockers.isEmpty, status != "mergeable" { return nil }
        self.blockers = blockers
    }
}

/// The latest pipeline on a merge request, as GitLab's status icons show it.
struct Pipeline: Equatable, Codable {
    enum Status: String, Codable {
        case running, pending, success, warning, failed, canceled, skipped, manual, created
        /// From GitLab's `detailed_status.icon`, which also tells passed-with-warnings apart.
        init(icon: String?, status: String?) {
            let name = icon?.replacingOccurrences(of: "status_", with: "") ?? status ?? ""
            switch name {
            case "running": self = .running
            case "success": self = .success
            case "warning", "success-with-warnings", "success_with_warnings": self = .warning
            case "failed": self = .failed
            case "canceled", "canceling": self = .canceled
            case "skipped": self = .skipped
            case "manual": self = .manual
            case "created": self = .created
            default: self = .pending // pending, preparing, waiting for a resource, scheduled
            }
        }
    }
    let id: Int, status: Status, label: String, url: String
    /// The pipeline's jobs, the view that says what's running or broke.
    var jobsURL: URL? { URL(string: url+"/builds") }
    init(id: Int, status: Status, label: String, url: String) { self.id = id; self.status = status; self.label = label; self.url = url }
    init?(gitLab object: [String: Any]?) {
        guard let object, let id = object["id"] as? Int, let url = object["web_url"] as? String else { return nil }
        let detailed = object["detailed_status"] as? [String: Any]
        status = Status(icon: detailed?["icon"] as? String, status: object["status"] as? String)
        label = detailed?["text"] as? String ?? (object["status"] as? String ?? "").capitalized
        self.id = id; self.url = url
    }
}

/// Public pull and merge requests, which need no sign-in.
enum PullRequestAPI {
    static let diffLimit = 40_000

    static func details(_ pr: PullRequest, session: URLSession = .shared) async throws -> PullRequestDetails {
        switch pr.forge {
        case .github: return try await GitHubAPI.details(pr, session: session)
        case .gitlab: return try await GitLabAPI.details(pr, session: session)
        }
    }
    /// The start of the diff; enough to say what changed without downloading a huge one.
    static func diff(_ pr: PullRequest, details: PullRequestDetails?, session: URLSession = .shared) async throws -> String {
        // GitLab's details already came with the diff, to count its lines.
        if let diff = details?.diff, !diff.isEmpty { return diff }
        guard pr.forge == .github else { return "" }
        return try await GitHubAPI.diff(pr, session: session)
    }
}

/// GitHub's REST API, and its pages where the API's limit has run out.
enum GitHubAPI {
    /// The API turned a request away for its hourly limit, which comes back at `until`.
    struct Limited: Error { let until: Date }
    /// A whole diff is read up to this, to count its lines.
    static let wholeDiffLimit = 8_000_000

    static func details(_ pr: PullRequest, session: URLSession = .shared) async throws -> PullRequestDetails {
        let (data, response) = try await session.data(for: request(pr, accept: "application/vnd.github+json"))
        if let response = response as? HTTPURLResponse, [403, 429].contains(response.statusCode),
           response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
            throw Limited(until: reset.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(60*60))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { throw URLError(.badServerResponse) }
        let state: PullRequestDetails.State = object["merged"] as? Bool == true ? .merged
            : object["state"] as? String == "closed" ? .closed : object["draft"] as? Bool == true ? .draft : .open
        return PullRequestDetails(title: title, state: state, commits: object["commits"] as? Int ?? 0,
                                  changedFiles: object["changed_files"] as? Int ?? 0, additions: object["additions"] as? Int ?? 0,
                                  deletions: object["deletions"] as? Int ?? 0, body: object["body"] as? String ?? "")
    }
    /// The pull request's diff, up to `limit` bytes, from github.com rather than the API, whose
    /// 60 requests an hour without a token every card shares.
    static func diff(_ pr: PullRequest, limit: Int = PullRequestAPI.diffLimit, session: URLSession = .shared) async throws -> String {
        var call = URLRequest(url: URL(string: "https://github.com/\(pr.project)/pull/\(pr.number).diff")!)
        call.setValue("Rise", forHTTPHeaderField: "User-Agent"); call.timeoutInterval = 15
        let (bytes, response) = try await session.bytes(for: call)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count >= limit { break } }
        return String(decoding: data, as: UTF8.self)
    }
    /// The details from what GitHub shows on its own pages, none of which counts against the API's
    /// limit: its hover card for the title, the state and the start of the description, and the
    /// whole diff for the lines and their split, and to describe it from.
    static func pageDetails(_ pr: PullRequest, session: URLSession = .shared) async throws -> PullRequestDetails {
        var call = URLRequest(url: URL(string: "https://github.com/\(pr.project)/pull/\(pr.number)/hovercard")!)
        call.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        call.setValue("text/html", forHTTPHeaderField: "Accept"); call.timeoutInterval = 15
        let request = call
        async let card = session.data(for: request)
        async let whole = diff(pr, limit: wholeDiffLimit, session: session)
        let ((data, response), diff) = try await (card, whole)
        guard (response as? HTTPURLResponse)?.statusCode == 200, diff.utf8.count < wholeDiffLimit,
              let shown = hovercard(String(decoding: data, as: UTF8.self)) else { throw URLError(.badServerResponse) }
        let read = ChangeBreakdown.read(diff: diff)
        let files = diff.split(separator: "\n").reduce(0) { $0 + ($1.hasPrefix("diff --git ") ? 1 : 0) }
        return PullRequestDetails(title: shown.title, state: shown.state, commits: 0, changedFiles: files,
                                  additions: read.lines.additions, deletions: read.lines.deletions,
                                  body: shown.body, diff: String(diff.prefix(PullRequestAPI.diffLimit)), breakdown: read.breakdown)
    }
    /// The title, state and start of the description in GitHub's hover card for a pull request.
    static func hovercard(_ html: String) -> (title: String, state: PullRequestDetails.State, body: String)? {
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        func plain(_ fragment: String) -> String {
            var text = fragment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
                text = text.replacingOccurrences(of: entity, with: character)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let title = first(#"<h4[^>]*markdown-title[^>]*>(.*?)</h4>"#).map(plain), !title.isEmpty else { return nil }
        let state: PullRequestDetails.State = switch first(#"title="Status: ([a-z ]+)""#)?.lowercased() {
            case "merged": .merged
            case "closed": .closed
            case "draft": .draft
            default: .open
        }
        return (title, state, first(#"class="[^"]*markdown-body-short[^"]*"[^>]*>(.*?)</div>"#).map(plain) ?? "")
    }
    /// The split from the whole diff, when it adds up to the pull request's own count; otherwise
    /// the API's file list.
    static func breakdown(_ pr: PullRequest, details: PullRequestDetails, session: URLSession = .shared) async throws -> ChangeBreakdown? {
        let limit = wholeDiffLimit
        if let diff = try? await Self.diff(pr, limit: limit, session: session), diff.utf8.count < limit {
            let read = ChangeBreakdown.read(diff: diff)
            if read.lines == ChangeBreakdown.Lines(additions: details.additions, deletions: details.deletions) { return read.breakdown }
        }
        return try await breakdown(pr, changedFiles: details.changedFiles, session: session)
    }
    /// The changed files' lines by kind, read 100 files at a time; nil when there are more files
    /// than that reads, so the split always adds up to the whole.
    static func breakdown(_ pr: PullRequest, changedFiles: Int, session: URLSession = .shared) async throws -> ChangeBreakdown? {
        var breakdown = ChangeBreakdown(), counted = 0
        for page in 1...GitLabAPI.maximumFilePages {
            var call = request(pr, accept: "application/vnd.github+json")
            call.url = URL(string: "https://api.github.com/repos/\(pr.project)/pulls/\(pr.number)/files?per_page=100&page=\(page)")
            let (data, response) = try await session.data(for: call)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw URLError(.badServerResponse)
            }
            for file in files {
                breakdown.add(path: file["filename"] as? String ?? "", additions: file["additions"] as? Int ?? 0, deletions: file["deletions"] as? Int ?? 0)
            }
            counted += files.count
            if files.count < 100 { break }
        }
        return counted >= changedFiles ? breakdown : nil
    }
    private static func request(_ pr: PullRequest, accept: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(pr.project)/pulls/\(pr.number)")!)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Rise", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }
}

/// GitLab's REST API (v4), on whichever server the merge request is on.
enum GitLabAPI {
    /// Changed files are read 100 at a time; past this many, the line counts stop growing.
    static let maximumFilePages = 5
    /// How a request gets to the server, its body and status back: by itself, or through a page
    /// signed in to it, as a private server answers only someone signed in.
    typealias Fetch = @MainActor (URL) async throws -> (data: Data, status: Int)
    static func fetch(_ session: URLSession) -> Fetch {
        { url in
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Rise", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
    /// Through `page`, with its sign-in, as the server's own pages ask it.
    @MainActor static func fetch(through page: WebPage) -> Fetch {
        { [weak page] url in
            guard let page else { throw URLError(.cancelled) }
            let answer = await page.evaluate("""
                const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' } });
                return [response.status, await response.text()];
                """, arguments: ["url": url.absoluteString], world: nil) as? [Any]
            guard let answer, answer.count == 2, let status = (answer[0] as? NSNumber)?.intValue, let body = answer[1] as? String else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), status)
        }
    }

    /// The pipeline and merge checks, which move on by the minute, unlike the rest.
    static func status(_ pr: PullRequest, session: URLSession = .shared) async throws -> (pipeline: Pipeline?, mergeCheck: MergeCheck?) {
        try await status(pr, fetch: fetch(session))
    }
    static func status(_ pr: PullRequest, fetch: Fetch) async throws -> (pipeline: Pipeline?, mergeCheck: MergeCheck?) {
        guard let object = try await json(pr, path: "", fetch: fetch) as? [String: Any] else { throw URLError(.badServerResponse) }
        return await status(pr, object: object, fetch: fetch)
    }
    private static func status(_ pr: PullRequest, object: [String: Any], fetch: Fetch) async -> (pipeline: Pipeline?, mergeCheck: MergeCheck?) {
        let approvals = object["state"] as? String == "opened" ? try? await json(pr, path: "/approvals", fetch: fetch) as? [String: Any] : nil
        return (Pipeline(gitLab: object["head_pipeline"] as? [String: Any]), MergeCheck(gitLab: object, approvals: approvals))
    }
    static func details(_ pr: PullRequest, session: URLSession = .shared) async throws -> PullRequestDetails {
        try await details(pr, fetch: fetch(session))
    }
    static func details(_ pr: PullRequest, fetch: Fetch) async throws -> PullRequestDetails {
        let object = try await json(pr, path: "", fetch: fetch) as? [String: Any]
        guard let object, let title = object["title"] as? String else { throw URLError(.badServerResponse) }
        let status = await status(pr, object: object, fetch: fetch)
        let state: PullRequestDetails.State = switch object["state"] as? String {
            case "merged": .merged
            case "closed", "locked": .closed
            default: object["draft"] as? Bool == true || object["work_in_progress"] as? Bool == true ? .draft : .open
        }
        // The merge request itself has no line counts; they come from its changed files.
        var files = 0, additions = 0, deletions = 0, diff = "", breakdown = ChangeBreakdown()
        for page in 1...maximumFilePages {
            guard let changes = try? await json(pr, path: "/diffs?per_page=100&page=\(page)", fetch: fetch) as? [[String: Any]] else { break }
            for change in changes {
                files += 1
                let text = change["diff"] as? String ?? ""
                var added = 0, removed = 0
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
                }
                additions += added; deletions += removed
                breakdown.add(path: change["new_path"] as? String ?? change["old_path"] as? String ?? "", additions: added, deletions: removed)
                if diff.utf8.count < PullRequestAPI.diffLimit, let path = change["new_path"] as? String {
                    diff += "diff --git a/\(change["old_path"] as? String ?? path) b/\(path)\n\(text)\n"
                }
            }
            if changes.count < 100 { break }
        }
        let changed = Int((object["changes_count"] as? String ?? "").filter(\.isNumber)) ?? files
        return PullRequestDetails(title: title, state: state, commits: 0, changedFiles: max(changed, files),
                                  additions: additions, deletions: deletions, pipeline: status.pipeline, mergeCheck: status.mergeCheck,
                                  body: object["description"] as? String ?? "", diff: String(diff.prefix(PullRequestAPI.diffLimit)),
                                  // Only when every file was read, so the split adds up to the whole.
                                  breakdown: files >= changed ? breakdown : nil)
    }
    private static func json(_ pr: PullRequest, path: String, fetch: Fetch) async throws -> Any {
        guard case .gitlab(let host) = pr.forge,
              let project = pr.project.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))),
              let url = URL(string: "https://\(host)/api/v4/projects/\(project)/merge_requests/\(pr.number)\(path)") else { throw URLError(.badURL) }
        let (data, status) = try await fetch(url)
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// A short description of a pull request for its tab's hover card, from the find bar's model.
enum PullRequestSummarizer {
    static let systemPrompt = """
    You write the description in a browser's hover card for a GitHub pull request or a GitLab merge request. The card already shows the title, status and diff size.

    Write one or two short sentences, at most 35 words, saying what the change does and why. Start directly with a verb, such as "Fixes", "Adds", "Removes" or "Speeds up". Never start with or mention "This PR", "This MR", "This pull request", "This merge request", "This change" or "The author", and don't repeat the title, number, author or repository. Write plain text only: no Markdown, quotes, lists or line breaks.
    """
    static func messages(title: String, body: String, diff: String, page: String) -> [[String: Any]] {
        var context = "Title: \(title)\n"
        if !body.isEmpty { context += "\nDescription:\n\(body.prefix(4_000))\n" }
        if !diff.isEmpty { context += "\nDiff (may be cut off):\n\(diff.prefix(16_000))\n" }
        if !page.isEmpty { context += "\nPull request page:\n\(page.prefix(20_000))\n" }
        return [["role": "system", "content": systemPrompt], ["role": "user", "content": context]]
    }
    /// `inputTokens` hears how many tokens the request took in, as the find bar's menu shows.
    static func summarize(_ messages: [[String: Any]], provider: ModelChoice = .openRouter,
                          session: URLSession = .shared,
                          inputTokens: @escaping @MainActor (Int) -> Void = { _ in }) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await ModelService.run(messages, provider: provider, session: session) { event in
                        switch event {
                        case .text(let content): continuation.yield(content)
                        case .inputTokens(let count): await inputTokens(count)
                        case .responded: break
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pull request details and descriptions, kept on disk. A saved card shows at once; its
/// details refresh once a launch, and each pull request is described only once.
@MainActor final class PullRequestSummaries {
    enum Phase { case idle, generating, done, failed }
    struct Entry {
        var details: PullRequestDetails?
        var summary = ""
        var phase = Phase.idle
        /// What writing the description took in, for the card's menu.
        var inputTokens: Int?
        /// The title and description as edited in the card (nil where not), shown instead of the
        /// request's own while `usesCustom`.
        var custom = Custom()
    }
    struct Custom: Codable, Equatable {
        var title: String?, summary: String?, shown = false
        var exists: Bool { title != nil || summary != nil }
    }
    private struct Saved: Codable { var summary: String?; var details: PullRequestDetails?; var inputTokens: Int?; var custom: Custom? }
    private(set) var entries: [String: Entry] = [:]
    private var saved: [String: Saved]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var breakdownTasks: [String: Task<Void, Never>] = [:]
    /// GitHub pull requests whose split couldn't be read, and when: asked for again a while after,
    /// as GitHub's hourly limit comes back.
    private var breakdownFailures: [String: Date] = [:]
    static let breakdownRetry: TimeInterval = 5*60
    private var statusChecks: [String: Date] = [:]
    /// When GitHub's API turned Rise away for its hourly limit, it's back then; until then
    /// details come from GitHub's pages.
    private var gitHubLimitedUntil = Date.distantPast
    /// What a card says when nothing could describe its pull or merge request.
    static func failure(_ pr: PullRequest) -> String {
        if case .gitlab = pr.forge { return "Couldn’t load this merge request." }
        return "Couldn’t load this pull request."
    }
    /// A page signed in to a server (by its host), to ask a private one through: an open one, or
    /// one opened offscreen for it.
    var signedInPage: (String) async -> WebPage? = { _ in nil }
    /// GitLab servers that only answered through a signed-in page: asked that way from then on.
    private var signedInHosts: Set<String> = []
    /// A pipeline and merge checks are checked again when the card shows, at most this often.
    static let statusRefresh: TimeInterval = 10
    private let storageURL: URL
    var onChange: ((String) -> Void)?
    /// Which service writes descriptions.
    var provider: () -> ModelChoice = { .openRouter }

    init(storageURL: URL) {
        self.storageURL = storageURL
        let data = try? Data(contentsOf: storageURL)
        saved = data.flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) }
            // Earlier files kept only descriptions.
            ?? data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?.mapValues { Saved(summary: $0) } ?? [:]
    }
    func entry(for pr: PullRequest) -> Entry {
        let saved = saved[pr.key]
        var entry = entries[pr.key] ?? Entry(details: saved?.details, summary: saved?.summary ?? "", phase: saved?.summary == nil ? .idle : .done,
                                             inputTokens: saved?.summary == nil ? nil : saved?.inputTokens)
        entry.custom = saved?.custom ?? Custom()
        return entry
    }
    /// Keeps what was edited in the card, a field left nil keeping its earlier edit, and shows it.
    func setCustom(_ key: String, title: String?, summary: String?) {
        var custom = saved[key]?.custom ?? Custom()
        if let title { custom.title = title }
        if let summary { custom.summary = summary }
        custom.shown = true
        saved[key, default: Saved()].custom = custom; save(); onChange?(key)
    }
    /// Shows the edited title and description, or the request's own again.
    func showCustom(_ key: String, _ shown: Bool) {
        guard saved[key]?.custom?.exists == true else { return }
        saved[key]?.custom?.shown = shown; save(); onChange?(key)
    }
    /// Fetches the details and, unless one is saved, writes the description. Keeps going
    /// when the card closes, so the description is ready next time.
    func load(_ pr: PullRequest, title: String, page: @escaping @MainActor () async -> String?) {
        guard tasks[pr.key] == nil, entries[pr.key].map({ $0.phase == .failed }) ?? true else { return }
        entries[pr.key] = entries[pr.key].map { Entry(details: $0.details) } ?? entry(for: pr)
        let key = pr.key
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            let fetched = await self.fetchDetails(pr)
            if var fetched {
                self.statusChecks[key] = Date()
                // GitHub's split is read on its own; it holds while the diff's size does.
                if fetched.breakdown == nil, let old = self.entries[key]?.details ?? self.saved[key]?.details, let split = old.breakdown,
                   (old.changedFiles, old.additions, old.deletions) == (fetched.changedFiles, fetched.additions, fetched.deletions) {
                    fetched.breakdown = split
                }
                self.update(key) { $0.details = fetched }
                self.saved[key, default: Saved()].details = fetched; self.save()
            }
            let details = fetched ?? self.entries[key]?.details
            guard self.entries[key]?.phase != .done else { self.tasks[key] = nil; return }
            self.update(key) { $0.phase = .generating }
            let diff = details == nil ? "" : (try? await PullRequestAPI.diff(pr, details: fetched)) ?? ""
            // Private repositories aren't in the public API; the open page can still describe them.
            let pageText = details == nil ? await page() ?? "" : ""
            var text = ""
            do {
                guard details != nil || !pageText.isEmpty else { throw URLError(.resourceUnavailable) }
                let messages = PullRequestSummarizer.messages(title: details?.title ?? title, body: details?.body ?? "", diff: diff, page: pageText)
                let counted: @MainActor (Int) -> Void = { [weak self] count in
                    self?.update(key) { $0.inputTokens = count }
                    self?.saved[key, default: Saved()].inputTokens = count
                }
                for try await chunk in PullRequestSummarizer.summarize(messages, provider: self.provider(), inputTokens: counted) {
                    text += chunk
                    self.update(key) { $0.summary = text }
                }
                let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty else { throw URLError(.zeroByteResource) }
                self.saved[key, default: Saved()].summary = summary; self.save()
                self.update(key) { $0.summary = summary; $0.phase = .done }
            } catch {
                self.update(key) { $0.phase = text.isEmpty ? .failed : .done }
            }
            self.tasks[key] = nil
        }
    }
    /// GitHub's API while its hourly limit lasts, and GitHub's pages when it's gone or the API fails.
    private func fetchDetails(_ pr: PullRequest) async -> PullRequestDetails? {
        if case .gitlab(let host) = pr.forge {
            if !signedInHosts.contains(host), let details = try? await GitLabAPI.details(pr) { return details }
            // A private server: through a page signed in to it, as its own pages ask.
            guard let page = await signedInPage(host), let details = try? await GitLabAPI.details(pr, fetch: GitLabAPI.fetch(through: page)) else { return nil }
            signedInHosts.insert(host)
            return details
        }
        if Date() >= gitHubLimitedUntil {
            do { return try await GitHubAPI.details(pr) }
            catch let limited as GitHubAPI.Limited { gitHubLimitedUntil = limited.until }
            catch {}
        }
        return try? await GitHubAPI.pageDetails(pr)
    }
    /// The split of a GitHub pull request's lines by kind of file, read the first time its file
    /// count is hovered, so a card nobody looks into costs no more requests.
    func loadBreakdown(_ pr: PullRequest) {
        let key = pr.key
        guard case .github = pr.forge, breakdownTasks[key] == nil,
              Date().timeIntervalSince(breakdownFailures[key] ?? .distantPast) > Self.breakdownRetry,
              let details = entries[key]?.details, details.breakdown == nil else { return }
        breakdownTasks[key] = Task { [weak self] in
            let breakdown = try? await GitHubAPI.breakdown(pr, details: details)
            guard let self else { return }
            self.breakdownTasks[key] = nil
            guard let breakdown else { self.breakdownFailures[key] = Date(); self.onChange?(key); return }
            self.breakdownFailures[key] = nil
            self.update(key) { $0.details?.breakdown = breakdown }
            self.saved[key]?.details?.breakdown = breakdown; self.save()
        }
        onChange?(key)
    }
    /// The split is on its way.
    func isLoadingBreakdown(_ pr: PullRequest) -> Bool { breakdownTasks[pr.key] != nil }
    /// Writes the description again, in place of the saved one. Not while one is being written.
    func regenerate(_ pr: PullRequest, title: String, page: @escaping @MainActor () async -> String?) {
        let key = pr.key
        guard tasks[key] == nil else { return }
        // A new description shows; the edits stay, to show again from the menu.
        saved[key]?.summary = nil; saved[key]?.inputTokens = nil; saved[key]?.custom?.shown = false; save()
        entries[key] = nil
        load(pr, title: title, page: page)
        onChange?(key)
    }
    /// Pipelines and merge checks change by the minute, unlike the rest of a merge request;
    /// each time its card shows, a GitLab merge request checks them again.
    func refreshStatus(_ pr: PullRequest) {
        let key = pr.key
        guard case .gitlab = pr.forge, tasks[key] == nil, entries[key]?.details != nil,
              Date().timeIntervalSince(statusChecks[key] ?? .distantPast) > Self.statusRefresh else { return }
        statusChecks[key] = Date()
        Task { [weak self] in
            guard let self, let status = try? await GitLabAPI.status(pr, fetch: await self.gitLabFetch(pr)), var details = self.entries[key]?.details,
                  details.pipeline != status.pipeline || details.mergeCheck != status.mergeCheck else { return }
            details.pipeline = status.pipeline; details.mergeCheck = status.mergeCheck
            self.update(key) { $0.details = details }
            self.saved[key, default: Saved()].details = details; self.save()
        }
    }
    /// Through a signed-in page for a server that needs one; otherwise by itself.
    private func gitLabFetch(_ pr: PullRequest) async -> GitLabAPI.Fetch {
        guard case .gitlab(let host) = pr.forge, signedInHosts.contains(host), let page = await signedInPage(host) else { return GitLabAPI.fetch(.shared) }
        return GitLabAPI.fetch(through: page)
    }
    private func update(_ key: String, _ change: (inout Entry) -> Void) {
        var entry = entries[key] ?? Entry(); change(&entry); entries[key] = entry
        onChange?(key)
    }
    private func save() {
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: storageURL, options: .atomic)
    }
}
