#if DEBUG
import Foundation
import Network

/// Serves real HTTP requests on-device; no mocked resource-loading or benchmark-only rules.
final class AdBlockHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.AdBlock.HTTP")
    private let lock = NSLock()
    private var requests = 0
    private var paths: [String: Int] = [:]
    func requestCount(for path: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths[path, default: 0] }
    private var fail = false
    private let slowIcons: Bool
    private let missingRootIcon: Bool
    var pageRequests: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var shouldFail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); defer { lock.unlock() }; fail = newValue }
    }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    init(slowIcons: Bool = false, missingRootIcon: Bool = false) throws {
        self.slowIcons = slowIcons
        self.missingRootIcon = missingRootIcon
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): self?.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    static func html(scriptBase: String = "/") -> String {
        """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body><main>Normal article</main><div id="ad-slot-1" class="ad-banner">Advertising</div>
        <script src="\(scriptBase)normal.js"></script><script src="\(scriptBase)prepare/ads"></script></body></html>
        """
    }
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let route = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            lock.lock(); paths[route, default: 0] += 1; let attempt = paths[route]!; lock.unlock()
            if shouldFail { connection.cancel(); return }
            if (slowIcons || missingRootIcon), route == "/favicon.ico" {
                let missing = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: missing, completion: .contentProcessed { _ in connection.cancel() }); return
            }
            if route == "/preview/retry", attempt == 1 {
                let unavailable = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: unavailable, completion: .contentProcessed { _ in connection.cancel() }); return
            }
            if route == "/favicon-audit/protected.svg", !request.contains("rise-icon=allowed") {
                let denied = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: denied, completion: .contentProcessed { _ in connection.cancel() }); return
            }
            let body: String, type: String
            if route == "/favicon-audit/page" {
                body = "<html><head><title>Declared artwork</title></head><body><script>document.cookie='rise-icon=allowed; path=/'</script>Article</body></html>"
                type = "text/html"
            }
            else if route == "/favicon-audit/protected.svg" {
                body = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='#ee3322'/></svg>"
                type = "image/svg+xml"
            }
            else if route == "/" || route == "/replacement" { lock.lock(); requests += 1; lock.unlock(); body = Self.html(); type = "text/html" }
            else if route == "/preview/slow.js" { body = "window.slowResourceFinished=true"; type = "application/javascript" }
            else if route.hasPrefix("/preview/") && !route.hasSuffix(".png") {
                lock.lock(); requests += 1; lock.unlock()
                let colour = route.contains("red") ? "#dc3545" : "#1676de"
                if route == "/preview/delayed" {
                    body = "<meta name='viewport' content='width=device-width'><link rel='icon' href='/preview/icon.png'><body style='margin:0'><script>setTimeout(()=>{document.body.style.cssText='margin:0;background:#1676de;color:white;font:24px sans-serif';document.body.innerHTML='<h1>Delayed article</h1><p>Client rendering is ready.</p>'},3500)</script>"
                } else {
                    let slow = route == "/preview/slow" ? "<script async src='/preview/slow.js'></script>" : ""
                    body = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><link rel='icon' href='/preview/icon.png'><title>Preview article</title></head><body style='margin:0;background:\(colour);color:white;font:24px sans-serif'><h1>Background article</h1><p>This page was rendered without selecting its tab.</p>\(slow)</body></html>"
                }
                type = "text/html"
            }
            else if route == "/preview/icon.png" || route == "/favicon.ico" { body = ""; type = "image/png" }
            else { body = route.contains("prepare/ads") ? "window.adLoaded=true;" : "window.normalLoaded=true;"; type = "application/javascript" }
            let bytes = route == "/preview/icon.png" || route == "/favicon.ico"
                ? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNQmHAXK2IYWhIAmMJjQXFQF3IAAAAASUVORK5CYII=")!
                : Data(body.utf8)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
            // A short delay keeps the native spinner observable during a real reload.
            let delay = route == "/preview/precommit" ? 3.0
                : route == "/preview/slow.js" || (slowIcons && route == "/preview/icon.png") ? 12.0 : 0.15
            queue.asyncAfter(deadline: .now()+delay) {
                connection.send(content: headers+bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

#endif
