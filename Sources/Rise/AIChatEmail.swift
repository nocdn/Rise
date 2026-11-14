import AppKit

/// An email the chat's model wrote for the user to send: shown in the answer as a card whose
/// fields they can edit, copy from, and open in Gmail's compose window, filled in.
struct AIChatEmailDraft: Equatable, Sendable {
    var from = "", to = "", cc = "", subject = "", body = ""

    /// From the model's `compose_email` call.
    init(from: String = "", to: String = "", cc: String = "", subject: String = "", body: String = "") {
        self.from = from; self.to = to; self.cc = cc; self.subject = subject; self.body = body
    }
    init(arguments: [String: Any]) {
        func text(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        self.init(from: text("from"), to: text("to"), cc: text("cc"), subject: text("subject"), body: text("body"))
    }

    /// Gmail's compose window, with whatever's filled in, in the account it's from where it says.
    var gmailURL: URL {
        var items: [(String, String)] = []
        if !from.isEmpty { items.append(("authuser", from)) }
        items += [("view", "cm"), ("fs", "1")]
        for (key, value) in [("to", to), ("cc", cc), ("su", subject), ("body", body)] where !value.isEmpty { items.append((key, value)) }
        // Only the unreserved characters left as they are, so a + or & in the text stays itself.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return URL(string: "https://mail.google.com/mail/?\(query)")!
    }
    /// The draft as it now reads, edits and all, for the model to see in a follow-up.
    var modelText: String {
        var lines: [String] = []
        if !from.isEmpty { lines.append("From: \(from)") }
        if !to.isEmpty { lines.append("To: \(to)") }
        if !cc.isEmpty { lines.append("Cc: \(cc)") }
        lines.append("Subject: \(subject)")
        return "<email_draft>\n\(lines.joined(separator: "\n"))\n\n\(body)\n</email_draft>"
    }
}

// MARK: The tool

extension AIChatBrowserTools {
    var composeEmail: AIChatTool {
        let address: [String: Any] = ["type": "string"]
        return AIChatTool(name: "compose_email", description: """
            Shows the user an email you've written as a draft in the chat: a card they can edit, copy the subject or body from, and open in Gmail's compose window, filled in, to send it themselves. Use it whenever the user asks you to write, draft or reply to an email, and again with the whole email to change one. Write the body as plain text without Markdown, with a blank line between paragraphs. Leave from empty unless you know the address the user sends from, and to empty unless you know the recipient's; never make an address up. After calling it, say a sentence at most; the user sees the email, so don't repeat it.
            """,
                          parameters: ["type": "object", "additionalProperties": false, "required": ["subject", "body"],
                                       "properties": ["to": address.merging(["description": "Recipients' addresses, separated by commas, if known."]) { $1 },
                                                      "cc": address.merging(["description": "Addresses to copy in, if any."]) { $1 },
                                                      "from": address.merging(["description": "The user's own address to send from, if known."]) { $1 },
                                                      "subject": ["type": "string"], "body": ["type": "string", "description": "The message, in plain text."]]],
                          step: { _ in AIChatStep(text: "Writing an email", symbol: "envelope") },
                          run: { arguments, step in
            let draft = AIChatEmailDraft(arguments: arguments)
            guard !draft.subject.isEmpty || !draft.body.isEmpty else { throw AIChatToolFailure(message: "Give the email a subject and a body.") }
            var done = step.done(draft.to.isEmpty ? "Wrote an email" : "Wrote an email to \(draft.to)")
            done.draft = .email(draft)
            return AIChatToolResult(output: "The draft is shown to the user in the chat, where they can edit it and open it in Gmail to send.", step: done)
        })
    }
}

// MARK: The card

/// The draft in the answer (`AIChatCard`): its subject and actions on top, copy the subject or
/// the body and open it in Gmail, then who it's from and to, its subject and its body. With no
/// address to send from, From is left empty for one to be typed in, as To is.
@MainActor final class AIChatEmailCard: AIChatCard {
    /// Pikaicons' copy-default and external-link-square, stroked a touch heavier than SF Symbols'.
    static let copyIcon = "M16.9 16.9c.24-.03.45-.08.65-.14 1.52-.5 2.71-1.69 3.21-3.21.24-.76.24-1.69.24-3.55s0-2.79-.24-3.55c-.5-1.52-1.69-2.71-3.21-3.21C16.79 3 15.86 3 14 3s-2.79 0-3.55.24c-1.52.5-2.71 1.69-3.21 3.21-.06.2-.11.41-.14.65m9.8 9.8c.1-.66.1-1.53.1-2.9 0-1.86 0-2.79-.24-3.55-.5-1.52-1.69-2.71-3.21-3.21C12.79 7 11.86 7 10 7c-1.37 0-2.24 0-2.9.1m9.8 9.8c-.03.24-.08.45-.14.65-.5 1.52-1.69 2.71-3.21 3.21-.76.24-1.69.24-3.55.24s-2.79 0-3.55-.24c-1.52-.5-2.71-1.69-3.21-3.21C3 16.79 3 15.86 3 14s0-2.79.24-3.55c.5-1.52 1.69-2.71 3.21-3.21.2-.06.41-.11.65-.14"
    static let openIcon = "M19.76 9.45c.26-1.63.31-3.28.14-4.91-.01-.12-.06-.22-.14-.3m0 0c-.08-.08-.18-.13-.3-.14-1.63-.17-3.28-.12-4.91.14m5.21 0L10 14M20 13.5c0 1.39 0 2.09-.14 2.67-.44 1.83-1.86 3.25-3.69 3.69-.58.14-1.28.14-2.67.14H12c-2.8 0-4.2 0-5.27-.54-.94-.48-1.71-1.25-2.19-2.19C4 16.2 4 14.8 4 12v-.5c0-2.33 0-3.49.38-4.41.51-1.23 1.48-2.2 2.71-2.71.77-.32 1.73-.37 3.41-.38"

    private(set) var draft: AIChatEmailDraft
    var onChange: ((AIChatEmailDraft) -> Void)?
    var onOpen: ((AIChatEmailDraft) -> Void)?
    var copy: (String) -> Void = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    let copyButton = MenuButton(title: "Copy")
    let openButton = ChromeButton(symbol: "arrow.up.right.square", size: 13, title: "Open in Gmail", action: {})
    private let fromLabel = label("From", size: fontSize, weight: .medium), toLabel = label("To", size: fontSize, weight: .medium), ccLabel = label("Cc", size: fontSize, weight: .medium)
    let fromField = AIChatCardField(placeholder: "Your email")
    let toField = AIChatCardField(placeholder: "Recipient")
    let ccField = AIChatCardField(placeholder: "Cc")
    let subjectField = AIChatCardField(placeholder: "Subject", weight: .medium)

    init(_ draft: AIChatEmailDraft) {
        self.draft = draft
        super.init(kind: "Email")
        copyButton.image = TablerIcon.image(Self.copyIcon, size: Self.iconSize, strokeWidth: Self.iconStroke, description: "Copy")
        openButton.image = TablerIcon.image(Self.openIcon, size: Self.iconSize, strokeWidth: Self.iconStroke, description: "Open in Gmail")
        copyButton.setHoverHint("Copy"); openButton.setHoverHint("Open in Gmail")
        copyButton.makeMenu = { [weak self] in self?.makeCopyMenu() }
        copyButton.alignsMenuTrailing = true
        openButton.actionBlock = { [weak self] in guard let self else { return }; self.onOpen?(self.draft) }
        [copyButton, openButton].forEach { $0.layer?.cornerRadius = 6; addSubview($0) }
        fromField.onCommit = { [weak self] value in self?.update { $0.from = value } }
        toField.onCommit = { [weak self] value in self?.update { $0.to = value } }
        ccField.onCommit = { [weak self] value in self?.update { $0.cc = value } }
        subjectField.onCommit = { [weak self] value in self?.update { $0.subject = value } }
        body.setAccessibilityLabel("Message")
        body.onChange = { [weak self] text in
            guard let self else { return }
            self.draft.body = text; self.onChange?(self.draft)
            self.contentChanged(resized: true)
        }
        addRowViews([fromLabel, toLabel, ccLabel, fromField, toField, ccField, subjectField])
        show(draft)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var headingText: String { draft.subject.isEmpty ? "Email" : draft.subject }
    override var headerButtons: [NSView] { [copyButton, openButton] }
    /// From goes with To, without a hairline between them; Cc only where there's one.
    override var rows: [Row] {
        var rows = [Row(label: fromLabel, content: fromField, dividerBelow: false), Row(label: toLabel, content: toField)]
        if !draft.cc.isEmpty { rows.append(Row(label: ccLabel, content: ccField)) }
        rows.append(Row(content: subjectField))
        return rows
    }

    /// Takes a draft that changed from outside, as the model rewrote it.
    func show(_ draft: AIChatEmailDraft) {
        self.draft = draft
        fromField.stringValue = draft.from; toField.stringValue = draft.to; ccField.stringValue = draft.cc
        subjectField.stringValue = draft.subject
        setBody(draft.body)
        contentChanged()
    }
    private func update(_ change: (inout AIChatEmailDraft) -> Void) {
        var next = draft; change(&next)
        guard next != draft else { needsLayout = true; return }
        let rowsChanged = next.cc.isEmpty != draft.cc.isEmpty
        draft = next
        onChange?(draft)
        contentChanged(resized: rowsChanged)
    }

    private func makeCopyMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ text: String) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
            let handler = MenuAction { [weak self] in self?.copy(text) }
            item.target = handler; item.representedObject = handler; item.isEnabled = !text.isEmpty
            menu.addItem(item)
        }
        add("Copy Subject", draft.subject)
        add("Copy Body", draft.body)
        return menu
    }
}

// MARK: Opening it in Gmail

/// Gmail's small compose window over the inbox, filled in. Gmail's links only fill its full-page
/// composer, so the inbox opens with a new message showing (`#inbox?compose=new`) and the fields
/// are typed into once it's there; where it never comes, the full-page composer opens instead.
enum AIChatGmailCompose {
    /// The inbox with a new message open, in the account it's from where it says.
    static func inboxURL(for draft: AIChatEmailDraft) -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let account = draft.from.isEmpty ? "0" : (draft.from.addingPercentEncoding(withAllowedCharacters: allowed) ?? "0")
        return URL(string: "https://mail.google.com/mail/u/\(account)/#inbox?compose=new")!
    }
    /// How long Gmail gets to show the new message once its page has loaded.
    static let wait: TimeInterval = 20

    /// Fills the newest compose window: To and Cc as typed, so Gmail makes them recipients, the
    /// subject, and the body above any signature, a line at a time. True once it's filled.
    static let fillScript = #"""
    const deadline = Date.now() + wait * 1000;
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    let dialog = null;
    while (Date.now() < deadline) {
      const subjects = [...document.querySelectorAll('input[name="subjectbox"]')];
      const subject = subjects[subjects.length - 1];
      if (subject) { dialog = subject.closest('[role="dialog"]') || subject.closest('form')?.parentElement || document; break; }
      await sleep(150);
    }
    if (!dialog) return false;
    const type = (element, text) => {
      element.focus();
      if (!document.execCommand('insertText', false, text)) {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), 'value')?.set;
        setter ? setter.call(element, (element.value || '') + text) : (element.value = (element.value || '') + text);
        element.dispatchEvent(new Event('input', {bubbles: true}));
      }
    };
    const field = names => dialog.querySelector(names.map(name =>
      `input[aria-label^="${name}" i], textarea[aria-label^="${name}" i], textarea[name="${name.toLowerCase()}"], input[name="${name.toLowerCase()}"]`).join(', '));
    const recipients = (element, list) => {
      if (!element || !list) return;
      // A comma after each, as Gmail turns typed addresses into recipients.
      type(element, list.split(/\s*[,;]\s*/).filter(Boolean).join(', ') + ', ');
    };
    recipients(field(['To']), to);
    if (cc) {
      let ccField = field(['Cc']);
      if (!ccField) {
        const show = [...dialog.querySelectorAll('[role="link"], span[data-tooltip]')].find(el => /^cc$/i.test((el.innerText || '').trim()) || /cc/i.test(el.getAttribute('data-tooltip') || ''));
        show?.click(); await sleep(150); ccField = field(['Cc']);
      }
      recipients(ccField, cc);
    }
    const subjectBox = dialog.querySelector('input[name="subjectbox"]');
    if (subjectBox && subject) { subjectBox.focus(); subjectBox.select?.(); type(subjectBox, subject); }
    const body = dialog.querySelector('div[contenteditable="true"][role="textbox"], div[contenteditable="true"][g_editable="true"], div[aria-label^="Message Body" i][contenteditable="true"]');
    if (body && message) {
      body.focus();
      const selection = getSelection(), range = document.createRange();
      range.setStart(body, 0); range.collapse(true); selection.removeAllRanges(); selection.addRange(range);
      message.split('\n').forEach((line, index, lines) => {
        if (line) type(body, line);
        if (index < lines.length - 1 && !document.execCommand('insertLineBreak')) document.execCommand('insertParagraph');
      });
    }
    return true;
    """#
    static func arguments(for draft: AIChatEmailDraft) -> [String: Any] {
        ["to": draft.to, "cc": draft.cc, "subject": draft.subject, "message": draft.body, "wait": wait]
    }
}

@MainActor extension BrowserController {
    /// Opens the draft in Gmail's small compose window, in a tab of its own, filled in.
    func openGmailCompose(_ draft: AIChatEmailDraft) {
        let tab = addTab(url: AIChatGmailCompose.inboxURL(for: draft))
        Task { @MainActor [weak self, weak tab] in
            guard let tab else { return }
            // Gmail redirects on its way in; the fill waits for the page to settle in the inbox.
            let deadline = Date()+AIChatBrowserTools.loadLimit+AIChatGmailCompose.wait
            var filled: Bool?
            while filled == nil, Date() < deadline, self?.tabs.contains(where: { $0 === tab }) == true {
                try? await Task.sleep(for: .milliseconds(300))
                let page = tab.page
                guard !page.isLoading, page.url?.host == "mail.google.com", page.url?.path.hasPrefix("/mail/") == true else { continue }
                // A script cut off by a navigation runs again; one that ran says whether it filled.
                filled = (try? await page.runScript(AIChatGmailCompose.fillScript, arguments: AIChatGmailCompose.arguments(for: draft), world: "Rise.GmailCompose")).map { $0 as? Bool == true }
            }
            // Signed out, or Gmail changed: the full-page composer still takes it all.
            if filled != true, self?.tabs.contains(where: { $0 === tab }) == true { tab.load(draft.gmailURL) }
        }
    }
}
