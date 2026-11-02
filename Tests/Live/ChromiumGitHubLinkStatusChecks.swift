// python3 scripts/test-chromium-live.py Tests/Live/ChromiumGitHubLinkStatusChecks.swift
import AppKit
import RiseCore
import RiseChromium
@testable import Rise

@main @MainActor struct GitHubLinkStatusMain {
    static func main() {
        DispatchQueue.main.asyncAfter(deadline: .now()+45) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { exit(1) }
        let run = GitHubLinkStatusRun(); app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}
@MainActor final class GitHubLinkStatusRun: NSObject, NSApplicationDelegate {
    var failures = 0
    func check(_ ok: Bool, _ message: String) { print(ok ? "PASS" : "FAIL", message); if !ok { failures += 1 } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
            let page = ChromiumPage()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(page.view); page.view.frame = window.contentView!.bounds
            window.makeKeyAndOrderFront(nil)
            let file = folder.appendingPathComponent("github-status.html")
            try! "<title>GitHub status fixture</title>".write(to: file, atomically: true, encoding: .utf8)
            page.load(file)
            for _ in 0..<200 where page.url != file || page.isLoading { try? await Task.sleep(for: .milliseconds(25)) }
            let login = "<meta name=user-login content=rise-test>"
            let star = "<form action='/owner/repo/star'><button>Star</button></form>"
            let unstar = "<form action='/owner/repo/unstar'><button>Starred</button></form>"
            let script = """
            const fetch = async (url, options) => {
                globalThis.requested = { url, method: options.method || 'GET', credentials: options.credentials };
                return { ok: status === 200, url: responseURL, text: async () => html };
            };
            \(GitHubStarScripts.readStatus)
            """
            let fixtures: [(String, String, Bool?)] = [
                (login+star, "Unstarred form", false), (login+unstar, "Starred form", true),
                (login+"<div class='starring-container on'>"+star+unstar+"</div>", "On toggler", true),
                (login+"<div class='starring-container'>"+star+unstar+"</div>", "Off toggler", false),
                (login+"<div data-testid='repository-header'><button aria-label='Star owner/repo'>Star</button></div>", "React header", false),
                (login+star+"<div style='display:none'>"+unstar+"</div>", "Hidden controls ignored", false),
                (star, "Signed out is unknown", nil), (login+"<button>Star another thing</button>", "Missing repo control is unknown", nil)
            ]
            for (html, name, expected) in fixtures {
                let answer = try? await page.evaluate(script, arguments: ["repositoryPath": "owner/repo", "html": html, "responseURL": "https://github.com/owner/repo", "status": 200], in: nil, world: .named("Rise.StatusCheck"))
                check(answer as? Bool == expected, name)
            }
            for (url, status) in [("https://github.com/login", 200), ("https://example.com/owner/repo", 200), ("https://github.com/owner/repo", 404)] {
                let answer = try? await page.evaluate(script, arguments: ["repositoryPath": "owner/repo", "html": login+star, "responseURL": url, "status": status], in: nil, world: .named("Rise.StatusCheck"))
                check(answer as? Bool == nil, "Redirects and failed responses remain unknown")
            }
            let request = try? await page.evaluate("return globalThis.requested", arguments: [:], in: nil, world: .named("Rise.StatusCheck")) as? [String: String]
            check(request?["method"] == "GET" && request?["credentials"] == "same-origin", "Only authenticated GETs, no star mutation")
            // Exercise the actual hydrated-page reader, not only parsed HTML.
            let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
            let reader = GitHubStarrer(); reader.host = window.contentView
            reader.origin = URL(string: "http://localhost:\(port)")!
            let repository = GitHubRepository(url: URL(string: "https://github.com/owner/live"))!
            let directory = folder.appendingPathComponent("owner/live")
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let document = directory.appendingPathComponent("index.html")
            let plainStar = star.replacingOccurrences(of: "owner/repo", with: "owner/live")
            let filledStar = unstar.replacingOccurrences(of: "owner/repo", with: "owner/live")
            let encodedStar = String(data: try! JSONSerialization.data(withJSONObject: [plainStar]), encoding: .utf8)!
            try! "\(login)<title>Live repository</title><div id=controls></div><script>setTimeout(()=>controls.innerHTML=\(encodedStar)[0],300)</script>"
                .write(to: document, atomically: true, encoding: .utf8)
            check(await reader.status(repository) == false, "Live reader waits for a hydrated unstarred control")
            try! (login+"<title>Live repository</title>"+filledStar).write(to: document, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: document.path)
            check(await reader.status(repository) == true, "A second lookup waits for a fresh document at the same URL")
            let mutableStar = "<form action='/owner/live/star' onsubmit=\"event.preventDefault();this.action='/owner/live/unstar';this.querySelector('button').textContent='Starred'\"><button>Star</button></form>"
            try! (login+"<title>Live repository</title>"+mutableStar).write(to: document, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(6)], ofItemAtPath: document.path)
            check(await reader.star(repository) == .starred, "An explicit star still works after read-only lookups")
            reader.tearDown()
            let pill = LinkStatusPill()
            window.contentView?.addSubview(pill)
            for (name, theme) in [("light", RiseTheme.neutral), ("dark", RiseTheme.dark)] {
                pill.appearance = theme.appearance
                for (stateName, state) in [("checking", GitHubLinkStatus.State.checking), ("unstarred", .unstarred), ("starred", .starred)] {
                    pill.show(URL(string: "https://github.com/lochie/skullet")!, theme: theme)
                    pill.setRepositoryState(state); pill.place(in: page.view.bounds); pill.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(400))
                    if let bitmap = pill.bitmapImageRepForCachingDisplay(in: pill.bounds) {
                        pill.cacheDisplay(in: pill.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(stateName).png"))
                    }
                }
            }
            page.browserView.close(); window.close()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
}
