// A site asking for a client certificate, in a real Rise window: macOS's chooser shows as a sheet
// with the keychain's identities that suit the site; Continue sends the one chosen, Cancel none,
// and the chooser closes if the site's request goes away. On a local site asking for a test CA's
// certificate, and on client.badssl.com when online.
// Run with python3 scripts/test-chromium-live.py certificates.
import AppKit
@testable import Rise
import RiseCore
import RiseChromium

@main @MainActor struct ChromiumClientCertificateMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let limit = Double(ProcessInfo.processInfo.environment["RISE_CHECK_TIMEOUT"] ?? "") ?? 180
        DispatchQueue.main.asyncAfter(deadline: .now()+limit) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumClientCertificateRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumClientCertificateRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let suite = "RiseChromiumCheck-\(UUID().uuidString)"
    let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    @discardableResult
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        print("PASS", what)
        return true
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: .page)
    }
    /// macOS's chooser, showing as a sheet on Rise's window.
    var chooser: NSWindow? {
        guard let sheet = browser.clientCertificateChoosers.values.first?.sheet, sheet === browser.window?.attachedSheet else { return nil }
        return sheet
    }
    /// The names on the certificates the chooser offers.
    var offered: [String] {
        browser.clientCertificateChoosers.values.flatMap(\.identities).compactMap { identity in
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        }
    }
    func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views(in:)) }
    /// Answers the chooser as a person does: picks `name`'s row, then presses Continue, or Cancel.
    func answer(_ ok: Bool, choosing name: String? = nil) {
        guard let sheet = chooser, let content = sheet.contentView else { return }
        let all = views(in: content)
        if let name, let chooser = browser.clientCertificateChoosers.values.first,
           let row = chooser.identities.firstIndex(where: { identity in
               var certificate: SecCertificate?
               SecIdentityCopyCertificate(identity, &certificate)
               return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } == name
           }), let table = all.compactMap({ $0 as? NSTableView }).first {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let buttons = all.compactMap { $0 as? NSButton }
        buttons.first { $0.title == (ok ? "Continue" : "Cancel") }?.performClick(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await checks() } catch { check(false, "\(error)") }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func checks() async throws {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setContentSize(NSSize(width: 1200, height: 800)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let hello = "return document.getElementById('name')?.textContent ?? ''"

        // Continue sends the certificate chosen, and the site has it.
        let tab = browser.addTab(url: URL(string: "https://localhost:\(port)/")!)
        if await waitUntil("A site asking for a certificate gets macOS's chooser, as a sheet", 15, { self.chooser != nil }) {
            check(offered.contains("Rise Test Client"), "Offering the keychain's identity for the site: \(offered)")
            answer(true, choosing: "Rise Test Client")
            // Signing with the key asks nothing: the test keychain grants it to Rise's team.
            let sent = Date()
            await waitUntil("Continue sends it, and the site has it", 15) {
                await self.value(hello, in: tab.page) as? String == "Hello, Rise Test Client"
            }
            check(Date().timeIntervalSince(sent) < 3, "Without macOS asking for a password first (\(Int(Date().timeIntervalSince(sent)))s)")
            check(browser.window?.attachedSheet == nil && browser.clientCertificateChoosers.isEmpty, "The chooser has gone")
        }
        // The site has it for the rest of the session, without asking again.
        tab.page.reload()
        try await Task.sleep(for: .milliseconds(1500))
        check(chooser == nil, "Loaded again, the site isn't asked about again")
        check(await value(hello, in: tab.page) as? String == "Hello, Rise Test Client", "And still has it")

        // Cancel goes on without one: the site, which needs one, doesn't load.
        let refused = browser.addTab(url: URL(string: "https://127.0.0.1:\(port)/")!)
        if await waitUntil("Another site asking gets the chooser too", 15, { self.chooser != nil }) {
            answer(false)
            await waitUntil("Cancelled, the chooser goes") { self.chooser == nil && self.browser.window?.attachedSheet == nil }
            try await Task.sleep(for: .milliseconds(1500))
            check((await value(hello, in: refused.page) as? String ?? "").isEmpty, "And the site gets no certificate")
        }

        // A request that goes away, as the tab goes somewhere else, takes the chooser with it.
        let withdrawn = browser.addTab(url: URL(string: "https://rise-cert.test:\(port)/")!)
        if await waitUntil("A third site asking gets the chooser", 15, { self.chooser != nil }) {
            withdrawn.page.load(URL(string: "about:blank")!)
            await waitUntil("Going elsewhere closes it, unanswered", 10) {
                self.browser.window?.attachedSheet == nil && self.browser.clientCertificateChoosers.isEmpty
            }
        }

        // A real site: client.badssl.com takes badssl.com's public client certificate.
        if ProcessInfo.processInfo.environment["RISE_BADSSL"] == "1" {
            let badssl = browser.addTab(url: URL(string: "https://client.badssl.com/")!)
            if await waitUntil("client.badssl.com asks with macOS's chooser", 30, { self.chooser != nil }) {
                check(offered.contains("BadSSL Client Certificate"), "Offering badssl.com's certificate: \(offered)")
                answer(true, choosing: "BadSSL Client Certificate")
                let text = "return document.body?.innerText ?? ''"
                let accepted = await waitUntil("client.badssl.com accepts the certificate", 30) {
                    let shown = (await self.value(text, in: badssl.page) as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    // Its page for a handshake with a certificate; without one it answers 400, "No required SSL certificate was sent".
                    return shown.contains("client-authenticated TLS handshake") && !shown.contains("No required SSL certificate")
                }
                if !accepted { print("client.badssl.com shows:", (await value(text, in: badssl.page) as? String ?? "").prefix(200).debugDescription) }
            }
        } else { print("SKIP client.badssl.com: offline, or its certificate couldn't go in the keychain") }
    }
}
