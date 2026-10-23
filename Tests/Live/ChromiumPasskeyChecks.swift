import AppKit
import LocalAuthentication
import RiseChromium
@testable import Rise

/// Uses a genuinely provisioned app and the real platform authenticator, without creating a
/// credential or asking for biometric input. End-to-end registration/sign-in is a separate,
/// interactive check; these checks must never stand in for that result.
@main @MainActor struct ChromiumPasskeyMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL passkey check timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else {
            print("FAIL Chromium did not start"); exit(1)
        }
        let run = PasskeyChecks(folder: folder)
        app.delegate = run
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class PasskeyChecks: NSObject, NSApplicationDelegate {
    let folder: URL
    let suite = "RisePasskeyCheck-\(UUID().uuidString)"
    var browser: BrowserController!
    var failures = 0
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message)
        if !condition { failures += 1 }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await runChecks() } catch { check(false, String(describing: error)) }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func runChecks() async throws {
        check(Bundle.main.url(forResource: "embedded", withExtension: "provisionprofile", subdirectory: nil) != nil
              || FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/embedded.provisionprofile"),
              "The test app carries a real provisioning profile")
        var localAuthError: NSError?
        check(LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &localAuthError),
              "macOS can authenticate this device's owner")
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false,
                                    preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setContentSize(NSSize(width: 1000, height: 700))
        browser.window?.center()
        browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let html = "<!doctype html><meta charset=utf-8><title>Rise passkey checks</title><h1>Rise passkey checks</h1>"
        try html.write(to: folder.appendingPathComponent("passkeys.html"), atomically: true, encoding: .utf8)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let url = URL(string: "http://localhost:\(port)/passkeys.html")!
        let tab = browser.addTab(url: url)
        let deadline = Date().addingTimeInterval(15)
        while tab.page.url != url || tab.page.isLoading {
            if Date() > deadline { throw NSError(domain: "PasskeyCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test page did not load"]) }
            try await Task.sleep(for: .milliseconds(30))
        }
        let page = tab.page
        let secure = try await page.evaluate("return isSecureContext && !!window.PublicKeyCredential", arguments: [:], in: nil, world: .page)
        check(secure as? Bool == true, "The loopback page is a secure WebAuthn context")
        let available = try await page.evaluate("return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()",
                                                arguments: [:], in: nil, world: .page)
        check(available as? Bool == true, "Chromium's real platform authenticator is available in the provisioned app")

        // An unrelated site may not ask for credentials belonging to another relying party.
        let wrongRP = try await page.evaluate("""
        try {
          await navigator.credentials.create({publicKey: {
            challenge: crypto.getRandomValues(new Uint8Array(32)),
            rp: {id: 'example.com', name: 'Rise test'},
            user: {id: new Uint8Array([1]), name: 'rise-test', displayName: 'Rise test'},
            pubKeyCredParams: [{type: 'public-key', alg: -7}],
            authenticatorSelection: {authenticatorAttachment: 'platform'}
          }});
          return 'unexpected success';
        } catch (error) { return error.name; }
        """, arguments: [:], in: nil, world: .page)
        check(wrongRP as? String == "SecurityError", "WebAuthn rejects an unrelated relying-party ID: \(wrongRP ?? "no result")")

        // Exercise the real request UI and cancellation without completing a credential. This
        // also catches dialog-host crashes that an entitlement-only unit test cannot see.
        let cancelled = try await page.evaluate("""
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 750);
        try {
          await navigator.credentials.create({signal: controller.signal, publicKey: {
            challenge: crypto.getRandomValues(new Uint8Array(32)),
            rp: {id: 'localhost', name: 'Rise cancellation test'},
            user: {id: crypto.getRandomValues(new Uint8Array(16)), name: 'rise-cancel-test', displayName: 'Rise cancellation test'},
            pubKeyCredParams: [{type: 'public-key', alg: -7}],
            authenticatorSelection: {authenticatorAttachment: 'platform', userVerification: 'required'},
            attestation: 'none', timeout: 30000
          }});
          return 'unexpected success';
        } catch (error) { return error.name; }
        finally { clearTimeout(timer); }
        """, arguments: [:], in: nil, world: .page)
        check(cancelled as? String == "AbortError", "A cancelled platform passkey request returns AbortError: \(cancelled ?? "no result")")
        let after = try await page.evaluate("return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()",
                                            arguments: [:], in: nil, world: .page)
        check(after as? Bool == true, "The platform authenticator still responds after cancellation")
    }
}
