// Run with python3 scripts/test-chromium-live.py Tests/Live/ChromiumAssistantPromptChecks.swift.
// Local composer fixtures exercise the production script in Chromium's isolated world.
import AppKit
import RiseCore
import RiseChromium
@testable import Rise

@main @MainActor struct AssistantPromptChecks {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder+"/chromium", keychain: false) else { exit(1) }
        let delegate = AssistantPromptCheckRun(folder: folder)
        let app = RCApplication.shared
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AssistantPromptCheckRun: NSObject, NSApplicationDelegate {
    let folder: String
    var browser: BrowserController!
    var failures = 0
    init(folder: String) { self.folder = folder }
    func check(_ value: Bool, _ message: String) { print(value ? "PASS" : "FAIL", message); if !value { failures += 1 } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let html = #"""
        <!doctype html><meta charset=utf-8><title>Assistant composer fixture</title><main id="root"></main>
        <script>
        const params=new URLSearchParams(location.search), service=params.get('service'), mode=params.get('mode');
        window.clicks=0; window.lastPrompt=null; window.inputs=0; let remounted=false;
        function mount() {
          const root=document.querySelector('#root'); root.textContent='';
          let editor;
          if(service==='chatGPT'&&mode!=='modern') { editor=document.createElement('textarea'); editor.id='prompt-textarea'; root.append(editor); }
          else { editor=document.createElement('div'); editor.contentEditable='true'; editor.style.minHeight='40px';
            editor.className=service==='gemini'?'ql-editor':'ProseMirror'; editor.setAttribute('role','textbox');
            if(service==='gemini') { const wrap=document.createElement('rich-textarea'); root.append(wrap); wrap.append(editor); }
            else root.append(editor);
          }
          if(mode==='draft') { if('value' in editor) editor.value='my unsent draft'; else editor.textContent='my unsent draft'; }
          const send=document.createElement('button'); send.textContent='Send'; send.disabled=true;
          send.setAttribute('aria-label','Send message'); send.dataset.testid='send-button'; send.className='send-button'; root.append(send);
          if(mode==='modern') { send.removeAttribute('data-testid'); send.type='submit'; send.setAttribute('aria-label','Send'); }
          editor.addEventListener('input',()=>{
            window.inputs++;
            if(mode==='remount'&&!remounted) { remounted=true; setTimeout(mount,50); return; }
            if(mode!=='disabled') setTimeout(()=>send.disabled=false,150);
          });
          send.onclick=()=>{ window.clicks++; window.lastPrompt='value' in editor?editor.value:editor.innerText;
            if(mode!=='ignored') { if('value' in editor) editor.value=''; else editor.textContent=''; send.disabled=true; }
          };
        }
        setTimeout(mount,250);
        </script>
        """#
        try html.write(toFile: folder+"/assistant.html", atomically: true, encoding: .utf8)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        browser = BrowserController(sessionURL: URL(fileURLWithPath: folder+"/session.json"), restore: false)
        browser.showWindow(nil)
        let tab = browser.addTab(url: URL(string: "about:blank")!), page = tab.page
        let prompt = "Hello \"world\" & 日本語\nSecond line <tag>"
        // Origin/path guards are replaced for the loopback fixture. Their production behavior is
        // checked below with the unmodified script, and in AssistantPromptTests.
        let script = AssistantPromptSubmission.script.replacingOccurrences(
            of: "location.protocol !== 'https:' || location.hostname !== hosts[service] || location.port",
            with: "location.hostname !== 'localhost'").replacingOccurrences(of: "if (!roots.includes(path)) return 'cancelled';", with: "")
        func value(_ body: String, world: ScriptWorld = .page) async throws -> Any? {
            try await page.evaluate(body, arguments: [:], in: nil, world: world)
        }
        for service in ChatAssistant.allCases {
            let modes = (service == .chatGPT ? ["modern"] : []) + ["normal", "remount", "draft", "disabled", "ignored"]
            for mode in modes {
                let url = URL(string: "http://localhost:\(port)/assistant.html?service=\(service.rawValue)&mode=\(mode)")!
                tab.load(url)
                let started = Date()
                while page.url != url || page.isLoading {
                    if Date().timeIntervalSince(started) > 10 { throw PageScriptError(message: "Fixture did not load") }
                    try await Task.sleep(for: .milliseconds(30))
                }
                let request = AssistantPrompt(service: service, text: prompt)
                let arguments: [String: Any] = ["requestID":request.id,"service":service.rawValue,"prompt":prompt,"allowClick":true]
                let rejected = try await page.evaluate(AssistantPromptSubmission.script, arguments: arguments, in: nil, world: .named(AssistantPromptSubmission.world)) as? String
                check(rejected == "cancelled", "\(service.name): production script refuses another origin")
                var result: String?
                for _ in 0..<35 {
                    result = try await page.evaluate(script, arguments: arguments, in: nil, world: .named(AssistantPromptSubmission.world)) as? String
                    if ["submitted","draft"].contains(result ?? "") { break }
                    if mode == "disabled", try await value("return window.inputs") as? Int == 1 { break }
                    if mode == "ignored", result == "clicked" {
                        _ = try await value("globalThis.riseAssistantPrompt.clickedAt -= 11000", world: .named(AssistantPromptSubmission.world))
                    }
                    if result == "stalled" { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let clicks = try await value("return window.clicks") as? Int
                switch mode {
                case "draft": check(result == "draft" && clicks == 0, "\(service.name): existing draft is preserved")
                case "disabled": check(result == "waiting" && clicks == 0, "\(service.name): disabled send is never clicked")
                case "ignored": check(result == "stalled" && clicks == 1, "\(service.name): an unacknowledged click is never retried")
                default:
                    check(result == "submitted" && clicks == 1, "\(service.name): \(mode) composer submits exactly once")
                    check(try await value("return window.lastPrompt") as? String == prompt, "\(service.name): multiline Unicode and punctuation survive")
                    for _ in 0..<3 { _ = try await page.evaluate(script, arguments: arguments, in: nil, world: .named(AssistantPromptSubmission.world)) }
                    check(try await value("return window.clicks") as? Int == 1, "\(service.name): repeated evaluation cannot send twice")
                }
            }
        }
        tab.cancelLoad(); browser.window?.close()
    }
}
