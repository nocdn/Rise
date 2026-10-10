import XCTest
import Foundation
@testable import Rise

/// A stand-in OpenCode service: sessions, prompts, deletes and the shared event stream.
private final class OpenCodeProtocol: URLProtocol {
    static let lock = NSLock()
    static var events: [[String: Any]] = []
    static var requests: [(method: String, path: String, body: [String: Any]?, authorization: String?)] = []
    static func prepare(_ events: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        self.events = events; requests = []
    }
    static func recorded() -> [(method: String, path: String, body: [String: Any]?, authorization: String?)] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body: Data? = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            stream.close(); body = data
        }
        let method = request.httpMethod ?? "GET", path = request.url!.path
        Self.lock.lock()
        Self.requests.append((method, path, body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] },
                              request.value(forHTTPHeaderField: "Authorization")))
        let events = Self.events
        Self.lock.unlock()
        var status = 200, data = Data("{}".utf8), type = "application/json"
        switch (method, path) {
        case ("POST", "/api/session"): data = Data(#"{"data":{"id":"ses_rise"}}"#.utf8)
        case ("GET", "/api/event"):
            type = "text/event-stream"
            let lines = ([["type": "server.connected", "data": [:]]] + events).map {
                "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n"
            }
            data = Data(lines.joined().utf8)
        case ("DELETE", _): status = 204; data = Data()
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class OpenCodeProviderTests: XCTestCase {
    private var discover: (() throws -> OpenCodeClient.Endpoint)!
    override func setUp() {
        discover = OpenCodeClient.discover
        OpenCodeClient.discover = { OpenCodeClient.Endpoint(url: URL(string: "http://127.0.0.1:4096")!, password: "secret") }
    }
    override func tearDown() { OpenCodeClient.discover = discover }

    private func session(_ events: [[String: Any]]) -> URLSession {
        OpenCodeProtocol.prepare(events)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func event(_ type: String, _ data: [String: Any], session: String = "ses_rise") -> [String: Any] {
        ["type": type, "data": data.merging(["sessionID": session]) { $1 }]
    }
    private func waitForDelete() async throws {
        for _ in 0..<100 where !OpenCodeProtocol.recorded().contains(where: { $0.method == "DELETE" }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAnswersStreamThroughALockedDownSessionThatIsDeletedAfterwards() async throws {
        let part: [String: Any] = ["assistantMessageID": "msg_1", "ordinal": 0]
        let session = session([
            event("session.text.delta", part.merging(["delta": "Ignore me"]) { $1 }, session: "ses_other"),
            event("session.text.started", part),
            event("session.text.delta", part.merging(["delta": "{\"snippet\":\"March"]) { $1 }),
            event("session.text.delta", part.merging(["delta": " 3\"}\nIt ships "]) { $1 }),
            event("session.text.ended", part.merging(["text": "{\"snippet\":\"March 3\"}\nIt ships **March 3**."]) { $1 }),
            event("session.step.ended", ["tokens": ["input": 3, "output": 9, "cache": ["read": 100, "write": 2000]]]),
            event("session.execution.succeeded", [:]),
        ])
        defer { session.invalidateAndCancel() }
        var highlights: [String] = [], counts: [Int] = [], text = ""
        let history = [FindBar.Turn(question: "What is it?", answer: "A browser.")]
        let stream = PageAssistant.answer("When?", history: history, page: {
            PageAssistant.Page(title: "Release", url: "https://example.test", selection: "", text: "It ships March 3.")
        }, highlight: { highlights.append($0); return true }, inputTokens: { counts.append($0) }, provider: .openCode, session: session)
        for try await token in stream { text += token }

        XCTAssertEqual(text, "It ships **March 3**.", "Text only in the final event still reaches the answer; other sessions don't")
        XCTAssertEqual(highlights, ["March 3"])
        XCTAssertEqual(counts, [2103], "Count cached input too")
        try await waitForDelete()
        let requests = OpenCodeProtocol.recorded()
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" },
                       ["POST /api/session", "GET /api/event", "POST /api/session/ses_rise/prompt", "DELETE /api/session/ses_rise"])
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Basic " + Data("opencode:secret".utf8).base64EncodedString() })
        let created = try XCTUnwrap(requests[0].body)
        XCTAssertEqual(created["title"] as? String, "Rise", "A set title skips OpenCode's extra title request")
        XCTAssertEqual(created["permissions"] as? [[String: String]], [["action": "*", "resource": "*", "effect": "deny"]])
        XCTAssertEqual(created["model"] as? [String: String], ["providerID": "openai", "id": "gpt-6-luna", "variant": "low"])
        let prompt = try XCTUnwrap(requests[2].body?["text"] as? String)
        XCTAssertTrue(prompt.hasPrefix(PageAssistant.systemPrompt))
        XCTAssertTrue(prompt.contains("<page>\nIt ships March 3.\n</page>"))
        XCTAssertTrue(prompt.contains("<conversation>\nUser: What is it?\n\nAssistant: {\"snippet\":\"\"}\nA browser.\n</conversation>"))
        XCTAssertTrue(prompt.hasSuffix("\n\nUser: When?"))
    }

    func testAFailedAnswerShowsOpenCodesReasonAndStillCleansUp() async throws {
        let session = session([event("session.execution.failed", ["error": ["type": "provider.no-route", "message": "Model unavailable: openai/gpt-6-luna"]])])
        defer { session.invalidateAndCancel() }
        var message: String?
        do {
            for try await _ in PullRequestSummarizer.summarize([["role": "user", "content": "Describe"]], provider: .openCode, session: session) {}
        } catch { message = error.localizedDescription }
        XCTAssertEqual(message, "OpenCode couldn’t answer: Model unavailable: openai/gpt-6-luna")
        try await waitForDelete()
        XCTAssertEqual(OpenCodeProtocol.recorded().suffix(2).map { "\($0.method) \($0.path)" },
                       ["POST /api/session/ses_rise/interrupt", "DELETE /api/session/ses_rise"])
    }

    func testOnlyALoopbackServiceGetsThePassword() async throws {
        func data(_ url: String) -> Data { Data(#"{"url":"\#(url)","password":"secret"}"#.utf8) }
        XCTAssertEqual(try OpenCodeClient.endpoint(from: data("http://127.0.0.1:49374")).password, "secret")
        for url in ["http://example.com:49374", "https://127.0.0.1:49374", "http://127.0.0.1.example.com"] {
            XCTAssertThrowsError(try OpenCodeClient.endpoint(from: data(url)), url)
        }
        OpenCodeClient.discover = { throw CocoaError(.fileNoSuchFile) }
        let stream = PageAssistant.answer("When?", history: [], page: {
            PageAssistant.Page(title: "", url: "", selection: "", text: "")
        }, highlight: { _ in false }, provider: .openCode, session: session([]))
        var message: String?
        do { for try await _ in stream {} } catch { message = error.localizedDescription }
        XCTAssertEqual(message, OpenCodeClient.unavailable)
        XCTAssertTrue(OpenCodeProtocol.recorded().isEmpty)
    }

    func testTheAIProviderSettingDefaultsToOpenRouterAndNamesOpenCodeInTheFooter() throws {
        _ = NSApplication.shared
        let suite = "RiseTests.AIProvider.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        defer {
            browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder)
        }
        func checked() -> [String] {
            let item = browser.makeMoreSiteMenu().items.first { $0.title == "AI Provider" }
            return item?.submenu?.items.filter { $0.state == .on }.map(\.title) ?? []
        }
        XCTAssertEqual(browser.aiProvider, .openRouter)
        XCTAssertEqual(checked(), ["OpenRouter (Hardcoded)"])
        browser.selectAIProvider(.openCode)
        XCTAssertEqual(browser.aiProvider, .openCode)
        XCTAssertEqual(checked(), ["OpenCode"])
        XCTAssertEqual(FindBar.answeredBy(browser.aiProvider), "Answered by gpt-6-luna via OpenCode")
        XCTAssertEqual(browser.tabHoverCards.summaries.provider(), .openCode)
    }
}

/// Talks to the real OpenCode service on this Mac. Run with RISE_LIVE_OPENCODE=1.
@MainActor final class OpenCodeLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RISE_LIVE_OPENCODE"] == "1", "Set RISE_LIVE_OPENCODE=1")
    }
    private func sessionsInRiseFolder() async throws -> [String] {
        let endpoint = try OpenCodeClient.discover()
        var components = URLComponents(url: endpoint.url.appendingPathComponent("api/session"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "directory", value: OpenCodeClient.folder.path), URLQueryItem(name: "limit", value: "50")]
        var request = URLRequest(url: components.url!)
        request.setValue("Basic " + Data("opencode:\(endpoint.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let sessions = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return sessions.filter { ($0["location"] as? [String: Any])?["directory"] as? String == OpenCodeClient.folder.path }.compactMap { $0["id"] as? String }
    }
    private func waitUntilNoSessions() async throws {
        for _ in 0..<50 { if try await sessionsInRiseFolder().isEmpty { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTFail("Rise left OpenCode sessions behind")
    }

    func testThePageAssistantAnswersThroughOpenCode() async throws {
        var highlights: [String] = [], counts: [Int] = [], tokens: [String] = []
        let started = Date()
        let stream = PageAssistant.answer("When do beta testers get access?", history: [], page: {
            PageAssistant.Page(title: "Rise 2.0", url: "https://example.test", selection: "",
                               text: "Rise 2.0 brings Peek and split view. The public release is April 14, 2027. Beta testers get access on March 2, 2027.")
        }, highlight: { highlights.append($0); return true }, inputTokens: { counts.append($0) }, provider: .openCode)
        for try await token in stream { tokens.append(token) }
        print("OpenCode answer in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(tokens.joined()) · highlights \(highlights) · input \(counts)")
        XCTAssertEqual(tokens.first, "", "Thinking ends before the answer text")
        XCTAssertTrue(tokens.joined().contains("March 2"))
        XCTAssertFalse(tokens.joined().contains("snippet"), "The metadata header stays hidden")
        XCTAssertEqual(highlights.count, 1); XCTAssertTrue(highlights.first?.contains("March 2") == true)
        XCTAssertGreaterThan(counts.last ?? 0, 0)
        try await waitUntilNoSessions()
    }

    func testCancellingMidAnswerInterruptsAndDeletesTheSession() async throws {
        let messages: [[String: Any]] = [["role": "user", "content": "Write a 600 word story about a lighthouse keeper."]]
        let consumer = Task { () -> String in
            var text = ""
            for try await chunk in PullRequestSummarizer.summarize(messages, provider: .openCode) {
                text += chunk
                if text.count > 20 { break }
            }
            return text
        }
        let text = try await consumer.value
        XCTAssertGreaterThan(text.count, 20)
        try await waitUntilNoSessions()
    }
}
