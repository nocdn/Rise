#if DEBUG
import Foundation
import Network

/// Serves real HTTP requests on-device; no mocked resource-loading or benchmark-only rules.
final class AdBlockHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.AdBlock.HTTP")
    private let lock = NSLock()
    private var requests = 0
    private var fail = false
    var pageRequests: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var shouldFail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fail }
        set { lock.lock(); defer { lock.unlock() }; fail = newValue }
    }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
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
            if shouldFail { connection.cancel(); return }
            let body: String, type: String
            if route == "/" || route == "/replacement" { lock.lock(); requests += 1; lock.unlock(); body = Self.html(); type = "text/html" }
            else if route.hasPrefix("/preview/") && !route.hasSuffix(".png") {
                lock.lock(); requests += 1; lock.unlock()
                let colour = route.contains("red") ? "#dc3545" : "#1676de"
                body = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><link rel='icon' href='/preview/icon.png'><title>Preview article</title></head><body style='margin:0;background:\(colour);color:white;font:24px sans-serif'><h1>Background article</h1><p>This page was rendered without selecting its tab.</p></body></html>"
                type = "text/html"
            }
            else if route == "/preview/icon.png" { body = ""; type = "image/png" }
            else { body = route.contains("prepare/ads") ? "window.adLoaded=true;" : "window.normalLoaded=true;"; type = "application/javascript" }
            let bytes = route == "/preview/icon.png"
                ? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNQmHAXK2IYWhIAmMJjQXFQF3IAAAAASUVORK5CYII=")!
                : Data(body.utf8)
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
            // A short delay keeps the native spinner observable during a real reload.
            queue.asyncAfter(deadline: .now()+0.15) {
                connection.send(content: headers+bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

#endif
