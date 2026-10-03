// Live network benchmark: run python3 scripts/test-adblock-live.py.
// A real NSApplication run loop is required for page visibility and idle callbacks.
import AppKit
import WebKit
@testable import Rise

@MainActor final class VerificationDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var failed = false
    func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let suite = "Rise.LiveVerification.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let session = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!)
        browser = BrowserController(sessionURL: session, restore: false, preferences: defaults)
        browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            for address in ["https://adblock.turtlecute.org/", "https://adblock-tester.com/", "https://adblock.turtlecute.org/", "https://adblock-tester.com/"] {
                browser.addTab(url: URL(string: address)!)
                let tab = browser.selectedTab!
                let web = tab.webView
                let deadline = Date().addingTimeInterval(60)
                var result = "", complete = false
                while Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                    if address.contains("turtlecute") {
                        result = (try? await web.evaluateJavaScript("document.querySelector('#adb_test_r')?.textContent ?? ''")) as? String ?? ""
                        complete = result.contains("not blocked")
                    } else {
                        result = (try? await web.evaluateJavaScript("JSON.stringify({score:document.querySelector('.final-score-value')?.textContent,pending:[...document.querySelectorAll('.status')].filter(e=>e.textContent.includes('checking')).length})")) as? String ?? ""
                        complete = result.contains("\"pending\":0") && result.contains("score")
                    }
                    if complete { break }
                }
                report("BENCHMARK \(address): \(result)")
                let passed = complete && (address.contains("turtlecute") ? result.contains("132") && result.contains("0 not blocked") : result.contains("\"score\":\"100\""))
                failed = failed || !passed
                if !passed { report("FAIL diagnostics: \((try? await web.evaluateJavaScript("document.body.innerText")) ?? "nil")") }
                browser.closeTab(tab.id)
            }
            defaults.removePersistentDomain(forName: suite)
            report(failed ? "VERIFICATION FAILED" : "VERIFICATION PASSED")
            NSApp.terminate(nil)
        }
    }
}
@main @MainActor struct VerifyMain {
    static func main() {
        let app = NSApplication.shared, delegate = VerificationDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        exit(delegate.failed ? 1 : 0)
    }
}
