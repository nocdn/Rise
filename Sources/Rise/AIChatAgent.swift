import AppKit

/// One tool the model called, with what it passed, as JSON.
struct AIChatToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String
    /// The arguments read, `{}` for none; nil when they aren't a JSON object.
    var parsed: [String: Any]? {
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

/// Something the assistant did on the way to its answer, shown under the question: a line saying
/// what, beside the page's favicon or a symbol, and where a click on it goes.
struct AIChatStep: Equatable, @unchecked Sendable {
    enum State: Equatable { case running, done, failed }
    enum Target: Equatable { case tab(UUID), url(URL) }
    /// What it's doing, "Searching the web for “otters”", until it's done.
    var text: String
    var symbol = "sparkle"
    var favicon: NSImage?
    var state = State.running
    var target: Target?
    /// An email or event the step made, shown in the answer as a card (`AIChatCard.swift`).
    var draft: AIChatDraft?
    /// Shown done: what it did, "Searched the web for “otters”".
    func done(_ text: String? = nil) -> AIChatStep {
        var step = self; step.state = .done; if let text { step.text = text }; return step
    }
    func failed(_ text: String? = nil) -> AIChatStep {
        var step = self; step.state = .failed; if let text { step.text = text }; return step
    }
}

/// A tool the chat's model can call: what it's for and takes, as the model reads it, the step it
/// shows, and the work itself.
struct AIChatTool {
    let name: String
    let description: String
    /// A JSON Schema object.
    let parameters: [String: Any]
    /// Reads without changing anything, so it can run alongside the reply's other calls.
    var readsOnly = true
    /// The step shown while it runs.
    let step: @MainActor (_ arguments: [String: Any]) -> AIChatStep
    let run: @MainActor (_ arguments: [String: Any], _ step: AIChatStep) async throws -> AIChatToolResult

    /// Its definition for Chat Completions and for the Responses API.
    var chatDefinition: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
    var responsesDefinition: [String: Any] {
        ["type": "function", "name": name, "description": description, "parameters": parameters, "strict": false]
    }
}

/// What a tool gives back: text for the model, any pictures for it to look at, and the step as it ends.
struct AIChatToolResult {
    var output: String
    var step: AIChatStep?
    var images: [AIChatImage] = []
}

/// A picture for the model, as a page's screenshot: a JPEG, and what it's of.
struct AIChatImage: Equatable, Sendable {
    let jpeg: Data
    let caption: String
    var dataURL: String { "data:image/jpeg;base64,\(jpeg.base64EncodedString())" }
    /// Said in its place where the model can't take pictures.
    static let refused = "[The screenshot couldn't be shown: this model doesn't take images. Read the page's text instead.]"
    /// Whether a model's error is its refusing a picture.
    static func isRefusal(_ error: Error) -> Bool {
        let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).lowercased()
        return message.contains("image")
    }
}

/// A tool that couldn't do what it was asked: why, for the model, and the step as it shows it.
struct AIChatToolFailure: Error {
    let message: String
    var step: String?
}

/// What the chat shows as the agent goes.
enum AIChatAgentEvent: Equatable {
    /// Waiting on the model again, now with the tools' results.
    case thinking
    /// The model's first words or first tool in this round.
    case responded
    case text(String)
    /// A step started or changed, by its call's id.
    case step(String, AIChatStep)
}

/// One reply: its words and the tools it called, in order.
struct AIChatReply: Equatable {
    var text = ""
    var calls: [AIChatToolCall] = []
}

/// What streams from the model during one reply.
enum AIChatModelDelta: Equatable {
    /// Its first output: words, or a tool it's calling.
    case responded
    case text(String)
}

/// A model the agent talks to, keeping the conversation in its own API's terms.
@MainActor protocol AIChatModel: AnyObject {
    var supportsTools: Bool { get }
    /// Streams one reply to the conversation so far, offered `tools` (callable unless `mayCall` is
    /// false), and adds it to the conversation.
    func reply(tools: [AIChatTool], mayCall: Bool, handle: (AIChatModelDelta) async throws -> Void) async throws -> AIChatReply
    /// The results of the last reply's calls, in its order.
    func append(results: [(call: AIChatToolCall, output: String)])
    /// Pictures the calls took, for the model to look at next, after their results.
    func append(images: [AIChatImage])
}
extension AIChatModel {
    func append(images: [AIChatImage]) {}
}

/// The chat's agent: it asks the model, runs the tools it calls, and gives it their results, round
/// after round, until it answers without calling any. As Pi's agent loop does, calls from one
/// reply run together when they only read, and in order when any of them changes something. After
/// `maximumRounds` it's asked to answer with what it has.
@MainActor enum AIChatAgent {
    nonisolated static let maximumRounds = 50
    /// The most a tool gives the model at once.
    static let outputLimit = 60_000

    static func run(_ model: AIChatModel, tools: [AIChatTool], maximumRounds: Int = maximumRounds,
                    handle: (AIChatAgentEvent) async throws -> Void) async throws {
        let tools = model.supportsTools ? tools : []
        var round = 0
        while true {
            try Task.checkCancellation()
            if round > 0 { try await handle(.thinking) }
            let mayCall = !tools.isEmpty && round < maximumRounds
            var responded = false
            let reply = try await model.reply(tools: tools, mayCall: mayCall) { delta in
                if !responded { responded = true; try await handle(.responded) }
                if case .text(let text) = delta, !text.isEmpty { try await handle(.text(text)) }
            }
            if !responded { try await handle(.responded) }
            guard mayCall, !reply.calls.isEmpty else { return }
            let results = try await perform(reply.calls, tools: tools, handle: handle)
            try Task.checkCancellation()
            model.append(results: results.map { ($0.call, $0.output) })
            let images = results.flatMap(\.images)
            if !images.isEmpty { model.append(images: images) }
            round += 1
        }
    }

    /// Runs one reply's calls, every step shown first, and gives each output in the calls' order.
    static func perform(_ calls: [AIChatToolCall], tools: [AIChatTool],
                        handle: (AIChatAgentEvent) async throws -> Void) async throws -> [(call: AIChatToolCall, output: String, images: [AIChatImage])] {
        struct Job { let call: AIChatToolCall; let tool: AIChatTool?; let arguments: [String: Any]?; let step: AIChatStep }
        var jobs: [Job] = []
        for call in calls {
            let tool = tools.first { $0.name == call.name }, arguments = call.parsed
            let step = tool.map { $0.step(arguments ?? [:]) } ?? AIChatStep(text: "Using \(call.name)", symbol: "wrench.and.screwdriver")
            jobs.append(Job(call: call, tool: tool, arguments: arguments, step: step))
            try await handle(.step(call.id, step))
        }
        var outcomes = [(output: String, step: AIChatStep, images: [AIChatImage])?](repeating: nil, count: jobs.count)
        if jobs.allSatisfy({ $0.tool?.readsOnly ?? true }) {
            await withTaskGroup(of: (Int, String, AIChatStep, [AIChatImage]).self) { group in
                for (index, job) in jobs.enumerated() {
                    group.addTask { @MainActor in
                        let (output, step, images) = await attempt(job.call, tool: job.tool, arguments: job.arguments, step: job.step)
                        return (index, output, step, images)
                    }
                }
                for await (index, output, step, images) in group {
                    outcomes[index] = (output, step, images)
                    try? await handle(.step(jobs[index].call.id, step))
                }
            }
        } else {
            for (index, job) in jobs.enumerated() {
                try Task.checkCancellation()
                let (output, step, images) = await attempt(job.call, tool: job.tool, arguments: job.arguments, step: job.step)
                outcomes[index] = (output, step, images)
                try await handle(.step(job.call.id, step))
            }
        }
        try Task.checkCancellation()
        return zip(jobs, outcomes).map { job, outcome in (job.call, outcome?.output ?? "Error: the tool didn't finish.", outcome?.images ?? []) }
    }

    /// One call, its failures told to the model rather than ending the answer.
    private static func attempt(_ call: AIChatToolCall, tool: AIChatTool?, arguments: [String: Any]?, step: AIChatStep) async -> (String, AIChatStep, [AIChatImage]) {
        guard let tool else {
            return ("Error: there's no tool called \(call.name). The tools are the ones listed.", step.failed(), [])
        }
        guard let arguments else {
            return ("Error: the arguments weren't a JSON object: \(call.arguments.prefix(200))", step.failed(), [])
        }
        do {
            let result = try await tool.run(arguments, step)
            return (limited(result.output), result.step ?? step.done(), result.images)
        } catch let failure as AIChatToolFailure {
            return ("Error: \(failure.message)", step.failed(failure.step), [])
        } catch is CancellationError {
            return ("Error: stopped.", step.failed(), [])
        } catch {
            return ("Error: \(error.localizedDescription)", step.failed(), [])
        }
    }
    static func limited(_ output: String) -> String {
        guard output.count > outputLimit else { return output }
        return String(output.prefix(outputLimit))+"\n[Cut short at \(outputLimit) characters.]"
    }
}

// MARK: Models

/// The model for a provider: OpenRouter through Chat Completions, OpenAI through its Responses API,
/// both with tools; OpenCode answers without them, its session denying every tool.
@MainActor enum AIChatModels {
    static func model(for choice: ModelChoice, messages: [[String: Any]], session: URLSession = .shared) -> AIChatModel {
        switch choice.provider {
        case .openRouter:
            return AIChatCompletionsModel(endpoint: PageAssistant.endpoint, key: choice.apiKey,
                                          model: choice.model, effort: choice.effort, messages: messages, session: session)
        case .openAI:
            return AIChatResponsesModel(key: choice.apiKey, model: choice.model, effort: choice.effort, input: messages, session: session)
        case .openCode:
            return AIChatPlainModel(choice: choice, messages: messages, session: session)
        }
    }

    /// Whether the provider's model gets the browser's tools: OpenCode's session denies them all.
    static func hasTools(_ choice: ModelChoice) -> Bool { choice.provider != .openCode }

    /// The `data:` payloads of a server-sent event stream, skipping its comments, to `[DONE]`.
    static func events(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    static func post(_ url: URL, key: String, body: [String: Any], session: URLSession) async throws -> URLSession.AsyncBytes {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Rise", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw try await ModelService.failure(bytes, status: http.statusCode,
                                                    provider: url.host?.hasSuffix("openai.com") == true ? .openAI : .openRouter)
        }
        return bytes
    }
}

/// Chat Completions, as OpenRouter serves it. A reply's reasoning comes back as
/// `reasoning_details`, encrypted for OpenAI's models, and goes back with it unchanged so the model
/// keeps its train of thought across the tools' results.
@MainActor final class AIChatCompletionsModel: AIChatModel {
    let endpoint: URL, key: String?, model: String, effort: String, session: URLSession
    private(set) var messages: [[String: Any]]
    var supportsTools: Bool { true }
    init(endpoint: URL, key: String?, model: String, effort: String, messages: [[String: Any]], session: URLSession) {
        self.endpoint = endpoint; self.key = key; self.model = model; self.effort = effort; self.messages = messages; self.session = session
    }

    func reply(tools: [AIChatTool], mayCall: Bool, handle: (AIChatModelDelta) async throws -> Void) async throws -> AIChatReply {
        guard let key, !key.isEmpty else { throw PageAssistant.Failure.service(OpenRouterClient.missingKey) }
        var body: [String: Any] = ["model": model, "stream": true, "reasoning": ["effort": effort], "messages": messages]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.chatDefinition)
            body["tool_choice"] = mayCall ? "auto" : "none"
            body["parallel_tool_calls"] = true
        }
        let bytes: URLSession.AsyncBytes
        do { bytes = try await AIChatModels.post(endpoint, key: key, body: body, session: session) }
        catch where hasImages && AIChatImage.isRefusal(error) {
            // A model that doesn't take pictures: they're taken out, and it's told, and asked again.
            dropImages(); body["messages"] = messages
            bytes = try await AIChatModels.post(endpoint, key: key, body: body, session: session)
        }
        var text = "", calls: [Int: (id: String, name: String, arguments: String)] = [:], details: [[String: Any]] = []
        for try await event in AIChatModels.events(bytes) {
            try Task.checkCancellation()
            if let message = (event["error"] as? [String: Any])?["message"] as? String { throw PageAssistant.Failure.service(message) }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let parts = delta["reasoning_details"] as? [[String: Any]] { Self.merge(parts, into: &details) }
            if let content = delta["content"] as? String, !content.isEmpty { text += content; try await handle(.text(content)) }
            for part in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = part["index"] as? Int ?? calls.count
                var call = calls[index] ?? ("", "", "")
                if call.name.isEmpty && call.id.isEmpty { try await handle(.responded) }
                if let id = part["id"] as? String, !id.isEmpty { call.id = id }
                let function = part["function"] as? [String: Any]
                call.name += function?["name"] as? String ?? ""
                call.arguments += function?["arguments"] as? String ?? ""
                calls[index] = call
            }
            if choice["finish_reason"] as? String == "error" { throw PageAssistant.Failure.service("The model stopped with an error.") }
        }
        let ordered = calls.keys.sorted().compactMap { index -> AIChatToolCall? in
            guard let call = calls[index], !call.name.isEmpty else { return nil }
            return AIChatToolCall(id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name, arguments: call.arguments)
        }
        var assistant: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
        if !ordered.isEmpty {
            assistant["tool_calls"] = ordered.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]] }
        }
        if !details.isEmpty { assistant["reasoning_details"] = details }
        messages.append(assistant)
        return AIChatReply(text: text, calls: ordered)
    }
    func append(results: [(call: AIChatToolCall, output: String)]) {
        for (call, output) in results { messages.append(["role": "tool", "tool_call_id": call.id, "content": output]) }
    }
    /// Tools' results take text alone, so pictures come after them as the user's.
    func append(images: [AIChatImage]) {
        var content: [[String: Any]] = []
        for image in images {
            content.append(["type": "text", "text": image.caption])
            content.append(["type": "image_url", "image_url": ["url": image.dataURL]])
        }
        messages.append(["role": "user", "content": content])
        hasImages = true
    }
    private var hasImages = false
    private func dropImages() {
        messages = messages.map { message in
            guard let parts = message["content"] as? [[String: Any]] else { return message }
            var message = message
            message["content"] = parts.map { $0["type"] as? String == "image_url" ? ["type": "text", "text": AIChatImage.refused] : $0 }
            return message
        }
        hasImages = false
    }

    /// Streamed reasoning arrives a piece at a time: pieces of one detail share its type and index,
    /// and their text, summary or encrypted data join up; the rest is the latest given.
    static func merge(_ parts: [[String: Any]], into details: inout [[String: Any]]) {
        for part in parts {
            if var last = details.last, last["type"] as? String == part["type"] as? String,
               (last["index"] as? Int) == (part["index"] as? Int) {
                for key in ["text", "summary", "data"] {
                    if let piece = part[key] as? String { last[key] = (last[key] as? String ?? "")+piece }
                }
                for (key, value) in part where !["text", "summary", "data"].contains(key) && !(value is NSNull) { last[key] = value }
                details[details.count-1] = last
            } else {
                details.append(part)
            }
        }
    }
}

/// OpenAI's Responses API, stateless (`store: false`): each reply's output items, its encrypted
/// reasoning among them, go back in as they came, with each call's output after it.
@MainActor final class AIChatResponsesModel: AIChatModel {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    let key: String?, model: String, effort: String, session: URLSession
    private(set) var input: [[String: Any]]
    var supportsTools: Bool { true }
    init(key: String?, model: String, effort: String, input: [[String: Any]], session: URLSession) {
        self.key = key; self.model = model; self.effort = effort; self.input = input; self.session = session
    }

    func reply(tools: [AIChatTool], mayCall: Bool, handle: (AIChatModelDelta) async throws -> Void) async throws -> AIChatReply {
        guard let key, !key.isEmpty else { throw PageAssistant.Failure.service(OpenAIClient.missingKey) }
        var body: [String: Any] = ["model": model, "stream": true, "store": false, "reasoning": ["effort": effort],
                                   "include": ["reasoning.encrypted_content"], "input": input]
        if !tools.isEmpty {
            body["tools"] = tools.map(\.responsesDefinition)
            body["tool_choice"] = mayCall ? "auto" : "none"
            body["parallel_tool_calls"] = true
        }
        let bytes: URLSession.AsyncBytes
        do { bytes = try await AIChatModels.post(Self.endpoint, key: key, body: body, session: session) }
        catch where hasImages && AIChatImage.isRefusal(error) {
            dropImages(); body["input"] = input
            bytes = try await AIChatModels.post(Self.endpoint, key: key, body: body, session: session)
        }
        var text = "", output: [[String: Any]]?
        for try await event in AIChatModels.events(bytes) {
            try Task.checkCancellation()
            let response = event["response"] as? [String: Any]
            switch event["type"] as? String {
            case "response.output_item.added":
                if (event["item"] as? [String: Any])?["type"] as? String == "function_call" { try await handle(.responded) }
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty { text += delta; try await handle(.text(delta)) }
            case "response.completed":
                output = response?["output"] as? [[String: Any]] ?? []
            case "response.failed", "response.incomplete":
                let message = (response?["error"] as? [String: Any])?["message"] as? String
                throw PageAssistant.Failure.service(message ?? "The model stopped before the answer finished.")
            case "error":
                throw PageAssistant.Failure.service(event["message"] as? String ?? "The model couldn’t answer.")
            default: continue
            }
            if output != nil { break }
        }
        guard let output else { throw PageAssistant.Failure.service("The model stopped before the answer finished.") }
        input += output
        let calls = output.compactMap { item -> AIChatToolCall? in
            guard item["type"] as? String == "function_call", let id = item["call_id"] as? String, let name = item["name"] as? String else { return nil }
            return AIChatToolCall(id: id, name: name, arguments: item["arguments"] as? String ?? "")
        }
        return AIChatReply(text: text, calls: calls)
    }
    func append(results: [(call: AIChatToolCall, output: String)]) {
        for (call, output) in results { input.append(["type": "function_call_output", "call_id": call.id, "output": output]) }
    }
    func append(images: [AIChatImage]) {
        var content: [[String: Any]] = []
        for image in images {
            content.append(["type": "input_text", "text": image.caption])
            content.append(["type": "input_image", "image_url": image.dataURL, "detail": "auto"])
        }
        input.append(["role": "user", "content": content])
        hasImages = true
    }
    private var hasImages = false
    private func dropImages() {
        input = input.map { item in
            guard let parts = item["content"] as? [[String: Any]] else { return item }
            var item = item
            item["content"] = parts.map { $0["type"] as? String == "input_image" ? ["type": "input_text", "text": AIChatImage.refused] : $0 }
            return item
        }
        hasImages = false
    }
}

/// A provider without tools: one reply, streamed as it was before the chat had any.
@MainActor final class AIChatPlainModel: AIChatModel {
    let choice: ModelChoice, messages: [[String: Any]], session: URLSession
    var supportsTools: Bool { false }
    init(choice: ModelChoice, messages: [[String: Any]], session: URLSession) { self.choice = choice; self.messages = messages; self.session = session }
    func reply(tools: [AIChatTool], mayCall: Bool, handle: (AIChatModelDelta) async throws -> Void) async throws -> AIChatReply {
        var text = ""
        try await ModelService.run(messages, provider: choice, session: session) { event in
            if case .text(let piece) = event, !piece.isEmpty { text += piece; try await handle(.text(piece)) }
        }
        return AIChatReply(text: text)
    }
    func append(results: [(call: AIChatToolCall, output: String)]) {}
}
