import AppKit
import RiseChromium

/// The chat's model using a tab's page as the person would: clicking, typing and pressing keys
/// that reach the page as the person's own, through DevTools, found with `AIChatPageScript`.
///
/// A page only takes input while Chromium has it on screen; one out of sight or in a covered
/// window stops drawing, and input sent to it never arrives. So while the model uses a tab its
/// page keeps visible (`setKeepsVisible`), and a tab out of sight is parked in the window, beyond
/// its edge, at the page's size, where it lays out as it would in front and no one sees it.
/// Ten seconds after the model's last use it's let go, as it was. Meanwhile a blue light goes
/// round its edges (`AIChatGlow`), so the person sees whose page it is for now.
///
/// A dialog the page asks for meanwhile (an alert, a confirm, a prompt, or leaving with unsaved
/// changes) goes to the model rather than showing over whatever the person is looking at: an
/// alert is noted and dismissed; the others wait for `handle_dialog`, and for the person if the
/// model lets the page go first. A file chooser it opens waits likewise, for `upload_file`.
///
/// Those are the model's only while it's at the page: when the page is parked out of sight, or
/// for a moment after the model's last use of it. A page in front the person uses themselves in
/// the meantime asks them, as ever.
@MainActor final class AIChatPageDriver {
    weak var browser: BrowserController?
    unowned let tools: AIChatBrowserTools

    /// How long a page keeps visible after the model last used it.
    static let idleRelease: Duration = .seconds(10)
    /// The most a DevTools command or a script is waited for: one never answered means the page is
    /// stuck, most often on a dialog.
    static let commandLimit: Double = 4

    @MainActor private final class Session {
        weak var tab: BrowserTab?
        let page: WebPage
        var parking: NSView?
        var held = false
        var release: Task<Void, Never>?
        /// The glow round the page's edges while the model has it.
        let glow = AIChatGlow(frame: .zero)
        /// Uses under way, and when the last ended.
        var using = 0
        var usedAt = Date.distantPast
        init(tab: BrowserTab, page: WebPage) { self.tab = tab; self.page = page }
    }
    private var sessions: [UUID: Session] = [:]

    struct Dialog {
        let kind: RCDialogKind
        let message: String
        let defaultText: String
        let finish: (Bool, String?) -> Void
        weak var page: ChromiumPage?
        var describe: String {
            let what = switch kind {
            case .alert: "an alert"
            case .confirm: "a confirm (OK or Cancel)"
            case .prompt: "a prompt asking for text" + (defaultText.isEmpty ? "" : ", suggesting “\(defaultText)”")
            case .leave: "whether to leave the page, which has changes that aren’t saved"
            case .reload: "whether to reload the page, which has changes that aren’t saved"
            @unknown default: "a dialog"
            }
            return message.isEmpty ? what : "\(what): “\(message)”"
        }
    }
    /// Dialogs waiting on the model, by page.
    private var dialogs: [ObjectIdentifier: Dialog] = [:]

    struct Chooser {
        let mode: RCFileChooserMode
        let finish: ([URL]?) -> Void
        var describe: String {
            switch mode {
            case .openMultiple: "a file chooser for one or more files"
            case .openFolder: "a file chooser for a folder"
            default: "a file chooser for one file"
            }
        }
    }
    /// File choosers the page opened for the model, waiting for files, by page.
    private var choosers: [ObjectIdentifier: Chooser] = [:]
    /// Asks the person whether the model may give these files to the page at `host`; a sheet over
    /// the window unless set, as tests do.
    var confirmUpload: (@MainActor (_ files: [URL], _ host: String, _ tab: BrowserTab) async -> Bool)?
    /// What happened to each page that the model hasn't been told yet, such as an alert dismissed.
    private var notes: [ObjectIdentifier: [String]] = [:]
    /// What each ref was when the model last saw it, by tab, for the steps' text.
    private var refNames: [UUID: [String: String]] = [:]

    init(tools: AIChatBrowserTools) {
        self.tools = tools
        browser = tools.browser
    }

    // MARK: Using a page

    /// `body` with the tab's page ready for input: loaded, in the window and visible to Chromium.
    func use<T>(_ tab: BrowserTab, allowingDialog: Bool = false, _ body: (WebPage) async throws -> T) async throws -> T {
        guard let browser, browser.tabs.contains(where: { $0 === tab }) else {
            throw AIChatToolFailure(message: "That tab has closed.")
        }
        if let url = tab.url ?? tab.requestedURL, !["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            throw AIChatToolFailure(message: "That tab isn't a web page the model can use: \(url.absoluteString).")
        }
        let page = await tools.loadedPage(of: tab)
        try Task.checkCancellation()
        if !allowingDialog, let dialog = dialogs[ObjectIdentifier(page)] {
            throw AIChatToolFailure(message: "The page is waiting on \(dialog.describe). Answer it with handle_dialog first.")
        }
        let session = attach(tab, page)
        session.using += 1
        defer { session.using -= 1; session.usedAt = Date(); scheduleRelease(tab.id, session) }
        // A page just parked, or kept visible, becomes visible in a frame or two.
        let deadline = Date()+2
        while Date() < deadline, !(await isVisible(page)), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        return try await body(page)
    }
    private func isVisible(_ page: WebPage) async -> Bool {
        await Self.within(1) { try? await page.evaluate("return document.visibilityState", arguments: [:], in: nil, world: .named(AIChatPageScript.world)) as? String } == "visible"
    }

    private func attach(_ tab: BrowserTab, _ page: WebPage) -> Session {
        let session: Session
        if let existing = sessions[tab.id], existing.page === page {
            existing.release?.cancel(); existing.release = nil
            session = existing
        } else {
            if let old = sessions[tab.id] { finish(old) }
            session = Session(tab: tab, page: page)
            sessions[tab.id] = session
        }
        // Out of the window (in the background, or chosen away from since): parked beyond its edge.
        if page.view.window == nil, let browser, let content = browser.window?.contentView {
            let size = browser.pageShadow.frame.size
            let parking = session.parking ?? HiddenAccessibilityView(frame: .zero)
            parking.frame = NSRect(x: -20000, y: 0, width: max(size.width, 800), height: max(size.height, 600))
            if parking.superview !== content { content.addSubview(parking) }
            session.parking = parking
            page.view.frame = parking.bounds
            parking.addSubview(page.view)
            if !tab.heldSinceBackgroundPicture { tab.heldSinceBackgroundPicture = true; page.setAudioMuted(true); session.held = true }
        }
        page.setKeepsVisible(true)
        // The glow's on the page the model is at; one it's moved on from fades, kept for a while.
        for other in sessions.values where other !== session { other.glow.hide() }
        session.glow.show(over: page.view)
        currentPage = page
        return session
    }
    private func scheduleRelease(_ id: UUID, _ session: Session) {
        session.release?.cancel()
        session.release = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled, let self, self.sessions[id] === session else { return }
            self.sessions[id] = nil
            self.finish(session)
        }
    }
    /// Lets the page go as it was: hidden again if it's out of sight, its dialog the person's.
    private func finish(_ session: Session) {
        session.release?.cancel()
        let page = session.page
        session.glow.hide()
        page.setKeepsVisible(false)
        if let parking = session.parking {
            if page.view.superview === parking { page.view.removeFromSuperview() }
            parking.removeFromSuperview()
        }
        if session.held, let tab = session.tab, let browser, browser.tabs.contains(where: { $0 === tab }), tab.page === page {
            browser.releaseBackgroundPicturePage(tab)
            if page.view.superview == nil { page.setMediaSuspended(true) }
        }
        let key = ObjectIdentifier(page)
        choosers.removeValue(forKey: key)?.finish(nil)
        if let dialog = dialogs.removeValue(forKey: key) {
            if let chromium = dialog.page, let browser {
                _ = browser.showDialog(PageDialog(kind: dialog.kind, message: dialog.message, defaultText: dialog.defaultText), from: chromium, finish: dialog.finish)
            } else { dialog.finish(false, nil) }
        }
        notes[key] = nil
    }
    /// Every page let go, as the model's answer ends.
    func releaseAll() {
        let all = sessions.values
        sessions.removeAll()
        currentPage = nil
        all.forEach(finish)
    }
    var drivenPages: [WebPage] { sessions.values.map(\.page) }
    /// The page the model used last, which glows.
    private(set) weak var currentPage: WebPage?

    // MARK: Dialogs

    /// A page the model is using asks for a dialog: true if the model takes it, so no sheet shows.
    func take(_ dialog: PageDialog, from page: ChromiumPage, finish: @escaping (Bool, String?) -> Void) -> Bool {
        guard isModels(page) else { return false }
        let key = ObjectIdentifier(page)
        if dialog.kind == .alert {
            notes[key, default: []].append("The page showed an alert, which was dismissed: “\(dialog.message)”")
            finish(true, nil)
            return true
        }
        dialogs[key]?.finish(false, nil)
        dialogs[key] = Dialog(kind: dialog.kind, message: dialog.message, defaultText: dialog.defaultText, finish: finish, page: page)
        return true
    }
    /// Whether what the page asks for now is the model's to answer: it's using the page, which is
    /// out of the person's sight or which the model used a moment ago.
    func isModels(_ page: WebPage) -> Bool {
        guard let session = sessions.values.first(where: { $0.page === page }) else { return false }
        return session.parking != nil && page.view.superview === session.parking || session.using > 0 || Date().timeIntervalSince(session.usedAt) < 3
    }
    func pendingDialog(_ page: WebPage) -> Dialog? { dialogs[ObjectIdentifier(page)] }

    /// A page the model is using opens a file chooser: true if the model takes it, so no panel
    /// shows. Saving is the person's.
    func takeChooser(_ mode: RCFileChooserMode, from page: ChromiumPage, finish: @escaping ([URL]?) -> Void) -> Bool {
        guard mode != .save, isModels(page) else { return false }
        let key = ObjectIdentifier(page)
        choosers.removeValue(forKey: key)?.finish(nil)
        choosers[key] = Chooser(mode: mode, finish: finish)
        return true
    }
    func pendingChooser(_ page: WebPage) -> Chooser? { choosers[ObjectIdentifier(page)] }
    /// Gives the waiting chooser `files`, or cancels it with nil.
    @discardableResult func answerChooser(_ page: WebPage, _ files: [URL]?) -> Chooser? {
        guard let chooser = choosers.removeValue(forKey: ObjectIdentifier(page)) else { return nil }
        chooser.finish(files)
        return chooser
    }
    func answerDialog(_ page: WebPage, accept: Bool, text: String?) -> Dialog? {
        guard let dialog = dialogs.removeValue(forKey: ObjectIdentifier(page)) else { return nil }
        dialog.finish(accept, dialog.kind == .prompt ? (text ?? dialog.defaultText) : nil)
        return dialog
    }
    /// What the model hasn't heard about the page yet: alerts dismissed, a dialog waiting.
    func news(_ page: WebPage) -> [String] {
        var lines = notes.removeValue(forKey: ObjectIdentifier(page)) ?? []
        if let dialog = dialogs[ObjectIdentifier(page)] {
            lines.append("The page is waiting on \(dialog.describe). Answer it with handle_dialog before anything else on this page.")
        }
        if let chooser = choosers[ObjectIdentifier(page)] {
            lines.append("The page opened \(chooser.describe). Give it files with upload_file, with no ref, or close it with upload_file and cancel true.")
        }
        return lines
    }

    // MARK: Refs

    func remember(_ refs: [[Any]], for tab: BrowserTab) {
        var names = refNames[tab.id] ?? [:]
        for pair in refs { if pair.count == 2, let ref = pair[0] as? String, let name = pair[1] as? String { names[ref] = name } }
        refNames[tab.id] = names
    }
    /// What `ref` was on the tab, as `button "Add one"`, if the model has seen it.
    func name(of ref: String, in tab: BrowserTab) -> String? { refNames[tab.id]?[Self.ref(ref)] }
    static func ref(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n")) }

    // MARK: The engine

    /// A DevTools command to the page, nil if it failed or wasn't answered in time.
    func send(_ page: WebPage, _ method: String, _ params: [String: Any] = [:], limit: Double = commandLimit) async -> [String: Any]? {
        await Self.within(limit) { await page.devTools(method, params) }
    }
    /// A call on the page script, its result; nil if the page didn't answer in time.
    func script(_ page: WebPage, _ op: String, _ args: [String: Any], limit: Double = commandLimit) async -> [String: Any]? {
        await Self.within(limit) {
            (try? await page.evaluate(AIChatPageScript.call(op), arguments: ["args": args], in: nil, world: .named(AIChatPageScript.world))) as? [String: Any]
        }
    }
    /// Whichever comes first: `work`'s answer, or nil after `seconds`.
    static func within<T>(_ seconds: Double, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let box = AIChatDriverOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resume: @MainActor (T?) -> Void = { value in
                guard !box.done else { return }
                box.done = true
                nonisolated(unsafe) let value = value
                continuation.resume(returning: value)
            }
            Task { @MainActor in resume(await work()) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); resume(nil) }
        }
    }

    // MARK: Input

    enum MouseButton: String { case left, right, middle }
    /// A click at `point`, in CSS pixels from the page's top left as it shows: true if the page took
    /// each part of it.
    func click(_ page: WebPage, at point: CGPoint, count: Int = 1, button: MouseButton = .left, modifiers: Int = 0) async -> Bool {
        var ok = await send(page, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y, "modifiers": modifiers]) != nil
        for click in 1...max(1, count) {
            let base: [String: Any] = ["x": point.x, "y": point.y, "button": button.rawValue, "clickCount": click, "modifiers": modifiers]
            ok = await send(page, "Input.dispatchMouseEvent", base.merging(["type": "mousePressed", "buttons": button == .left ? 1 : button == .right ? 2 : 4]) { $1 }) != nil && ok
            ok = await send(page, "Input.dispatchMouseEvent", base.merging(["type": "mouseReleased", "buttons": 0]) { $1 }) != nil && ok
        }
        return ok
    }
    func hover(_ page: WebPage, at point: CGPoint) async -> Bool {
        await send(page, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y]) != nil
    }
    /// Presses at `from`, moves to `to` a step at a time with the button held, as a hand does,
    /// lingering there, and lets go: true if the page took it all and its mouse works after.
    ///
    /// A drag the page starts as its own (HTML's, with dragstart and drop) DevTools carries out
    /// inside the page, never as the Mac's, and then holds the mouse until it's told the drag is
    /// over: so it's told, every time.
    func drag(_ page: WebPage, from: CGPoint, to: CGPoint, steps: Int = 16) async -> Bool {
        func mouse(_ type: String, _ point: CGPoint, buttons: Int, limit: Double = 2) async -> Bool {
            var event: [String: Any] = ["type": type, "x": point.x, "y": point.y, "buttons": buttons]
            if type != "mouseMoved" { event["button"] = "left"; event["clickCount"] = 1 }
            else if buttons != 0 { event["button"] = "left" }
            return await send(page, "Input.dispatchMouseEvent", event, limit: limit) != nil
        }
        var ok = await mouse("mouseMoved", from, buttons: 0)
        ok = await mouse("mousePressed", from, buttons: 1) && ok
        try? await Task.sleep(for: .milliseconds(60))
        let count = max(2, steps)
        for step in 1...count {
            let t = Double(step)/Double(count)
            // Eased, as a hand slows to place what it carries.
            let eased = 1-pow(1-t, 2)
            let point = CGPoint(x: from.x+(to.x-from.x)*eased, y: from.y+(to.y-from.y)*eased)
            ok = await mouse("mouseMoved", point, buttons: 1) && ok
            try? await Task.sleep(for: .milliseconds(18))
        }
        // Over the target a moment, for places that light up or make room as something's held over them.
        try? await Task.sleep(for: .milliseconds(80))
        ok = await mouse("mouseMoved", to, buttons: 1) && ok
        try? await Task.sleep(for: .milliseconds(40))
        ok = await mouse("mouseReleased", to, buttons: 0, limit: 3) && ok
        return await endDrag(page, at: to) && ok
    }
    /// Ends any drag DevTools still holds, so the mouse works again: true once it does.
    func endDrag(_ page: WebPage, at point: CGPoint) async -> Bool {
        for _ in 0..<3 {
            _ = await send(page, "Input.cancelDragging", [:], limit: 2)
            if await send(page, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": point.x, "y": point.y], limit: 1.5) != nil { return true }
        }
        return false
    }

    /// Gives `files` to the file field the page script marked `mark`, wherever it is on the page,
    /// in a frame or shadow root too: false if it wasn't found or wouldn't take them.
    func setFiles(_ page: WebPage, mark: String, _ files: [URL]) async -> Bool {
        guard await send(page, "DOM.getDocument", ["depth": 0]) != nil else { return false }
        defer { Task { @MainActor in _ = await self.send(page, "DOM.disable", [:], limit: 2) } }
        guard let search = await send(page, "DOM.performSearch", ["query": "[data-rise-upload=\"\(mark)\"]", "includeUserAgentShadowDOM": false]),
              let id = search["searchId"] as? String else { return false }
        defer { Task { @MainActor in _ = await self.send(page, "DOM.discardSearchResults", ["searchId": id], limit: 2) } }
        guard (search["resultCount"] as? Int ?? 0) > 0,
              let found = await send(page, "DOM.getSearchResults", ["searchId": id, "fromIndex": 0, "toIndex": 1]),
              let node = (found["nodeIds"] as? [Int])?.first, node != 0 else { return false }
        return await send(page, "DOM.setFileInputFiles", ["files": files.map(\.path), "nodeId": node], limit: 8) != nil
    }
    /// Drops `files` at `point`, as the person dropping them from the Finder does.
    func dropFiles(_ page: WebPage, at point: CGPoint, _ files: [URL]) async -> Bool {
        let data: [String: Any] = ["items": [], "files": files.map(\.path), "dragOperationsMask": 1]
        for type in ["dragEnter", "dragOver"] {
            guard await send(page, "Input.dispatchDragEvent", ["type": type, "x": point.x, "y": point.y, "data": data]) != nil else { return false }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return await send(page, "Input.dispatchDragEvent", ["type": "drop", "x": point.x, "y": point.y, "data": data], limit: 8) != nil
    }

    func insertText(_ page: WebPage, _ text: String) async -> Bool {
        await send(page, "Input.insertText", ["text": text]) != nil
    }

    /// A key as DevTools takes it.
    struct Key {
        var key: String, code: String, keyCode: Int
        var text: String?
        /// The Mac's editing command for it in a text field, which is how the Mac edits text.
        var command: String?
        var location = 0
    }
    struct Chord { let key: Key; let modifiers: Int; let names: String }
    static let modifierBits = ["alt": 1, "option": 1, "opt": 1, "control": 2, "ctrl": 2, "meta": 4, "command": 4, "cmd": 4, "shift": 8]

    /// "Enter", "Shift+Tab", "Meta+A", "ArrowDown": nil for a name it doesn't know.
    static func chord(_ text: String) -> Chord? {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "Meta++" is Meta and the plus key.
        if text.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers = 0
        for part in parts {
            guard let bit = modifierBits[part.lowercased()] else { return nil }
            modifiers |= bit
        }
        guard var key = key(last) else { return nil }
        // With Command or Control, a letter types nothing; Shift makes it a capital.
        if modifiers & (2 | 4) != 0 { key.text = nil }
        else if modifiers & 8 != 0, let text = key.text, text.count == 1, text.first?.isLetter == true { key.text = text.uppercased() }
        key.command = command(for: key.key, modifiers: modifiers)
        return Chord(key: key, modifiers: modifiers, names: text)
    }
    static func key(_ name: String) -> Key? {
        let named: [String: Key] = [
            "enter": Key(key: "Enter", code: "Enter", keyCode: 13, text: "\r"), "return": Key(key: "Enter", code: "Enter", keyCode: 13, text: "\r"),
            "tab": Key(key: "Tab", code: "Tab", keyCode: 9), "escape": Key(key: "Escape", code: "Escape", keyCode: 27),
            "esc": Key(key: "Escape", code: "Escape", keyCode: 27), "backspace": Key(key: "Backspace", code: "Backspace", keyCode: 8),
            "delete": Key(key: "Delete", code: "Delete", keyCode: 46), "space": Key(key: " ", code: "Space", keyCode: 32, text: " "),
            "arrowup": Key(key: "ArrowUp", code: "ArrowUp", keyCode: 38), "arrowdown": Key(key: "ArrowDown", code: "ArrowDown", keyCode: 40),
            "arrowleft": Key(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37), "arrowright": Key(key: "ArrowRight", code: "ArrowRight", keyCode: 39),
            "up": Key(key: "ArrowUp", code: "ArrowUp", keyCode: 38), "down": Key(key: "ArrowDown", code: "ArrowDown", keyCode: 40),
            "left": Key(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37), "right": Key(key: "ArrowRight", code: "ArrowRight", keyCode: 39),
            "home": Key(key: "Home", code: "Home", keyCode: 36), "end": Key(key: "End", code: "End", keyCode: 35),
            "pageup": Key(key: "PageUp", code: "PageUp", keyCode: 33), "pagedown": Key(key: "PageDown", code: "PageDown", keyCode: 34),
        ]
        if let key = named[name.lowercased()] { return key }
        if name.count >= 2, name.first == "F" || name.first == "f", let number = Int(name.dropFirst()), (1...12).contains(number) {
            return Key(key: "F\(number)", code: "F\(number)", keyCode: 111+number)
        }
        guard name.count == 1, let character = name.first else { return nil }
        let text = String(character)
        if character.isLetter, character.isASCII {
            return Key(key: text.lowercased(), code: "Key\(text.uppercased())", keyCode: Int(character.uppercased().unicodeScalars.first!.value), text: text.lowercased())
        }
        if character.isNumber, character.isASCII { return Key(key: text, code: "Digit\(text)", keyCode: Int(character.unicodeScalars.first!.value), text: text) }
        let punctuation: [Character: (String, Int)] = [
            "-": ("Minus", 189), "=": ("Equal", 187), "[": ("BracketLeft", 219), "]": ("BracketRight", 221), "\\": ("Backslash", 220),
            ";": ("Semicolon", 186), "'": ("Quote", 222), ",": ("Comma", 188), ".": ("Period", 190), "/": ("Slash", 191), "`": ("Backquote", 192),
            "+": ("Equal", 187), "?": ("Slash", 191),
        ]
        if let (code, keyCode) = punctuation[character] { return Key(key: text, code: code, keyCode: keyCode, text: text) }
        return Key(key: text, code: "", keyCode: 0, text: text)
    }
    /// The Mac's editing commands for keys in a text field, as AppKit sends them to the page.
    static func command(for key: String, modifiers: Int) -> String? {
        let shift = modifiers & 8 != 0, alt = modifiers & 1 != 0, meta = modifiers & 4 != 0
        let selecting = shift ? "AndModifySelection" : ""
        switch key {
        case "Backspace": return meta ? "deleteToBeginningOfLine" : alt ? "deleteWordBackward" : "deleteBackward"
        case "Delete": return alt ? "deleteWordForward" : "deleteForward"
        case "ArrowLeft": return meta ? "moveToLeftEndOfLine\(selecting)" : alt ? "moveWordLeft\(selecting)" : "moveLeft\(selecting)"
        case "ArrowRight": return meta ? "moveToRightEndOfLine\(selecting)" : alt ? "moveWordRight\(selecting)" : "moveRight\(selecting)"
        case "ArrowUp": return meta ? "moveToBeginningOfDocument\(selecting)" : "moveUp\(selecting)"
        case "ArrowDown": return meta ? "moveToEndOfDocument\(selecting)" : "moveDown\(selecting)"
        case "Home": return "moveToBeginningOfDocument\(selecting)"
        case "End": return "moveToEndOfDocument\(selecting)"
        case "a" where meta: return "selectAll"
        case "c" where meta: return "copy"
        case "x" where meta: return "cut"
        case "v" where meta: return "paste"
        case "z" where meta: return shift ? "redo" : "undo"
        default: return nil
        }
    }
    /// Presses `chord`, `editing` when a text field has the keyboard, so the Mac's editing applies.
    func press(_ page: WebPage, _ chord: Chord, editing: Bool) async -> Bool {
        let key = chord.key
        var down: [String: Any] = ["type": key.text == nil ? "rawKeyDown" : "keyDown", "key": key.key, "code": key.code,
                                   "windowsVirtualKeyCode": key.keyCode, "nativeVirtualKeyCode": key.keyCode, "modifiers": chord.modifiers]
        if let text = key.text { down["text"] = text; down["unmodifiedText"] = text }
        if editing, let command = key.command { down["commands"] = [command] }
        let pressed = await send(page, "Input.dispatchKeyEvent", down) != nil
        let released = await send(page, "Input.dispatchKeyEvent", ["type": "keyUp", "key": key.key, "code": key.code,
                                                                    "windowsVirtualKeyCode": key.keyCode, "nativeVirtualKeyCode": key.keyCode, "modifiers": chord.modifiers]) != nil
        return pressed && released
    }
    /// Types `text` a key at a time, for fields that act on each key rather than on what's typed.
    func typeKeys(_ page: WebPage, _ text: String) async -> Bool {
        for character in text {
            if character == "\n" { if let enter = Self.chord("Enter"), !(await press(page, enter, editing: true)) { return false }; continue }
            if let key = Self.key(String(character)), key.code != "" || character.isASCII {
                var key = key
                key.text = String(character)
                if character.isUppercase { key.key = String(character) }
                guard await press(page, Chord(key: key, modifiers: character.isUppercase ? 8 : 0, names: String(character)), editing: false) else { return false }
            } else {
                guard await insertText(page, String(character)) else { return false }
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return true
    }
}

private final class AIChatDriverOnce: @unchecked Sendable { var done = false }
