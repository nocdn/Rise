import Foundation

/// Where Rise's model requests go: OpenRouter or OpenAI with an API key, or the signed-in
/// OpenCode service on this Mac, which runs the model through the user's own account.
enum AIProvider: String, CaseIterable {
    case openRouter
    #if os(macOS)
    case openCode
    #endif
    case openAI
    static let preferenceKey = "Rise.AIProvider"
    var title: String {
        switch self {
        case .openRouter: return "OpenRouter"
        #if os(macOS)
        case .openCode: return "OpenCode (Local)"
        #endif
        case .openAI: return "OpenAI"
        }
    }
    /// The model a provider uses until another is chosen, as that provider names it.
    var defaultModel: String { self == .openAI ? "gpt-6-luna" : PageAssistant.model }
    /// The reasoning efforts a provider takes, by value and title.
    var efforts: [(String, String)] {
        let common = [("none", "None"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high")]
        return self == .openAI ? common + [("max", "Max")] : common
    }
}

/// A provider with the model, reasoning effort and API key a request uses.
struct ModelChoice: Equatable {
    var provider: AIProvider
    var model: String
    var effort: String
    /// The user's own key; nil until they add one, and for OpenCode, which signs in on its own.
    var apiKey: String?

    static let openRouter = ModelChoice(provider: .openRouter, model: PageAssistant.model, effort: PageAssistant.reasoningEffort)
    #if os(macOS)
    /// OpenRouter with a real key, for checks that ask the real model: `RISE_OPENROUTER_KEY`, else the key
    /// saved in Rise's settings.
    static var liveOpenRouter: ModelChoice {
        var choice = openRouter
        choice.apiKey = ProcessInfo.processInfo.environment["RISE_OPENROUTER_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? AIKeys.keychainRead(.openRouter)
        return choice
    }
    #endif
    #if os(macOS)
    static let openCode = ModelChoice(provider: .openCode, model: PageAssistant.model, effort: PageAssistant.reasoningEffort)
    #endif
    /// The model's own name, without its maker: "gpt-6-luna".
    var modelName: String { model.split(separator: "/").last.map(String.init) ?? model }
}

enum ModelEvent: Equatable {
    /// The model started thinking or writing, before any answer text.
    case responded
    case text(String)
    /// Every input token, cached or not.
    case inputTokens(Int)
}

enum ModelService {
    /// Streams one chat-style request. The handler runs before the next event is read,
    /// so a slow handler holds the stream back instead of buffering it.
    @MainActor static func run(_ messages: [[String: Any]], provider: ModelChoice, session: URLSession = .shared,
                    handle: (ModelEvent) async throws -> Void) async throws {
        #if os(iOS)
        guard MobileAISettings.shared.enabled else {
            throw PageAssistant.Failure.service("AI features are disabled in App settings.")
        }
        guard let key = provider.apiKey, !key.isEmpty else {
            throw PageAssistant.Failure.service("Add an \(provider.provider.title) API key in App settings.")
        }
        // Every mobile AI path (Ask, Summarise and follow-ups) passes this gate before
        // a client can create a network request. Key entry alone is not consent.
        try await MobileAIConsent.shared.authorize(provider.provider)
        try Task.checkCancellation()
        switch provider.provider {
        case .openRouter:
            try await OpenRouterClient.run(messages, choice: provider, session: session) { event in
                try await deliver(event, provider: provider.provider, handle: handle)
            }
        case .openAI:
            try await OpenAIClient.run(messages, choice: provider, session: session) { event in
                try await deliver(event, provider: provider.provider, handle: handle)
            }
        }
        #else
        switch provider.provider {
        case .openRouter: try await OpenRouterClient.run(messages, choice: provider, session: session, handle: handle)
        case .openCode: try await OpenCodeClient.run(messages, session: session, handle: handle)
        case .openAI: try await OpenAIClient.run(messages, choice: provider, session: session, handle: handle)
        }
        #endif
    }

    #if os(iOS)
    @MainActor private static func deliver(_ event: ModelEvent, provider: AIProvider,
                                           handle: (ModelEvent) async throws -> Void) async throws {
        guard MobileAISettings.shared.enabled,
              MobileAISettings.shared.hasSharingConsent(for: provider) else { throw CancellationError() }
        try await handle(event)
    }
    #endif

    static func errorMessage(in data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }

    /// Reads a failed response's body for the service's own explanation.
    static func failure(_ bytes: URLSession.AsyncBytes, status: Int) async throws -> Error {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return PageAssistant.Failure.service(errorMessage(in: data) ?? "The model couldn’t answer (HTTP \(status)).")
    }
}

enum OpenRouterClient {
    #if os(iOS)
    static let missingKey = "Add an OpenRouter API key in App settings."
    #else
    static let missingKey = "Add an OpenRouter API key in Rise’s settings, under AI."
    #endif

    @MainActor static func run(_ messages: [[String: Any]], choice: ModelChoice, session: URLSession,
                    handle: (ModelEvent) async throws -> Void) async throws {
        var request = URLRequest(url: PageAssistant.endpoint)
        request.httpMethod = "POST"
        guard let key = choice.apiKey, !key.isEmpty else { throw PageAssistant.Failure.service(missingKey) }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Rise", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": choice.model, "stream": true,
            "reasoning": ["effort": choice.effort], "messages": messages])
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw try await ModelService.failure(bytes, status: http.statusCode)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            let data = Data(payload.utf8)
            if let message = ModelService.errorMessage(in: data) { throw PageAssistant.Failure.service(message) }
            let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Usage can arrive without a content delta, after the last answer token.
            if let count = (chunk?["usage"] as? [String: Any])?["prompt_tokens"] as? Int, count >= 0 {
                try await handle(.inputTokens(count))
            }
            guard let delta = (chunk?["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if !(delta["reasoning"] as? String ?? "").isEmpty || !(delta["reasoning_details"] as? [[String: Any]] ?? []).isEmpty {
                try await handle(.responded)
            }
            if let content = delta["content"] as? String, !content.isEmpty { try await handle(.text(content)) }
        }
    }
}

/// OpenAI's Responses API, which takes every reasoning effort its models offer.
enum OpenAIClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let missingKey = "Add an OpenAI API key in Rise’s settings, under AI."

    @MainActor static func run(_ messages: [[String: Any]], choice: ModelChoice, session: URLSession,
                    handle: (ModelEvent) async throws -> Void) async throws {
        guard let key = choice.apiKey, !key.isEmpty else { throw PageAssistant.Failure.service(missingKey) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": choice.model, "stream": true, "store": false,
            "reasoning": ["effort": choice.effort], "input": messages])
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw try await ModelService.failure(bytes, status: http.statusCode)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let response = event["response"] as? [String: Any]
            switch event["type"] as? String {
            case "response.output_item.added":
                if (event["item"] as? [String: Any])?["type"] as? String == "reasoning" { try await handle(.responded) }
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty { try await handle(.text(delta)) }
            case "response.completed":
                if let count = (response?["usage"] as? [String: Any])?["input_tokens"] as? Int, count >= 0 {
                    try await handle(.inputTokens(count))
                }
                return
            case "response.failed", "response.incomplete":
                let message = (response?["error"] as? [String: Any])?["message"] as? String
                throw PageAssistant.Failure.service(message ?? "The model stopped before the answer finished.")
            case "error":
                throw PageAssistant.Failure.service(event["message"] as? String ?? "The model couldn’t answer.")
            default: continue
            }
        }
    }
}

/// Talks to the OpenCode background service that the OpenCode apps and CLI share. Each
/// request is a short-lived session with every tool denied, so page text can't make the
/// model act on this Mac; the session is deleted once the answer ends.
#if os(macOS)
enum OpenCodeClient {
    struct Endpoint: Equatable {
        let url: URL
        let password: String
    }

    static let unavailable = "OpenCode isn’t running on this Mac. Open OpenCode, or run “opencode service start” in Terminal, then try again."

    /// Where the service records its address and password, readable only by this user.
    static var serviceFile: URL {
        let environment = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let state = environment.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return state.appendingPathComponent("opencode/service.json")
    }
    /// Replaced in tests.
    static var discover: () throws -> Endpoint = { try endpoint(from: Data(contentsOf: serviceFile)) }

    /// Only a loopback address gets the password.
    static func endpoint(from data: Data) throws -> Endpoint {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String, let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              let password = object["password"] as? String, !password.isEmpty else {
            throw PageAssistant.Failure.service(unavailable)
        }
        return Endpoint(url: url, password: password)
    }

    /// An empty folder of Rise's own, so no project's instructions or settings apply.
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rise/OpenCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The same model and effort as OpenRouter, through OpenCode's own provider.
    static var model: [String: Any] {
        let parts = PageAssistant.model.split(separator: "/", maxSplits: 1).map(String.init)
        return ["providerID": parts.first ?? "", "id": parts.last ?? "", "variant": PageAssistant.reasoningEffort]
    }

    /// A session takes one message, so the instructions and earlier turns go first.
    static func prompt(from messages: [[String: Any]]) -> String {
        var instructions: [String] = [], turns: [(role: String, text: String)] = []
        for message in messages {
            let role = message["role"] as? String ?? "user", text = message["content"] as? String ?? ""
            if role == "system" { instructions.append(text) } else { turns.append((role, text)) }
        }
        let last = turns.popLast()
        var parts = instructions
        if !turns.isEmpty {
            let history = turns.map { ($0.role == "assistant" ? "Assistant: " : "User: ") + $0.text }
            parts.append("<conversation>\n" + history.joined(separator: "\n\n") + "\n</conversation>")
        }
        if let last { parts.append(turns.isEmpty ? last.text : "User: " + last.text) }
        return parts.joined(separator: "\n\n")
    }

    static func run(_ messages: [[String: Any]], session: URLSession,
                    handle: (ModelEvent) async throws -> Void) async throws {
        let endpoint: Endpoint
        do { endpoint = try discover() } catch { throw PageAssistant.Failure.service(unavailable) }
        let created = try await json(endpoint, "POST", "api/session", session: session, body: [
            "title": "Rise", "location": ["directory": folder.path], "model": model,
            "permissions": [["action": "*", "resource": "*", "effect": "deny"]]])
        guard let id = (created?["data"] as? [String: Any])?["id"] as? String else {
            throw PageAssistant.Failure.service("OpenCode didn’t start a session.")
        }
        do {
            try await converse(id, prompt: prompt(from: messages), endpoint: endpoint, session: session, handle: handle)
            cleanUp(id, interrupt: false, endpoint: endpoint, session: session)
        } catch {
            cleanUp(id, interrupt: true, endpoint: endpoint, session: session)
            throw error
        }
    }

    private static func converse(_ id: String, prompt: String, endpoint: Endpoint, session: URLSession,
                                 handle: (ModelEvent) async throws -> Void) async throws {
        // The event stream only carries live events, so it must be open before the prompt goes in.
        var request = request(endpoint, "GET", "api/event")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PageAssistant.Failure.service(unavailable) }
        var lines = bytes.lines.makeAsyncIterator()
        while let line = try await lines.next() {
            if line.hasPrefix("data:"), line.contains("\"server.connected\"") { break }
        }
        try Task.checkCancellation()
        _ = try await json(endpoint, "POST", "api/session/\(id)/prompt", session: session, body: ["text": prompt])
        var events = OpenCodeEvents(sessionID: id)
        while let line = try await lines.next() {
            try Task.checkCancellation()
            let read = try events.read(line)
            for event in read.events { try await handle(event) }
            if read.finished { return }
        }
        throw PageAssistant.Failure.service("OpenCode stopped before the answer finished.")
    }

    /// Runs on its own, so the session goes away even when the answer was cancelled.
    private static func cleanUp(_ id: String, interrupt: Bool, endpoint: Endpoint, session: URLSession) {
        Task.detached {
            if interrupt { _ = try? await json(endpoint, "POST", "api/session/\(id)/interrupt", session: session, body: [:]) }
            _ = try? await json(endpoint, "DELETE", "api/session/\(id)", session: session)
        }
    }

    private static func request(_ endpoint: Endpoint, _ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.httpMethod = method
        let credentials = Data("opencode:\(endpoint.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private static func json(_ endpoint: Endpoint, _ method: String, _ path: String, session: URLSession,
                             body: [String: Any]? = nil) async throws -> [String: Any]? {
        var request = request(endpoint, method, path)
        request.timeoutInterval = 30
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            throw PageAssistant.Failure.service(unavailable)
        }
        let object = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw PageAssistant.Failure.service(object?["message"] as? String ?? "OpenCode couldn’t answer.")
        }
        return object
    }
}

/// Turns OpenCode's shared event stream into one session's model events.
struct OpenCodeEvents {
    let sessionID: String
    private var streamed: [String: String] = [:]
    init(sessionID: String) { self.sessionID = sessionID }

    mutating func read(_ line: String) throws -> (events: [ModelEvent], finished: Bool) {
        // The stream carries every session's events; skip other sessions without decoding them.
        guard line.hasPrefix("data:"), line.contains(sessionID),
              let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
              let type = event["type"] as? String, let data = event["data"] as? [String: Any],
              data["sessionID"] as? String == sessionID else { return ([], false) }
        let part = "\(data["assistantMessageID"] as? String ?? "")#\(data["ordinal"] as? Int ?? 0)"
        switch type {
        case "session.reasoning.started", "session.reasoning.delta", "session.text.started":
            return ([.responded], false)
        case "session.text.delta":
            let delta = data["delta"] as? String ?? ""
            streamed[part, default: ""] += delta
            return (delta.isEmpty ? [] : [.text(delta)], false)
        case "session.text.ended":
            // Text that only arrives in the final event still reaches the answer.
            let text = data["text"] as? String ?? "", shown = streamed[part] ?? ""
            streamed[part] = text
            guard text.count > shown.count, text.hasPrefix(shown) else { return ([], false) }
            return ([.text(String(text.dropFirst(shown.count)))], false)
        case "session.step.ended":
            guard let tokens = data["tokens"] as? [String: Any] else { return ([], false) }
            let cache = tokens["cache"] as? [String: Any]
            let total = [tokens["input"], cache?["read"], cache?["write"]].compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
            return ([.inputTokens(total)], false)
        case "session.execution.succeeded":
            return ([], true)
        case "session.execution.failed":
            let message = (data["error"] as? [String: Any])?["message"] as? String
            throw PageAssistant.Failure.service(message.map { "OpenCode couldn’t answer: \($0)" } ?? "OpenCode couldn’t answer.")
        case "session.execution.interrupted":
            throw CancellationError()
        default:
            return ([], false)
        }
    }
}

#endif
