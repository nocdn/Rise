#if DEBUG
import UIKit
import WebKit
import Network

/// Open Here against a local server: the link loads in this tab, it and its server redirect are
/// allowed without trying an app, the referrer is the web's default, and a later navigation, or
/// a tap during its load, is allowed as usual. Also checks where it sits in the menu.
@MainActor enum OpenHereAudit {
    static let argument = "-RiseOpenHereAudit"

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("OpenHereAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var checks: [String: Bool] = [:]
            func check(_ name: String, _ valid: Bool) { checks[name] = valid }
            do {
                let server = try OpenHereFixture(); try await server.start(); defer { server.stop() }
                browser.loadViewIfNeeded()
                let page = browser.webView
                let probe = OpenHereProbe(browser: browser)
                let delegate = page.navigationDelegate
                page.navigationDelegate = probe
                defer { page.navigationDelegate = delegate }

                // The menu: right under Open, with its icon, in Open's section; web links only.
                let open = UIAction(title: "Open", image: UIImage(systemName: "safari"), identifier: BrowserViewController.openLinkIdentifier) { _ in }
                let suggested: [UIMenuElement] = [open, UIAction(title: "Add to Reading List") { _ in },
                                                  UIAction(title: "Copy Link") { _ in }, UIAction(title: "Share…") { _ in }]
                let menu = browser.nativeLinkMenu(in: page, url: URL(string: "https://example.com/article")!, actions: suggested)
                let titles = menu.children.compactMap { ($0 as? UIAction)?.title }
                check("menu-puts-open-here-right-under-open", titles == ["Open", "Open Here", "Add to Reading List", "Copy Link", "Share…"])
                check("open-here-has-opens-icon", (menu.children[1] as? UIAction)?.image == open.image)
                let sectioned = browser.nativeLinkMenu(in: page, url: URL(string: "https://example.com/article")!,
                                                       actions: [UIMenu(options: .displayInline, children: suggested)])
                check("open-here-stays-in-opens-section", (sectioned.children.first as? UIMenu)?.children.prefix(2).compactMap { ($0 as? UIAction)?.title } == ["Open", "Open Here"])
                check("no-open-here-for-app-links", ["mailto:a@example.com", "tel:+441234567890"].allSatisfy { link in
                    !browser.nativeLinkMenu(in: page, url: URL(string: link)!, actions: suggested).children.contains { ($0 as? UIAction)?.title == "Open Here" }
                })

                page.load(URLRequest(url: server.url.appendingPathComponent("home")))
                try await probe.wait { page.url?.path == "/home" && !page.isLoading }
                let tabs = browser.tabs.count
                probe.policies.removeAll()

                browser.openHere(server.url.appendingPathComponent("start"), in: page)
                check("open-here-is-tracked-while-loading", browser.openingHere.object(forKey: page) != nil)
                try await probe.wait { page.url?.path == "/end" && !page.isLoading }
                check("load-and-redirect-reach-the-policy", probe.policies.map(\.path) == ["/start", "/end"])
                check("load-and-redirect-never-try-an-app", probe.policies.allSatisfy { $0.policy == BrowserViewController.allowWithoutAppLink })
                check("policy-is-webkits-allow-without-app-link", BrowserViewController.allowWithoutAppLink.rawValue == 3)
                check("open-here-ends-on-commit", browser.openingHere.object(forKey: page) == nil)
                check("opens-in-this-tab", browser.tabs.count == tabs && browser.webView === page)
                check("sends-the-default-referrer", server.referrer(for: "/start") == server.url.appendingPathComponent("home").absoluteString)
                check("back-returns-to-the-links-page", page.backForwardList.backItem?.url.path == "/home")

                probe.policies.removeAll()
                _ = try await page.evaluateJavaScript("location.href = '/home'; 0")
                try await probe.wait { page.url?.path == "/home" && !page.isLoading }
                check("later-navigation-is-allowed-as-usual", probe.policies.first?.policy == .allow)

                browser.openHere(server.url.appendingPathComponent("slow"), in: page)
                try await Task.sleep(for: .milliseconds(200))
                probe.policies.removeAll()
                _ = try await page.evaluateJavaScript("const a = document.createElement('a'); a.href = '/end'; document.body.append(a); a.click(); 0")
                try await probe.wait { page.url?.path == "/end" && !page.isLoading }
                check("a-tap-during-the-load-is-the-persons-own", probe.policies.first { $0.path == "/end" }?.policy == .allow)
                check("a-tap-during-the-load-ends-open-here", browser.openingHere.object(forKey: page) == nil)

            } catch { check("finished-without-timing-out", false) }
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("checks.json"))
            }
            let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
            try? (passed ? "Passed" : "Failed").write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// Forwards to the browser's own delegate, noting how each main-frame navigation was allowed.
@MainActor private final class OpenHereProbe: NSObject, WKNavigationDelegate {
    let browser: BrowserViewController
    var policies: [(path: String, policy: WKNavigationActionPolicy)] = []
    init(browser: BrowserViewController) { self.browser = browser }
    func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<500 { if ready() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NSError(domain: "Rise.OpenHereAudit.Timeout", code: 1)
    }
    func webView(_ page: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let path = action.request.url?.path ?? "", main = action.targetFrame?.isMainFrame == true
        browser.webView(page, decidePolicyFor: action) { [self] policy in
            if main { policies.append((path, policy)) }
            decisionHandler(policy)
        }
    }
    func webView(_ page: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        browser.webView(page, decidePolicyFor: response, decisionHandler: decisionHandler)
    }
    func webView(_ page: WKWebView, didCommit navigation: WKNavigation!) { browser.webView(page, didCommit: navigation) }
    func webView(_ page: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        browser.webView(page, didFail: navigation, withError: error)
    }
    func webView(_ page: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        browser.webView(page, didFailProvisionalNavigation: navigation, withError: error)
    }
}

/// `/start` redirects to `/end`; `/slow` answers after a while; every page is a little HTML.
private final class OpenHereFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.OpenHere.HTTP")
    private let lock = NSLock()
    private var referrers: [String: String] = [:]
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func referrer(for path: String) -> String? { lock.lock(); defer { lock.unlock() }; return referrers[path] }
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
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let route = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let referrer = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("referer:") }
                .map { String($0.dropFirst("referer:".count)).trimmingCharacters(in: .whitespaces) }
            lock.lock(); referrers[route] = referrer; lock.unlock()
            let response: String
            if route == "/start" {
                response = "HTTP/1.1 302 Found\r\nLocation: /end\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else if route == "/favicon.ico" {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                let body = "<html><head><title>\(route)</title></head><body>\(route)</body></html>"
                response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            }
            queue.asyncAfter(deadline: .now()+(route == "/slow" ? 3 : 0)) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
#endif
