#if DEBUG
import Foundation
import Network

/// Actual HTTP forms and React-like controls, backed by server state rather than DOM mocks.
final class GitHubStarHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.GitHubStar.HTTP")
    private let lock = NSLock()
    private var starred: Set<String> = ["already"]
    private var posts: [String: Int] = [:]
    private var actions: [String: Int] = [:]
    private var readDelays: [String: Double] = [:]
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func postCount(_ name: String) -> Int { lock.withLock { posts[name, default: 0] } }
    func isStarred(_ name: String) -> Bool { lock.withLock { starred.contains(name) } }
    func setStarred(_ name: String,_ value: Bool) { lock.withLock { if value { starred.insert(name) } else { starred.remove(name) } } }
    func postCount(_ name: String,starred: Bool) -> Int { lock.withLock { actions[name+"/"+(starred ? "star" : "unstar"),default: 0] } }
    func setReadDelay(_ name: String,_ seconds: Double) { lock.withLock { readDelays[name] = seconds } }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: queue); receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            let bytes = accumulated+(data ?? Data())
            guard bytes.count < 131072 else { connection.cancel(); return }
            guard let split = bytes.range(of: Data("\r\n\r\n".utf8)),
                  let header = String(data: bytes[..<split.lowerBound], encoding: .utf8) else {
                if complete { connection.cancel() } else { receive(connection, accumulated: bytes) }; return
            }
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= split.upperBound+length else { receive(connection, accumulated: bytes); return }
            respond(connection, header: header)
        }
    }
    private func respond(_ connection: NWConnection, header: String) {
        let request = header.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = request.first.map(String.init) ?? "GET"
        let path = request.dropFirst().first.map(String.init) ?? "/"
        let parts = path.split(separator: "/"); let name = parts.count > 1 ? String(parts[1]) : ""
        let authenticated = header.lowercased().contains("fixture_session=allowed")
        if name == "hang" { queue.asyncAfter(deadline: .now()+4) { connection.cancel() }; return }
        if name == "redirect" { send(connection, body: "", status: "302 Found", extra: "Location: https://example.com/\r\n"); return }
        if name == "server-error" { send(connection, body: "Unavailable", status: "503 Unavailable"); return }
        if name == "missing" { send(connection, body: "<title>Page not found · GitHub</title>", status: "404 Not Found"); return }
        if method == "POST" {
            let desired = !path.hasSuffix("/unstar")
            lock.withLock { posts[name, default: 0] += 1; actions[name+"/"+(desired ? "star" : "unstar"),default: 0] += 1 }
            guard authenticated, !name.hasPrefix("reject") else {
                send(connection, body: "Denied", status: "403 Forbidden"); return
            }
            if name == "delayed" {
                queue.asyncAfter(deadline: .now()+0.7) { [self] in
                    setStarred(name,desired)
                    send(connection, body: "{}", type: "application/json")
                }; return
            }
            setStarred(name,desired)
            if name == "form" { send(connection, body: "", status: "303 See Other", extra: "Location: /owner/form\r\n") }
            else { send(connection, body: "{}", type: "application/json") }
            return
        }
        let on = isStarred(name)
        let auth = authenticated && name != "expired" ? "<meta name='user-login' content='fixture-user'>" : ""
        let star = on ? "Unstar" : "Star", action = on ? "unstar" : "star"
        let control: String
        if name == "form" {
            control = "<form method='post' action='/owner/\(name)/\(action)'><input type='hidden' name='authenticity_token' value='fixture-csrf'><button>\(star)</button></form>"
        } else {
            let delay = name == "hydration" ? 400 : 0
            let scope = name == "labelled" ? "" : "id='repository-details-container'"
            let suffix = name == "labelled" ? "owner/labelled" : "this repository"
            control = """
            <div \(scope)><button id="star" data-starred="\(on)" \(name == "disabled" ? "disabled" : "") aria-label="\(star) \(suffix)">\(star)</button></div>
            <script>setTimeout(()=>{const button=document.querySelector('#star');button.__reactPropsFixture={};button.onclick=()=>{
              const desired=button.dataset.starred!=='true';
              const render=on=>{button.dataset.starred=String(on);button.textContent=on?'Unstar':'Star';button.setAttribute('aria-label',(on?'Unstar':'Star')+' \(suffix)')};
              render(desired);
              fetch('/owner/\(name)/'+(desired?'star':'unstar'),{method:'POST',headers:{'X-CSRF-Token':'fixture-csrf'}}).then(r=>{if(!r.ok)render(!desired)})
            }},\(delay))</script>
            """
        }
        let distractor = "<form action='/other/recommended/unstar'><button>Unstar</button></form><button aria-label='Unstar other/recommended'>Unstar</button><button style='display:none' aria-label='Unstar this repository'>Unstar</button>"
        let markup = "<!doctype html><title>owner/\(name)</title>\(auth)<body>\(name == "no-control" ? "" : control)\(distractor)</body>"
        let delay = lock.withLock { readDelays[name,default: 0] }
        if delay > 0 { queue.asyncAfter(deadline: .now()+delay) { [self] in send(connection,body: markup) } }
        else { send(connection, body: markup) }
    }
    private func send(_ connection: NWConnection, body: String, status: String = "200 OK", type: String = "text/html", extra: String = "") {
        let bytes = Data(body.utf8)
        let header = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n".utf8)
        connection.send(content: header+bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
