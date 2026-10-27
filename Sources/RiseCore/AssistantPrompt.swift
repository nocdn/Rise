import Foundation

public enum ChatAssistant: String, CaseIterable, Sendable {
    case chatGPT, claude, gemini
    public var name: String { switch self { case .chatGPT: "ChatGPT"; case .claude: "Claude"; case .gemini: "Gemini" } }
    public var domain: String { switch self { case .chatGPT: "chatgpt.com"; case .claude: "claude.ai"; case .gemini: "gemini.google.com" } }
    public var entryURL: URL { URL(string: "https://\(domain)\(self == .claude ? "/new" : self == .gemini ? "/app" : "/")")! }
    public func owns(_ url: URL) -> Bool { url.scheme == "https" && url.host?.lowercased() == domain && url.port == nil }
    public func isConversation(_ url: URL) -> Bool {
        guard owns(url) else { return false }
        return path(in: url).hasPrefix(self == .chatGPT ? "/c/" : self == .claude ? "/chat/" : "/app/")
    }
    public func isComposer(_ url: URL) -> Bool {
        guard owns(url) else { return false }
        return ["", "/", self == .claude ? "/new" : self == .gemini ? "/app" : "/"].contains(path(in: url))
    }
    private func path(in url: URL) -> String {
        self == .gemini ? url.path.replacingOccurrences(of: #"^/u/\d+(?=/)"#, with: "", options: .regularExpression) : url.path
    }
}

/// Created only by Enter in the address bar's explicit Ask mode. A normal visit to a chat site
/// never runs this, and no prompt is placed in a URL, session history, or query-string warning.
public struct AssistantPrompt: Equatable, Sendable {
    public let id: String
    public let service: ChatAssistant
    public let text: String
    public init(service: ChatAssistant, text: String) {
        id = UUID().uuidString; self.service = service; self.text = text
    }
}

/// Wait for the client app to hydrate instead of guessing a load delay. The isolated script
/// remembers a click before making it, so retries of evaluation cannot submit a second copy.
@MainActor public final class AssistantPromptSubmission {
    public static let world = "Rise.AssistantPrompt"
    public enum Outcome: Equatable { case submitted, draft, cancelled, unavailable }
    private var task: Task<Void, Never>?
    public init() {}
    public func cancel() { task?.cancel(); task = nil }
    public func start(_ request: AssistantPrompt, url: @escaping () -> URL?,
                      evaluate: @escaping (_ script: String, _ arguments: [String: Any]) async -> String?,
                      completion: @escaping (Outcome) -> Void) {
        cancel()
        task = Task {
            let start = ProcessInfo.processInfo.systemUptime
            var clicked = false, visited = false
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime-start < 45 {
                if let current = url() {
                    if request.service.isConversation(current) {
                        completion(clicked ? .submitted : .cancelled); return
                    }
                    if request.service.isComposer(current) {
                        visited = true
                        let result = await evaluate(Self.script, ["requestID": request.id, "service": request.service.rawValue,
                                                                 "prompt": request.text, "allowClick": !clicked])
                        guard !Task.isCancelled else { return }
                        switch result {
                        case "submitted": completion(.submitted); return
                        case "clicked": clicked = true
                        case "draft": completion(.draft); return
                        case "cancelled": completion(.cancelled); return
                        case "stalled": completion(.unavailable); return
                        default: break
                        }
                    } else if visited || ProcessInfo.processInfo.systemUptime-start > 3 {
                        completion(.unavailable); return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            if !Task.isCancelled { completion(.unavailable) }
        }
    }

    public static let script = #"""
    const hosts = {chatGPT:'chatgpt.com', claude:'claude.ai', gemini:'gemini.google.com'};
    if (location.protocol !== 'https:' || location.hostname !== hosts[service] || location.port) return 'cancelled';
    const path = service === 'gemini' ? location.pathname.replace(/^\/u\/\d+(?=\/)/,'') : location.pathname;
    const roots = service === 'claude' ? ['/','/new'] : service === 'gemini' ? ['/','/app'] : ['/'];
    if (!roots.includes(path)) return 'cancelled';
    const normalize = text => String(text || '').replace(/\r\n?/g,'\n').replace(/\u00a0/g,' ').trim();
    const wanted = normalize(prompt);
    if (!wanted) return 'cancelled';
    const visible = el => el && el.isConnected && el.getClientRects().length &&
      getComputedStyle(el).visibility !== 'hidden' && getComputedStyle(el).display !== 'none';
    const first = selectors => selectors.flatMap(selector => Array.from(document.querySelectorAll(selector))).find(visible);
    const editors = {
      chatGPT:['#prompt-textarea','textarea[name="prompt-textarea"]','.ProseMirror[role="textbox"][contenteditable="true"]','[contenteditable="true"][aria-label="Ask ChatGPT"]'],
      claude:['.ProseMirror[contenteditable="true"]','[role="textbox"][contenteditable="true"]'],
      gemini:['rich-textarea .ql-editor[contenteditable="true"]','rich-textarea [contenteditable="true"]','.input-area textarea']
    };
    const sends = {
      chatGPT:['button[data-testid="send-button"]','button[aria-label="Send prompt"]','button[aria-label="Send message"]','button[type="submit"][aria-label="Send"]'],
      claude:['button[aria-label="Send message"]','button[aria-label="Send Message"]','button[data-testid="send-button"]'],
      gemini:['button.send-button','button[aria-label="Send message"]','button[aria-label="Send"]']
    };
    const read = el => normalize('value' in el ? el.value : el.innerText);
    let state = globalThis.riseAssistantPrompt;
    if (!state || state.id !== requestID) {
      if (!allowClick) return 'cancelled'; // A new document after a click must never submit again.
      state = globalThis.riseAssistantPrompt = {id:requestID, stage:'waiting', writing:false};
      const stop = e => { if (e.isTrusted && !state.writing) state.cancelled = true; };
      state.stop = stop;
      document.addEventListener('keydown',stop,true);
      document.addEventListener('beforeinput',stop,true);
      document.addEventListener('pointerdown',stop,true);
    }
    const finish = result => {
      for (const type of ['keydown','beforeinput','pointerdown']) document.removeEventListener(type,state.stop,true);
      return result;
    };
    if (state.cancelled) return finish('cancelled');
    const editor = first(editors[service] || []);
    if (state.stage === 'clicked') {
      const busy = first(['button[data-testid="stop-button"]','button[aria-label="Stop response"]','button[aria-label="Stop generating"]','button.stop-button']);
      if (busy || editor && !read(editor)) return finish('submitted');
      if (Date.now()-state.clickedAt > 10000) return finish('stalled');
      return 'clicked';
    }
    if (!editor) return 'waiting';
    if (editor.disabled || editor.getAttribute('aria-disabled') === 'true') return 'waiting';
    const existing = read(editor);
    if (existing && existing !== wanted) return finish('draft');
    if (existing !== wanted) {
      state.writing = true;
      try {
        editor.focus();
        if (editor instanceof HTMLTextAreaElement || editor instanceof HTMLInputElement) {
          const proto = editor instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(proto,'value').set.call(editor,prompt);
          editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:prompt}));
          editor.dispatchEvent(new Event('change',{bubbles:true}));
        } else {
          const range = document.createRange(); range.selectNodeContents(editor);
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
          if (!document.execCommand('insertText',false,prompt)) {
            editor.textContent = prompt;
            editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:prompt}));
          }
        }
      } finally { state.writing = false; }
      state.readyAt = 0; state.editor = editor;
      return 'waiting'; // Give React/ProseMirror/Quill time to enable its real send button.
    }
    let send = first(sends[service] || []);
    if (!send) {
      const form = editor.closest('form');
      send = form && Array.from(form.querySelectorAll('button[type="submit"]')).find(visible);
    }
    if (!visible(send) || send.disabled || send.getAttribute('aria-disabled') === 'true') { state.readyAt=0; return 'waiting'; }
    if (state.editor !== editor || state.send !== send || !state.readyAt) {
      state.editor=editor; state.send=send; state.readyAt=Date.now(); return 'waiting';
    }
    if (Date.now()-state.readyAt < 200) return 'waiting';
    if (!allowClick) return finish('cancelled');
    state.stage='clicked'; state.clickedAt=Date.now();
    send.click();
    return 'clicked';
    """#
}
