import Foundation
import WebKit

/// A pull request on github.com, from any of its pages (conversation, commits, files).
struct GitHubPullRequest: Equatable {
    let owner: String, repo: String, number: Int
    var key: String { "\(owner)/\(repo)#\(number)" }
    init?(url: URL?) {
        guard let url, url.host()?.lowercased().replacingOccurrences(of: "www.", with: "") == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        owner = parts[0]; repo = parts[1]; self.number = number
    }
    /// GitHub's tab title, "Title by author · Pull Request #12 · owner/repo", down to the title.
    static func title(fromTab title: String) -> String {
        var title = title.components(separatedBy: " · Pull Request #").first ?? title
        if let by = title.range(of: " by ", options: .backwards) { title = String(title[..<by.lowerBound]) }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

struct PullRequestDetails: Equatable, Codable {
    enum State: String, Codable { case open, draft, merged, closed }
    let title: String, state: State, commits: Int, changedFiles: Int, additions: Int, deletions: Int
    /// Only for writing the description; never saved.
    var body = ""
    private enum CodingKeys: String, CodingKey { case title, state, commits, changedFiles, additions, deletions }
}

/// Public pull requests through GitHub's REST API, which needs no sign-in.
enum GitHubAPI {
    static let diffLimit = 40_000

    static func details(_ pr: GitHubPullRequest, session: URLSession = .shared) async throws -> PullRequestDetails {
        let (data, response) = try await session.data(for: request(pr, accept: "application/vnd.github+json"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { throw URLError(.badServerResponse) }
        let state: PullRequestDetails.State = object["merged"] as? Bool == true ? .merged
            : object["state"] as? String == "closed" ? .closed : object["draft"] as? Bool == true ? .draft : .open
        return PullRequestDetails(title: title, state: state, commits: object["commits"] as? Int ?? 0,
                                  changedFiles: object["changed_files"] as? Int ?? 0, additions: object["additions"] as? Int ?? 0,
                                  deletions: object["deletions"] as? Int ?? 0, body: object["body"] as? String ?? "")
    }
    /// The start of the diff; enough to say what changed without downloading a huge one.
    static func diff(_ pr: GitHubPullRequest, session: URLSession = .shared) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request(pr, accept: "application/vnd.github.diff"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count >= diffLimit { break } }
        return String(decoding: data, as: UTF8.self)
    }
    private static func request(_ pr: GitHubPullRequest, accept: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(pr.owner)/\(pr.repo)/pulls/\(pr.number)")!)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Rise", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }
}

/// A short description of a pull request for its tab's hover card, from the find bar's model.
enum PullRequestSummarizer {
    static let systemPrompt = """
    You write the description in a browser's hover card for a GitHub pull request. The card already shows the title, status and diff size.

    Write one or two short sentences, at most 35 words, saying what the change does and why. Start directly with a verb, such as "Fixes", "Adds", "Removes" or "Speeds up". Never start with or mention "This PR", "This pull request", "This change" or "The author", and don't repeat the title, number, author or repository. Write plain text only: no Markdown, quotes, lists or line breaks.
    """
    static func messages(title: String, body: String, diff: String, page: String) -> [[String: Any]] {
        var context = "Title: \(title)\n"
        if !body.isEmpty { context += "\nDescription:\n\(body.prefix(4_000))\n" }
        if !diff.isEmpty { context += "\nDiff (may be cut off):\n\(diff.prefix(16_000))\n" }
        if !page.isEmpty { context += "\nPull request page:\n\(page.prefix(20_000))\n" }
        return [["role": "system", "content": systemPrompt], ["role": "user", "content": context]]
    }
    static func summarize(_ messages: [[String: Any]], session: URLSession = .shared) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: PageAssistant.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(PageAssistant.apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Rise", forHTTPHeaderField: "X-Title")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": PageAssistant.model, "stream": true,
                        "reasoning": ["effort": PageAssistant.reasoningEffort], "messages": messages])
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
                        if chunk?["error"] != nil { throw URLError(.badServerResponse) }
                        let delta = (chunk?["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
                        if let content = delta?["content"] as? String, !content.isEmpty { continuation.yield(content) }
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
    }
    private struct Saved: Codable { var summary: String?; var details: PullRequestDetails? }
    private(set) var entries: [String: Entry] = [:]
    private var saved: [String: Saved]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let storageURL: URL
    var onChange: ((String) -> Void)?

    init(storageURL: URL) {
        self.storageURL = storageURL
        let data = try? Data(contentsOf: storageURL)
        saved = data.flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) }
            // Earlier files kept only descriptions.
            ?? data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?.mapValues { Saved(summary: $0) } ?? [:]
    }
    func entry(for pr: GitHubPullRequest) -> Entry {
        if let entry = entries[pr.key] { return entry }
        let saved = saved[pr.key]
        return Entry(details: saved?.details, summary: saved?.summary ?? "", phase: saved?.summary == nil ? .idle : .done)
    }
    /// Fetches the details and, unless one is saved, writes the description. Keeps going
    /// when the card closes, so the description is ready next time.
    func load(_ pr: GitHubPullRequest, title: String, page: @escaping @MainActor () async -> String?) {
        guard tasks[pr.key] == nil, entries[pr.key].map({ $0.phase == .failed }) ?? true else { return }
        entries[pr.key] = entries[pr.key].map { Entry(details: $0.details) } ?? entry(for: pr)
        let key = pr.key
        tasks[key] = Task { [weak self] in
            let fetched = try? await GitHubAPI.details(pr)
            guard let self else { return }
            if let fetched {
                self.update(key) { $0.details = fetched }
                self.saved[key, default: Saved()].details = fetched; self.save()
            }
            let details = fetched ?? self.entries[key]?.details
            guard self.entries[key]?.phase != .done else { self.tasks[key] = nil; return }
            self.update(key) { $0.phase = .generating }
            let diff = details == nil ? "" : (try? await GitHubAPI.diff(pr)) ?? ""
            // Private repositories aren't in the public API; the open page can still describe them.
            let pageText = details == nil ? await page() ?? "" : ""
            var text = ""
            do {
                guard details != nil || !pageText.isEmpty else { throw URLError(.resourceUnavailable) }
                let messages = PullRequestSummarizer.messages(title: details?.title ?? title, body: details?.body ?? "", diff: diff, page: pageText)
                for try await chunk in PullRequestSummarizer.summarize(messages) {
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
    private func update(_ key: String, _ change: (inout Entry) -> Void) {
        var entry = entries[key] ?? Entry(); change(&entry); entries[key] = entry
        onChange?(key)
    }
    private func save() {
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: storageURL, options: .atomic)
    }
}
